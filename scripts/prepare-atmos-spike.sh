#!/usr/bin/env bash
# Prepare a scene for the Atmos Object Spike (Settings → Developer).
#
#   scripts/prepare-atmos-spike.sh <movie.mkv> <start-seconds> <duration-seconds> "<scene name>"
#
# Cuts the first TrueHD track's window, decodes its object presentation with
# truehdd (https://github.com/truehdd/truehdd — build it, then put it on PATH
# or set TRUEHDD), and writes build/AtmosSpike/<scene name>/ with:
#   scene.json   — elements + position/gain events (atmos-spike-damf2json.py)
#   audio.s16le  — raw interleaved 16-bit PCM, one channel per element
# then prints the devicectl commands that copy it into the app's Documents.
#
# Only a stream with an Atmos object presentation (truehdd "Presentation 3")
# yields a scene; plain TrueHD 7.1 has no objects to place.
set -euo pipefail

if [[ $# -ne 4 ]]; then
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi
input=$1 start=$2 duration=$3 name=$4
truehdd=${TRUEHDD:-truehdd}
repo=$(cd "$(dirname "$0")/.." && pwd)
out="$repo/build/AtmosSpike/$name"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$out"
stream=$(ffprobe -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$input" \
    | awk -F, '$2 == "truehd" { print $1; exit }')
[[ -n "$stream" ]] || { echo "No TrueHD audio track in $input." >&2; exit 1; }

echo "==> Cutting TrueHD stream $stream, ${start}s +${duration}s"
ffmpeg -v error -ss "$start" -i "$input" -t "$duration" -map "0:$stream" -c copy -f truehd "$work/clip.thd" 2>/dev/null

echo "==> Decoding objects (truehdd)"
"$truehdd" --loglevel error decode "$work/clip.thd" --output-path "$work/clip" >/dev/null
[[ -f "$work/clip.atmos" ]] || { echo "No Atmos object presentation in this track." >&2; exit 1; }

echo "==> Writing scene"
python3 "$repo/scripts/atmos-spike-damf2json.py" "$work/clip" "$out/scene.json"
ffmpeg -v error -y -i "$work/clip.atmos.audio" -af aresample=osf=s16:dither_method=triangular \
    -f s16le -c:a pcm_s16le "$out/audio.s16le"

echo
echo "Scene ready: $out"
echo "Copy to the headset (bundle id per scripts/build-signing.conf):"
for f in scene.json audio.s16le; do
    echo "  xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \\"
    echo "    --domain-identifier com.illixion.spatialstash --source \"$out/$f\" \\"
    echo "    --destination \"Documents/AtmosSpike/$name/$f\""
done
