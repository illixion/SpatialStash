#!/bin/bash
set -euo pipefail

# Build and sign SpatialStash for visionOS device deployment.
#
# Prerequisites:
#   - Copy scripts/build-signing.conf.example to scripts/build-signing.conf and fill in your values
#   - Signing certs installed in keychain (matching identities in build-signing.conf)
#   - Provisioning profiles in the search paths defined in build-signing.conf
#
# Usage:
#   ./scripts/build-and-sign.sh                  # Release build + deploy (default)
#   ./scripts/build-and-sign.sh --debug          # Debug build + deploy
#   ./scripts/build-and-sign.sh --sign-only      # Sign existing build/SpatialStash.ipa
#   ./scripts/build-and-sign.sh --ipa path.ipa   # Sign a specific IPA

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Configuration (loaded from build-signing.conf) ---
CONF_FILE="$SCRIPT_DIR/build-signing.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONF_FILE" >&2
    echo "Copy scripts/build-signing.conf.example to scripts/build-signing.conf and edit it." >&2
    exit 1
fi
# shellcheck source=build-signing.conf
source "$CONF_FILE"

# Validate required variables
for var in TEAM_ID BUILD_BUNDLE_ID BUNDLE_ID DEVICE_NAME DEV_IDENTITY DIST_IDENTITY DEV_PROFILE_NAME DIST_PROFILE_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable $var is not set in $CONF_FILE" >&2
        exit 1
    fi
done

# --- Parse arguments ---
CONFIG="Release"
SIGN_ONLY=false
NO_DEPLOY=false
INPUT_IPA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)      CONFIG="Debug"; shift ;;
        --sign-only)  SIGN_ONLY=true; shift ;;
        --no-deploy)  NO_DEPLOY=true; shift ;;
        --ipa)        INPUT_IPA="$2"; SIGN_ONLY=true; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--debug] [--sign-only] [--no-deploy] [--ipa path.ipa]"
            echo ""
            echo "Options:"
            echo "  --debug       Build with Debug configuration instead of Release"
            echo "  --sign-only   Skip build, sign existing IPA at build/SpatialStash.ipa"
            echo "  --no-deploy   Sign but don't install to device"
            echo "  --ipa PATH    Sign a specific IPA file"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Sideloading uses dev signing
SIGN_IDENTITY="$DEV_IDENTITY"
PROFILE_NAME="$DEV_PROFILE_NAME"

# --- Helper functions ---

find_profile() {
    local profile_name="$1"
    local profile_file=""

    for search_path in "${PROFILE_SEARCH_PATHS[@]}"; do
        for f in "$search_path"/*.mobileprovision; do
            [[ -f "$f" ]] || continue
            local name
            name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - -- -)
            if [[ "$name" == "$profile_name" ]]; then
                profile_file="$f"
                break 2
            fi
        done
    done

    if [[ -z "$profile_file" ]]; then
        echo "ERROR: Could not find provisioning profile named '$profile_name'" >&2
        echo "Searched: ${PROFILE_SEARCH_PATHS[*]}" >&2
        exit 1
    fi
    echo "$profile_file"
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

    echo "Signing with identity: $identity"

    # Sign all embedded dylibs and frameworks first (deepest items first)
    find "$app_path" -name "*.dylib" -o -name "*.framework" | while read -r item; do
        echo "  Signing: $(basename "$item")"
        codesign --force --sign "$identity" --timestamp=none "$item"
    done

    # Sign the main app bundle with entitlements
    echo "  Signing: $(basename "$app_path") (with entitlements)"
    codesign --force --sign "$identity" --entitlements "$entitlements" --timestamp=none "$app_path"
}

# --- Main ---

cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build"
IPA_PATH="$BUILD_DIR/SpatialStash.ipa"

# Step 1: Build (unless --sign-only)
if [[ "$SIGN_ONLY" == false ]]; then
    echo "==> Setting build info..."
    ./scripts/set-build-info.sh

    echo "==> Building for visionOS ($CONFIG)..."
    xcodebuild -quiet \
        -project SpatialStash/SpatialStash.xcodeproj \
        -scheme SpatialStash \
        -configuration "$CONFIG" \
        -destination 'generic/platform=visionOS' \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUILD_BUNDLE_ID" \
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
    (cd "$BUILD_DIR" && rm -f SpatialStash.ipa && zip -qr SpatialStash.ipa Payload)
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

# Step 2: Find provisioning profile
echo "==> Locating provisioning profile ($PROFILE_NAME)..."
PROFILE_PATH=$(find_profile "$PROFILE_NAME")
echo "  Found: $PROFILE_PATH"

# Step 3: Extract entitlements
WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"
extract_entitlements "$PROFILE_PATH" "$ENTITLEMENTS_PLIST"
echo "==> Extracted entitlements from profile"

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
sign_app "$APP_BUNDLE" "$SIGN_IDENTITY" "$ENTITLEMENTS_PLIST"

# Step 7: Repack as signed IPA
SIGNED_IPA="${IPA_PATH%.ipa}-signed.ipa"
echo "==> Repacking signed IPA..."
(cd "$UNPACK_DIR" && rm -f "$SIGNED_IPA" && zip -qr "$SIGNED_IPA" Payload)
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
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_NAME" | awk '{print $3}')
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
