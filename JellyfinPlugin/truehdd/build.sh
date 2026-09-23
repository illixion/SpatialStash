#!/usr/bin/env bash
# Build the truehdd the Atmos Objects plugin runs: upstream at a pinned commit
# plus our patches (applied in order).
#
#   JellyfinPlugin/truehdd/build.sh [--force]
#
# Leaves the binary at JellyfinPlugin/truehdd/checkout/target/release/truehdd.
#
# audio-stdout.patch adds `decode --audio-stdout`: decoded PCM (24-bit LE,
# interleaved) streams to stdout instead of a seekable CAF file, so the plugin
# can serve audio while the decode is still running. The DAMF header and
# metadata still go to --output-path (upstream already flushes the metadata
# after every update).
set -euo pipefail

REPO=https://github.com/truehdd/truehdd
COMMIT=012e69a5aa466bd6e19756aaedb1def7f5d67907   # truehdd 0.6.2 / truehd 0.7.2
PATCHES=(audio-stdout.patch)

here=$(cd "$(dirname "$0")" && pwd)
checkout="$here/checkout"

if [[ "${1:-}" == "--force" ]]; then
    rm -rf "$checkout"
fi

if [[ ! -d "$checkout" ]]; then
    git clone --quiet "$REPO" "$checkout"
    git -C "$checkout" checkout --quiet "$COMMIT"
    for patch in "${PATCHES[@]}"; do
        echo "==> Applying $patch"
        git -C "$checkout" apply "$here/$patch"
    done
else
    echo "==> $checkout exists, rebuilding as is (--force to start over)"
fi

cargo build --release --manifest-path "$checkout/Cargo.toml"
echo "Built $checkout/target/release/truehdd"
