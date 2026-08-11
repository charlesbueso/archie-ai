"""Summarise logs/model_dump.json produced by the eval_ruby model dumper.

Kept as a script rather than an ad-hoc REPL session so a re-dump of any model
can be re-analysed the same way -- this is the first half of the "inspect a
client model" workflow.
"""
import json
import pathlib
import sys
from collections import defaultdict

sys.stdout.reconfigure(encoding="utf-8")  # layer/material names are Spanish

ROOT = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((ROOT / "logs" / "model_dump.json").read_text(encoding="utf-8"))
nodes = data["nodes"]
by_i = {n["i"]: n for n in nodes}

print(f"== MODEL {data['model']['title']}  nodes={len(nodes)}")
print(f"layers: {[l['name'] for l in data['layers']]}")
print(f"pages : {data['pages']}")
print()


def wmin(n):
    return n["bb"]["min"]


def wsize(n):
    return n["bb"]["size"]


# --- cluster top-level nodes by X to separate the house from the sample board
print("== TOP-LEVEL NODES (depth 0), sorted by x")
tops = sorted([n for n in nodes if n["d"] == 0], key=lambda n: wmin(n)[0])
for n in tops:
    mn, sz = wmin(n), wsize(n)
    print(
        f"  i={n['i']:<4} {n['kind']} {n['defn'][:26]:<26} "
        f"min({mn[0]:8.2f},{mn[1]:8.2f},{mn[2]:7.2f}) "
        f"size({sz[0]:7.2f} x {sz[1]:7.2f} x {sz[2]:6.2f}) "
        f"ents={n['ents']:<5} kids={n['kids']:<4} desc={sum(1 for m in nodes if m['p'] == n['i'])}"
    )
print()

# --- subtree sizes so we can see which top-level node is the actual building
print("== SUBTREE NODE COUNTS (top-level)")
children = defaultdict(list)
for n in nodes:
    children[n["p"]].append(n["i"])


def subtree(i):
    out, stack = 0, [i]
    while stack:
        c = stack.pop()
        out += 1
        stack.extend(children[c])
    return out


for n in tops:
    print(f"  i={n['i']:<4} {n['defn'][:30]:<30} subtree={subtree(n['i']):<5} z0={wmin(n)[2]:7.2f} h={wsize(n)[2]:6.2f}")
print()

# --- slab candidates: thin in Z, large in XY
print("== SLAB CANDIDATES (z-thickness < 0.60m, footprint > 8 m2)")
slabs = []
for n in nodes:
    sz = wsize(n)
    if 0.001 < sz[2] < 0.60 and sz[0] * sz[1] > 8:
        slabs.append(n)
slabs.sort(key=lambda n: (round(wmin(n)[2], 2), -wsize(n)[0] * wsize(n)[1]))
for n in slabs:
    mn, sz = wmin(n), wsize(n)
    print(
        f"  i={n['i']:<4} d={n['d']} {n['defn'][:22]:<22} z={mn[2]:7.3f} thick={sz[2]:6.3f} "
        f"{sz[0]:7.2f} x {sz[1]:7.2f}  area={sz[0]*sz[1]:8.1f} path={n['path'][:44]}"
    )
print()

# --- storey detection: histogram of node base elevations
print("== Z-ELEVATION HISTOGRAM (base of each node, 0.25m bins, count>=3)")
hist = defaultdict(int)
for n in nodes:
    hist[round(wmin(n)[2] * 4) / 4] += 1
for z in sorted(hist):
    if hist[z] >= 3:
        print(f"  z={z:7.2f}  {'#' * min(hist[z], 60)} ({hist[z]})")
print()

# --- wall candidates: thin in X or Y, tall in Z
print("== WALL CANDIDATES (thin<0.40m in x or y, height>2.0m, len>1.5m)")
walls = []
for n in nodes:
    sz = wsize(n)
    thin_x = sz[0] < 0.40 and sz[1] > 1.5
    thin_y = sz[1] < 0.40 and sz[0] > 1.5
    if (thin_x or thin_y) and sz[2] > 2.0:
        walls.append(n)
for n in sorted(walls, key=lambda n: wmin(n)[2]):
    mn, sz = wmin(n), wsize(n)
    print(
        f"  i={n['i']:<4} d={n['d']} {n['defn'][:20]:<20} min({mn[0]:7.2f},{mn[1]:7.2f},{mn[2]:6.2f}) "
        f"size({sz[0]:6.2f} x {sz[1]:6.2f} x {sz[2]:5.2f}) path={n['path'][:40]}"
    )
print()

# --- definition names that hint at doors/windows/slabs
print("== DEFINITIONS matching door/window/slab keywords")
KW = ["puerta", "door", "ventana", "window", "losa", "slab", "vano", "marco",
      "frame", "glass", "vidrio", "cristal", "bano", "baño", "wc", "closet",
      "muro", "wall", "piso", "floor", "techo", "roof", "entrepiso", "escalera",
      "stair"]
for d in data["definitions"]:
    nm = d["name"].lower()
    if any(k in nm for k in KW):
        s = d["bb"]["size"]
        print(f"  {d['name'][:40]:<40} inst={d['instances']:<4} ents={d['ents']:<6} size({s[0]:6.2f} x {s[1]:6.2f} x {s[2]:6.2f})")
print()

# --- node names (non-null) - any human naming at all?
named = [n for n in nodes if n["name"]]
print(f"== NAMED NODES: {len(named)}")
for n in named[:60]:
    print(f"  i={n['i']:<4} d={n['d']} name={n['name'][:40]:<40} defn={n['defn'][:24]}")
