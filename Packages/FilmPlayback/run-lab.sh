#!/usr/bin/env bash
# Builds PlayerLab, wraps it in an app bundle and launches it with `open`.
#
# A bare executable run from a terminal is attributed to that terminal by
# privacy enforcement (TCC): head tracking's motion request is then checked
# against the terminal's Info.plist, which has no NSMotionUsageDescription,
# and TCC aborts the process. As its own bundle, launched through
# LaunchServices, the lab is responsible for itself.
#
#   JELLYFIN_TOKEN=… ./run-lab.sh [log file]
# The FILM_* variables described in Sources/PlayerLab/PlayerLab.swift pass through.
set -euo pipefail
cd "$(dirname "$0")"
log="${1:-/tmp/playerlab.log}"

swift build --product PlayerLab
app=.build/PlayerLab.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/out/Products/Debug/PlayerLab "$app/Contents/MacOS/PlayerLab" 2>/dev/null \
    || cp "$(swift build --show-bin-path)/PlayerLab" "$app/Contents/MacOS/PlayerLab"
plutil -convert xml1 -o "$app/Contents/Info.plist" Sources/PlayerLab/Info.plist
plutil -insert CFBundleExecutable -string PlayerLab "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null

env_args=()
for name in JELLYFIN_TOKEN FILM_SERVER FILM_ITEM FILM_START FILM_AUTOPLAY FILM_SCRIPT; do
    if [[ -n "${!name:-}" ]]; then env_args+=(--env "$name=${!name}"); fi
done
: > "$log"
open -n -W "${env_args[@]}" --stdout "$log" --stderr "$log" "$app"
