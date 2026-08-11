"""Classify the inner-loop holes dumped by the openings extractor.

Every door/window in CASA_CUMBRES_DE_JUAREZ is a hard hole cut through wall
faces (there are no cuts_opening components), so each real opening shows up
once per wall face -- we dedupe those pairs here and bucket by storey.
"""
import json
import pathlib
import sys
from collections import defaultdict

sys.stdout.reconfigure(encoding="utf-8")

ROOT = pathlib.Path(__file__).resolve().parent.parent
d = json.loads((ROOT / "logs" / "openings.json").read_text(encoding="utf-8"))
holes = d["holes"]

# Finished floor levels derived from slab tops (see analyze_dump.py output):
#   ground slab Group#202 z=0.00 t=0.62 -> FFL 0.62
#   entrepiso   Group#207 z=3.27 t=0.30 -> FFL 3.57
FFL = {"PB": 0.62, "PA": 3.57}
HOUSE_X_MAX = 40.0  # beyond this is the material/furniture sample board


def classify(h):
    nx, ny, nz = (abs(v) for v in h["nrm"])
    sx, sy, sz = h["size"]
    if nz > 0.7:
        return "horiz", max(sx, sy), min(sx, sy)  # hole in a slab (stairwell etc)
    if nx > 0.7:
        return "vert", sy, sz
    if ny > 0.7:
        return "vert", sx, sz
    return "skew", max(sx, sy), sz


rows = []
for h in holes:
    if h["min"][0] > HOUSE_X_MAX:
        continue
    kind, w, ht = classify(h)
    rows.append({**h, "kind": kind, "w": w, "h": ht})

print(f"holes total={len(holes)}  in-house={len(rows)}")

# --- dedupe: the same physical opening appears on both wall faces
seen, uniq = [], []
for r in sorted(rows, key=lambda r: (r["min"][2], r["min"][0], r["min"][1])):
    dup = False
    for s in seen:
        if (r["kind"] == s["kind"]
                and abs(r["min"][2] - s["min"][2]) < 0.05
                and abs(r["w"] - s["w"]) < 0.06
                and abs(r["h"] - s["h"]) < 0.06
                and abs(r["min"][0] - s["min"][0]) < 0.45
                and abs(r["min"][1] - s["min"][1]) < 0.45):
            dup = True
            break
    if not dup:
        seen.append(r)
        uniq.append(r)
print(f"unique physical openings={len(uniq)}\n")


def storey(z):
    best, bn = None, None
    for n, f in FFL.items():
        dz = z - f
        if -0.35 < dz < 3.0 and (best is None or dz < best):
            best, bn = dz, n
    return bn, (best if best is not None else 0.0)


print("== VERTICAL OPENINGS (doors / windows), grouped by storey")
buckets = defaultdict(list)
for r in uniq:
    if r["kind"] != "vert":
        continue
    st, sill = storey(r["min"][2])
    buckets[st].append((r, sill))

for st in ["PB", "PA", None]:
    if st not in buckets:
        continue
    print(f"\n-- storey {st}  (FFL {FFL.get(st, '?')})")
    for r, sill in sorted(buckets[st], key=lambda t: (round(t[1], 2), t[0]["w"])):
        tag = "DOOR  " if sill < 0.12 else "WINDOW"
        print(f"   {tag} w={r['w']:5.2f} h={r['h']:5.2f} sill={sill:5.2f} "
              f"at({r['min'][0]:7.2f},{r['min'][1]:7.2f},{r['min'][2]:6.2f}) "
              f"n={r['nrm']} path={r['path'][-52:]}")

print("\n== HORIZONTAL HOLES (slab penetrations: stairwells, shafts)")
for r in uniq:
    if r["kind"] == "horiz":
        print(f"   {r['w']:6.2f} x {r['h']:6.2f} at z={r['min'][2]:6.2f} path={r['path'][-56:]}")

print("\n== SKEW / non-axis-aligned")
for r in uniq:
    if r["kind"] == "skew":
        print(f"   w={r['w']:5.2f} h={r['h']:5.2f} n={r['nrm']} at={r['min']} path={r['path'][-46:]}")

print("\n== DIMENSION HISTOGRAM (vertical openings, rounded 5cm)")
hist = defaultdict(int)
for r in uniq:
    if r["kind"] == "vert":
        hist[(round(r["w"] * 20) / 20, round(r["h"] * 20) / 20)] += 1
for (w, h), c in sorted(hist.items(), key=lambda kv: -kv[1]):
    print(f"   {w:5.2f} x {h:5.2f}  ->  {c}")
