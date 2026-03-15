#!/bin/bash
# Writes the current git commit hash into the xcconfig so Xcode
# bakes it into the Info.plist at build time.
#
# Usage:
#   ./scripts/set-build-info.sh          # auto-detect from git
#   ./scripts/set-build-info.sh abc1234  # explicit hash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
XCCONFIG="$REPO_ROOT/Configuration/SpatialStash.xcconfig"

if [ $# -ge 1 ]; then
    HASH="$1"
elif command -v git &>/dev/null && git -C "$REPO_ROOT" rev-parse --short HEAD &>/dev/null; then
    HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
else
    HASH="unknown"
fi

# Replace the COMMIT_HASH line in the xcconfig
if grep -q '^COMMIT_HASH' "$XCCONFIG"; then
    sed -i '' "s/^COMMIT_HASH.*$/COMMIT_HASH = ${HASH}/" "$XCCONFIG"
else
    echo "COMMIT_HASH = ${HASH}" >> "$XCCONFIG"
fi

echo "Set COMMIT_HASH = ${HASH} in $(basename "$XCCONFIG")"
