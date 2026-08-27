#!/bin/bash
# Runs the XCUITest suite against a booted visionOS simulator.
#
# Usage:
#   ./scripts/run-ui-tests.sh                          # whole suite
#   ./scripts/run-ui-tests.sh WelcomeFlowUITests       # one class
#   ./scripts/run-ui-tests.sh WelcomeFlowUITests/testSkipDismissesTheFlowAndLandsInTheApp
#
# Environment:
#   SIM_UDID   simulator to use; defaults to the newest available Vision Pro
#   KEEP_DD    set to 1 to keep the derived data directory
#
# Why a script rather than a remembered xcodebuild line: two flags are not
# optional and are easy to leave off.
#
#   -collect-test-diagnostics never
#       A *passing* run otherwise hangs for exactly 600 s after "Test run
#       passed". One recorded runtime issue — a Main Thread Checker report is
#       enough — makes xcodebuild collect simulator diagnostics, and
#       `simctl diagnose` waits on /usr/bin/darwinup, which the visionOS
#       simulator runtime does not ship.
#
#   CODE_SIGNING_ALLOWED=NO
#       Simulator builds do not need to be signed, and signing here would want
#       a physical Touch ID / YubiKey confirmation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
PROJECT="$REPO_ROOT/SpatialStash/SpatialStash.xcodeproj"
DERIVED_DATA="$REPO_ROOT/build/uitest-dd"

# The newest available Vision Pro simulator, unless told otherwise. `-J` keeps
# the JSON stable across Xcode versions; the last runtime listed is the newest.
if [ -z "${SIM_UDID:-}" ]; then
    SIM_UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
runtimes = sorted(k for k in data if "xrOS" in k or "visionOS" in k)
for runtime in reversed(runtimes):
    for device in data[runtime]:
        print(device["udid"])
        raise SystemExit
')"
fi

if [ -z "$SIM_UDID" ]; then
    echo "No visionOS simulator available. Install one in Xcode > Settings > Components." >&2
    exit 1
fi

# A plain string, not an array: `#!/bin/bash` on macOS is bash 3.2, where
# expanding an empty array under `set -u` is an "unbound variable" error. The
# value never contains whitespace, so `${VAR:+"$VAR"}` is safe here.
ONLY_TESTING=""
if [ $# -ge 1 ]; then
    ONLY_TESTING="-only-testing:SpatialStashUITests/$1"
fi

echo "Simulator: $SIM_UDID"
# Boots it if it isn't already, and waits until it is actually usable.
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

# `set -e` would skip the cleanup below on a test failure, and a failing test
# run is exactly when the derived data is worth deleting or keeping on purpose.
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme SpatialStash \
    -destination "platform=visionOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -collect-test-diagnostics never \
    ${ONLY_TESTING:+"$ONLY_TESTING"} \
    test \
    CODE_SIGNING_ALLOWED=NO
STATUS=$?
set -e

if [ "${KEEP_DD:-0}" != "1" ]; then
    rm -rf "$DERIVED_DATA"
fi

exit $STATUS
