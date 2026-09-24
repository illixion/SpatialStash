#!/usr/bin/env bash
# Plays a film's picture on the Apple TV (FilmLabTV) and reads what the TV
# receives from the rooted LG C1: its live HDMI signal's HDR type, frame
# rate and pixel encoding (luna videooutput/getStatus, read-only).
#
#   JELLYFIN_TOKEN=… ./check-tv.sh <item-id> [start-seconds] [seconds-to-watch]
#
# Deploy first with `FILMLAB=1 ~/bin/build-and-sign` from the repo root.
# The TV needs an ssh-exec session open (ssh-exec exec --host root@<tv> …),
# whose socket this reuses; luna-send only prints with a TTY, hence -tt.
set -euo pipefail
item="${1:?item id}"; start="${2:-600}"; watch="${3:-45}"
: "${JELLYFIN_TOKEN:?set JELLYFIN_TOKEN}"
device="${ATV_DEVICE:-ATV}"
tv="${TV_HOST:-root@172.20.49.154}"
socket="$HOME/.ssh/claude-sessions/${tv//[@.]/_}"
log="${TMPDIR:-/tmp}/filmlab-console.log"

tv_status() {
    ssh -S "$socket" -tt "$tv" 'luna-send -n 1 luna://com.webos.service.videooutput/getStatus "{}"' 2>/dev/null \
        | tr -d '\r' | python3 -c '
import sys, json
v = json.load(sys.stdin)["video"][0]; i = v.get("videoInfo") or {}
enc = i.get("pixelEncoding")
rng = i.get("rgbRange") if enc == "RGB" else i.get("ycbcrRange")
print("%s Hz  hdr=%s  %s %s" % (v.get("frameRate"), i.get("hdrType"), enc, rng))'
}

echo "TV before: $(tv_status)"
: > "$log"
xcrun devicectl device process launch --device "$device" --terminate-existing --console com.illixion.filmlab \
    -- -FilmToken "$JELLYFIN_TOKEN" -FilmItem "$item" -FilmStart "$start" > "$log" 2>&1 &
launcher=$!
for ((t = 5; t <= watch; t += 5)); do
    sleep 5
    printf '%3ds  %s\n' "$t" "$(tv_status)"
done
kill "$launcher" 2>/dev/null || true
echo "--- app"
grep -E 'FilmLabTV:|Terminating|signal' "$log" | grep -v 't=' | cut -c1-240
grep 'FilmLabTV: t=' "$log" | tail -1 | cut -c1-240
