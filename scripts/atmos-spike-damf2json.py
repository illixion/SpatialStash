#!/usr/bin/env python3
"""Convert a truehdd DAMF set (.atmos + .atmos.metadata) into the compact
scene.json the Hypnos Atmos spike reads.

Usage: damf2json.py <base> <out.json>   (base = path without .atmos)

Channel order in .atmos.audio is bed channels first, then objects, in the
order the .atmos header lists them. Later metadata events carry only
samplePos + pos; rampLength and gain persist from the element's last event.
"""
import json, re, sys

base, out = sys.argv[1], sys.argv[2]
header = open(base + ".atmos").read()
beds = re.findall(r"- channel: (\w+)\s+ID: (\d+)", header)
objs = re.findall(r"^\s+- ID: (\d+)\s*$", header.split("objects:")[1], re.M)
elements = [{"id": int(i), "channel": n, "kind": "bed", "bedChannel": c}
            for n, (c, i) in enumerate(beds)]
elements += [{"id": int(i), "channel": len(beds) + n, "kind": "object"}
             for n, i in enumerate(objs)]

meta = open(base + ".atmos.metadata").read()
sample_rate = int(re.search(r"sampleRate: (\d+)", meta).group(1))
state = {}  # id -> {"ramp", "gain"}
events = []
for blk in meta.split("\n  - ID: ")[1:]:
    eid = int(blk.split("\n", 1)[0])
    st = state.setdefault(eid, {"ramp": 0, "gain": 0.0, "active": True})
    if m := re.search(r"rampLength: (\d+)", blk): st["ramp"] = int(m.group(1))
    if m := re.search(r"gain: (\S+)", blk):
        g = m.group(1)
        st["gain"] = -144.0 if "inf" in g else float(g)
    if m := re.search(r"active: (\w+)", blk): st["active"] = m.group(1) == "true"
    sp = int(re.search(r"samplePos: (\d+)", blk).group(1))
    pm = re.search(r"pos: \[([^\]]*)\]", blk)
    ev = {"id": eid, "t": sp, "ramp": st["ramp"],
          "gain": st["gain"] if st["active"] else -144.0}
    if pm: ev["pos"] = [float(v) for v in pm.group(1).split(",")]
    events.append(ev)

events.sort(key=lambda e: (e["t"], e["id"]))
json.dump({"sampleRate": sample_rate, "elements": elements, "events": events},
          open(out, "w"), separators=(",", ":"))
print(f"{len(elements)} elements ({len(beds)} bed), {len(events)} events -> {out}")
