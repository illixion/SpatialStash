#!/bin/bash
set -euo pipefail

# Build and sign an app for device deployment.
#
# All signing material (certs, profiles, passwords) is read from
# build-signing.conf — nothing needs to be in the login keychain, so this
# works over SSH.
#
# Usage:
#   ./scripts/build-and-sign.sh                  # Release build + deploy (dev-signed)
#   ./scripts/build-and-sign.sh --debug          # Debug build + deploy
#   ./scripts/build-and-sign.sh --distribution   # Sign with the distribution cert/profile
#   ./scripts/build-and-sign.sh --no-deploy      # Sign but don't install to device
#   ./scripts/build-and-sign.sh --sign-only      # Skip build, sign existing IPA
#   ./scripts/build-and-sign.sh --ipa path.ipa   # Sign a specific IPA (implies --sign-only)
#   ./scripts/build-and-sign.sh --private-api    # GitHub-only: private spatial-3D tuning (visionOS 27+)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load configuration ---
CONF_FILE="$SCRIPT_DIR/build-signing.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONF_FILE" >&2
    echo "Copy scripts/build-signing.conf.example to scripts/build-signing.conf and edit it." >&2
    exit 1
fi
# shellcheck source=build-signing.conf
source "$CONF_FILE"

# Defaults for optional config values
PLATFORM="${PLATFORM:-visionOS}"
TARGET_NAME="${TARGET_NAME:-$SCHEME_NAME}"
P12_PASSWORD="${P12_PASSWORD:-}"
DEV_P12_PASSWORD="${DEV_P12_PASSWORD:-$P12_PASSWORD}"
DIST_P12_PASSWORD="${DIST_P12_PASSWORD:-$P12_PASSWORD}"
PRE_BUILD_HOOK="${PRE_BUILD_HOOK:-}"
# Extra xcodebuild settings (bash array), e.g. compilation conditions:
#   EXTRA_BUILD_SETTINGS=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SOME_FLAG')
if [[ -z "${EXTRA_BUILD_SETTINGS+x}" ]]; then EXTRA_BUILD_SETTINGS=(); fi

required_vars=(
    PROJECT_PATH SCHEME_NAME TARGET_NAME PLATFORM
    TEAM_ID BUILD_BUNDLE_ID DEVICE_NAME
    DEV_P12_PATH DEV_PROFILE_PATH
)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable $var is not set in $CONF_FILE" >&2
        exit 1
    fi
done

# --- Parse arguments ---
CONFIG="Release"
SIGN_ONLY=false
NO_DEPLOY=false
USE_DIST=false
INPUT_IPA=""
PRIVATE_API=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)         CONFIG="Debug"; shift ;;
        --distribution)  USE_DIST=true; shift ;;
        --sign-only)     SIGN_ONLY=true; shift ;;
        --no-deploy)     NO_DEPLOY=true; shift ;;
        --private-api)   PRIVATE_API=true; shift ;;
        --ipa)           INPUT_IPA="$2"; SIGN_ONLY=true; shift 2 ;;
        -h|--help)
            sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --private-api compiles the undocumented ImagePresentationComponent tuning
# (Services/PrivateSpatial3DTuning.swift). It must never reach the App Store,
# so it is mutually exclusive with the distribution signing identity. The
# deployment target is raised to 27.0 because the visionOS 27-only symbols are
# linked non-weakly — on 26.x dyld would fail at launch.
if [[ "$PRIVATE_API" == true ]]; then
    if [[ "$USE_DIST" == true ]]; then
        echo "ERROR: --private-api cannot be combined with --distribution." >&2
        echo "       Private API is for GitHub-only builds and would be rejected by App Review." >&2
        exit 1
    fi
    # The visionOS 27-only accessors are only present in the 27.0 SDK's .tbd, so
    # an older Xcode fails at link time with a bare "Undefined symbol" naming a
    # mangled Swift accessor. Fail here with something actionable instead.
    SDK_VER="$(xcrun --sdk xros --show-sdk-version 2>/dev/null || echo 0)"
    if [[ "${SDK_VER%%.*}" -lt 27 ]]; then
        echo "ERROR: --private-api needs the visionOS 27 SDK; active xrOS SDK is $SDK_VER." >&2
        echo "       Point DEVELOPER_DIR at an Xcode 27 install, e.g.:" >&2
        echo "         DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer $0 --private-api" >&2
        exit 1
    fi
    EXTRA_BUILD_SETTINGS+=(
        "PRIVATE_API_CONDITION=SPATIALSTASH_PRIVATE_API SPATIALSTASH_PRIVATE_API_V27"
        "XROS_DEPLOYMENT_TARGET=27.0"
    )
    echo "NOTE: building with private-API spatial-3D tuning (visionOS 27.0+ only, xrOS SDK $SDK_VER)."
fi

if [[ "$USE_DIST" == true ]]; then
    P12_PATH="$DIST_P12_PATH"
    P12_PW="$DIST_P12_PASSWORD"
    PROFILE_PATH="$DIST_PROFILE_PATH"
    [[ -n "$P12_PATH" && -n "$PROFILE_PATH" ]] || {
        echo "ERROR: --distribution requires DIST_P12_PATH and DIST_PROFILE_PATH in $CONF_FILE" >&2
        exit 1
    }
else
    P12_PATH="$DEV_P12_PATH"
    P12_PW="$DEV_P12_PASSWORD"
    PROFILE_PATH="$DEV_PROFILE_PATH"
fi

for f in "$P12_PATH" "$PROFILE_PATH"; do
    [[ -f "$f" ]] || { echo "ERROR: File not found: $f" >&2; exit 1; }
done

# --- Work dir + cleanup ---
WORK_DIR=$(mktemp -d)
KEYCHAIN_PATH=""
ORIGINAL_KEYCHAINS=""

cleanup() {
    if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
        if [[ -n "$ORIGINAL_KEYCHAINS" ]]; then
            # shellcheck disable=SC2086
            security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
        fi
        security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    [[ -n "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- Helpers ---

# Create a temporary keychain and import the given .p12 into it.
# Sets SIGN_IDENTITY to the SHA1 of the imported signing identity.
# Must be called directly, NOT via $(...): it sets KEYCHAIN_PATH and
# ORIGINAL_KEYCHAINS for the EXIT trap, and a command-substitution
# subshell would discard them — leaking the temp keychain into the
# user search list on every build.
setup_signing_keychain() {
    local p12="$1"
    local p12_password="$2"

    KEYCHAIN_PATH="$WORK_DIR/signing.keychain-db"
    local keychain_pass
    keychain_pass="$(openssl rand -hex 16)"

    security create-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
    security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH" >/dev/null
    security unlock-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null

    # Prepend our keychain to the user search list so codesign can find it.
    ORIGINAL_KEYCHAINS=$(security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' | tr '\n' ' ')
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_KEYCHAINS >/dev/null

    security import "$p12" -k "$KEYCHAIN_PATH" -P "$p12_password" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

    local sha1
    sha1=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
        | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')
    if [[ -z "$sha1" ]]; then
        echo "ERROR: No code-signing identity found in $p12" >&2
        echo "       (is the password correct?)" >&2
        exit 1
    fi
    SIGN_IDENTITY="$sha1"
}

extract_entitlements() {
    local profile_path="$1"
    local entitlements_plist="$2"
    security cms -D -i "$profile_path" 2>/dev/null \
        | plutil -extract Entitlements xml1 -o "$entitlements_plist" -- -
}

sign_app() {
    local app_path="$1"
    local identity="$2"
    local entitlements="$3"
    local keychain="$4"

    echo "Signing with identity: $identity"

    # Sign all embedded dylibs and frameworks first (deepest items first)
    find "$app_path" \( -name "*.dylib" -o -name "*.framework" \) | while read -r item; do
        echo "  Signing: $(basename "$item")"
        codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$item"
    done

    # Sign the main app bundle with entitlements
    echo "  Signing: $(basename "$app_path") (with entitlements)"
    codesign --force --sign "$identity" --keychain "$keychain" \
        --entitlements "$entitlements" --timestamp=none "$app_path"
}

# --- Main ---

cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build"
IPA_PATH="$BUILD_DIR/${TARGET_NAME}.ipa"

# Figure out whether PROJECT_PATH is a project or a workspace
case "$PROJECT_PATH" in
    *.xcworkspace) PROJECT_FLAG="-workspace" ;;
    *.xcodeproj)   PROJECT_FLAG="-project" ;;
    *) echo "ERROR: PROJECT_PATH must end in .xcodeproj or .xcworkspace" >&2; exit 1 ;;
esac

# Step 1: Build (unless --sign-only)
if [[ "$SIGN_ONLY" == false ]]; then
    if [[ -n "$PRE_BUILD_HOOK" ]]; then
        echo "==> Running pre-build hook: $PRE_BUILD_HOOK"
        # shellcheck disable=SC2086
        ( cd "$PROJECT_ROOT" && eval $PRE_BUILD_HOOK )
    fi

    echo "==> Building for $PLATFORM ($CONFIG)..."
    xcodebuild -quiet \
        "$PROJECT_FLAG" "$PROJECT_PATH" \
        -scheme "$SCHEME_NAME" \
        -configuration "$CONFIG" \
        -destination "generic/platform=$PLATFORM" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUILD_BUNDLE_ID" \
        ${EXTRA_BUILD_SETTINGS[@]+"${EXTRA_BUILD_SETTINGS[@]}"} \
        build

    echo "==> Packaging IPA..."
    APP_PATH=$(find "$BUILD_DIR/DerivedData" -name '*.app' -type d | head -1)
    if [[ -z "$APP_PATH" ]]; then
        echo "ERROR: No .app bundle found in DerivedData" >&2
        exit 1
    fi
    rm -rf "$BUILD_DIR/Payload"
    mkdir -p "$BUILD_DIR/Payload"
    cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
    ( cd "$BUILD_DIR" && rm -f "${TARGET_NAME}.ipa" && zip -qr "${TARGET_NAME}.ipa" Payload )
    echo "  Built: $IPA_PATH"
fi

# Use custom IPA path if specified
if [[ -n "$INPUT_IPA" ]]; then
    IPA_PATH="$INPUT_IPA"
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "ERROR: IPA not found at $IPA_PATH" >&2
    exit 1
fi

# Step 2: Import signing cert into a temporary keychain
echo "==> Importing signing certificate from $(basename "$P12_PATH")..."
setup_signing_keychain "$P12_PATH" "$P12_PW"
echo "  Identity: $SIGN_IDENTITY"

# Step 3: Extract entitlements from the provisioning profile
ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"
extract_entitlements "$PROFILE_PATH" "$ENTITLEMENTS_PLIST"
echo "==> Using profile: $PROFILE_PATH"

# Step 4: Unpack IPA
echo "==> Unpacking IPA..."
UNPACK_DIR="$WORK_DIR/unpack"
mkdir -p "$UNPACK_DIR"
unzip -qo "$IPA_PATH" -d "$UNPACK_DIR"

APP_BUNDLE=$(find "$UNPACK_DIR/Payload" -name '*.app' -type d -maxdepth 1 | head -1)
if [[ -z "$APP_BUNDLE" ]]; then
    echo "ERROR: No .app found in IPA" >&2
    exit 1
fi

# Step 5: Embed provisioning profile
echo "==> Embedding provisioning profile..."
cp "$PROFILE_PATH" "$APP_BUNDLE/embedded.mobileprovision"

# Step 6: Sign
echo "==> Signing app bundle..."
sign_app "$APP_BUNDLE" "$SIGN_IDENTITY" "$ENTITLEMENTS_PLIST" "$KEYCHAIN_PATH"

# Step 7: Repack as signed IPA
SIGNED_IPA="${IPA_PATH%.ipa}-signed.ipa"
echo "==> Repacking signed IPA..."
( cd "$UNPACK_DIR" && rm -f "$SIGNED_IPA" && zip -qr "$SIGNED_IPA" Payload )
echo ""
echo "Done! Signed IPA: $SIGNED_IPA"

# Step 8: Verify
echo ""
echo "==> Verification:"
codesign -dvvv "$APP_BUNDLE" 2>&1 | grep -E "^(Authority|TeamIdentifier|Identifier|Signature)"

# Step 9: Deploy to device
if [[ "$NO_DEPLOY" == false ]]; then
    echo ""
    echo "==> Deploying to $DEVICE_NAME..."
    # Resolve the device UUID by pattern, never by column position: the Hostname
    # column is empty while a device sits in the `connected` state, which shifts
    # every later field left and made `awk '{print $3}'` return the literal
    # string "connected" as the identifier. Simulator rows are skipped since
    # devicectl only installs to physical devices. `|| true` is required under
    # `set -euo pipefail`, which would otherwise abort on grep's no-match exit
    # before the friendly error below could run.
    DEVICE_LIST=$(xcrun devicectl list devices 2>/dev/null || true)
    _device_uuid() {
        grep -v "simulated" \
            | grep -oiE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
            | head -1
    }
    # Prefer an exact match in the Name column, then fall back to a loose match
    # so configs that name a model substring keep working.
    DEVICE_ID=$(printf '%s\n' "$DEVICE_LIST" | grep -E "^${DEVICE_NAME}[[:space:]]" | _device_uuid || true)
    if [[ -z "$DEVICE_ID" ]]; then
        DEVICE_ID=$(printf '%s\n' "$DEVICE_LIST" | grep -F "$DEVICE_NAME" | _device_uuid || true)
    fi
    if [[ -z "$DEVICE_ID" ]]; then
        echo "ERROR: Device '$DEVICE_NAME' not found. Is it connected and paired?" >&2
        echo "Available devices:"
        xcrun devicectl list devices 2>/dev/null | grep -E "available|connected"
        exit 1
    fi
    xcrun devicectl device install app --device "$DEVICE_ID" "$SIGNED_IPA"
    echo ""
    echo "Installed on $DEVICE_NAME!"
else
    echo ""
    echo "To install: xcrun devicectl device install app --device <UDID> '$SIGNED_IPA'"
fi
