"""Turn the wall-loop dump into a REGION-based edit plan.

First attempt moved only the vertices belonging to each inner loop. That breaks
openings built as stepped frame assemblies (the PB window is four concentric
loops across 0.16 m of wall, with extra frame vertices *between* the loops):
the unlisted in-between vertices stayed put and dragged the faces into
self-intersecting fragments.

So instead of naming vertices, each opening declares a REGION -- a box around
the hole -- plus piecewise rules saying how far to move a vertex based on which
side of the opening it sits on. Everything inside the box travels together, so
frames, reveals and jambs keep their relative geometry.

Spec targets:  windows 1.50 w x 1.80 h, sill 0.50   doors 0.91 w x 2.13 h, sill 0
"""
import json
import pathlib
import sys

sys.stdout.reconfigure(encoding="utf-8")
ROOT = pathlib.Path(__file__).resolve().parent.parent
loops_all = json.loads((ROOT / "logs" / "wall_loops.json").read_text(encoding="utf-8"))

FFL = {"PB": 0.62, "PA": 3.57}
WIN = (1.50, 1.80, 0.50)
DOOR = (0.91, 2.13, 0.00)
# Box margin. Must exceed the model's rough-opening reveal, otherwise the daylight
# opening is resized while the rough opening around it stays at its original size.
# The modeller used a uniform reveal of 0.03-0.06 m, so 0.02 was too tight.
M = 0.08

OPENINGS = [
    dict(c="PB", id="PB-D1", kind="DOOR",   loops=[0, 4],       h=0, note="wide terrace / sliding door"),
    dict(c="PB", id="PB-D2", kind="DOOR",   loops=[1, 5],       h=0, note="main entrance, double leaf"),
    dict(c="PB", id="PB-W1", kind="WINDOW", loops=[6, 2, 3, 7], h=1, note="west window, 4-loop stepped frame"),
    # NOTE: former PA-D3 / PA-D4 were NOT two doors. They are the two leaves of one
    # 1.66 m terrace door split by a 0.05 m mullion at x 9.80-9.85. Sizing them
    # independently drove the new 0.91 openings into each other and inverted the
    # mullion, so they are handled together in build_double() below.
    dict(c="PA", id="PA-D5", kind="DOOR",   loops=[6, 4],       h=0, note="wide balcony door"),
    dict(c="PA", id="PA-W2", kind="WINDOW", loops=[8, 7, 5],    h=0, note="already 1.50x1.80; sill 0.40 -> 0.50"),
]


def ext(loop, ax):
    vs = loop["verts"]
    return min(v[ax] for v in vs), max(v[ax] for v in vs)


def build(op):
    cont = op["c"]
    L = [loops_all[cont]["loops"][i] for i in op["loops"]]
    ha = op["h"]
    na = 1 - ha  # the wall's normal axis (0=x, 1=y)
    tw, th, tsill = WIN if op["kind"] == "WINDOW" else DOOR
    ffl = FFL[cont]

    prim = max(L, key=lambda l: (ext(l, ha)[1] - ext(l, ha)[0]) * (ext(l, 2)[1] - ext(l, 2)[0]))
    h0, h1 = ext(prim, ha)
    z0, z1 = ext(prim, 2)
    hc = (h0 + h1) / 2.0
    nh0, nh1 = hc - tw / 2.0, hc + tw / 2.0
    nz0 = ffl + tsill
    nz1 = nz0 + th

    hmin = min(ext(l, ha)[0] for l in L)
    hmax = max(ext(l, ha)[1] for l in L)
    zmin = min(ext(l, 2)[0] for l in L)
    zmax = max(ext(l, 2)[1] for l in L)
    nmin = min(ext(l, na)[0] for l in L)
    nmax = max(ext(l, na)[1] for l in L)

    return dict(
        id=op["id"], kind=op["kind"], container=cont, note=op["note"],
        h_axis=ha, n_axis=na,
        box=dict(h=[hmin - M, hmax + M], z=[zmin - M, zmax + M], n=[nmin - 0.05, nmax + 0.05]),
        h_rules=[[-1e9, hc, nh0 - h0], [hc, 1e9, nh1 - h1]],
        z_rules=[[-1e9, (z0 + z1) / 2.0, nz0 - z0], [(z0 + z1) / 2.0, 1e9, nz1 - z1]],
        current=f"{h1-h0:.2f} x {z1-z0:.2f} sill {z0-ffl:.2f}",
        target=f"{tw:.2f} x {th:.2f} sill {tsill:.2f}",
    )


def build_bay():
    cont, ffl = "PA", FFL["PA"]
    L = loops_all[cont]["loops"]
    tw, th, tsill = WIN
    a0, a1 = ext(L[0], 0)          # light A
    b0, b1 = ext(L[1], 0)          # light B
    o0, o1 = ext(L[17], 0)         # outer recess
    az0, az1 = ext(L[0], 2)
    oz0, oz1 = ext(L[17], 2)

    # hold the mullion: A keeps its right edge, B keeps its left edge
    dl = (a1 - tw) - a0
    dr = (b0 + tw) - b1
    nz0, nz1 = ffl + tsill, ffl + tsill + th
    dz0, dz1 = nz0 - az0, nz1 - az1

    mull_lo, mull_hi = a1 - 0.10, b0 + 0.10
    nmin = min(ext(L[i], 1)[0] for i in (0, 1, 11, 17))
    nmax = max(ext(L[i], 1)[1] for i in (0, 1, 11, 17))

    return dict(
        id="PA-W3", kind="WINDOW", container=cont,
        note="two-light bay; each light -> 1.50 wide, mullion and reveal margins held",
        h_axis=0, n_axis=1,
        box=dict(h=[o0 - M, o1 + M], z=[min(az0, oz0) - M, max(az1, oz1) + M], n=[nmin - 0.05, nmax + 0.05]),
        h_rules=[[-1e9, mull_lo, dl], [mull_lo, mull_hi, 0.0], [mull_hi, 1e9, dr]],
        z_rules=[[-1e9, (az0 + az1) / 2.0, dz0], [(az0 + az1) / 2.0, 1e9, dz1]],
        current=f"bay {o1-o0:.2f} x {oz1-oz0:.2f}; lights {a1-a0:.2f} + {b1-b0:.2f}",
        target=f"each light {tw:.2f} x {th:.2f} sill {tsill:.2f}",
    )


def build_double():
    """The PA terrace door: two leaves, one mullion. Same treatment as the bay --
    each LEAF gets the spec width and the mullion between them is held still."""
    cont, ffl = "PA", FFL["PA"]
    L = loops_all[cont]["loops"]
    tw, th, tsill = DOOR
    a0, a1 = ext(L[2], 0)            # leaf A  (loops 2 and 12, two wall faces)
    b0, b1 = ext(L[3], 0)            # leaf B  (loop 3)
    z0, z1 = ext(L[2], 2)
    dl = (a1 - tw) - a0              # A keeps its right edge
    dr = (b0 + tw) - b1              # B keeps its left edge
    nz0, nz1 = ffl + tsill, ffl + tsill + th
    mull_lo, mull_hi = a1 - 0.10, b0 + 0.10
    nmin = min(ext(L[i], 1)[0] for i in (2, 12, 3))
    nmax = max(ext(L[i], 1)[1] for i in (2, 12, 3))
    return dict(
        id="PA-D3", kind="DOOR", container=cont,
        note="two-leaf terrace door; each leaf -> 0.91 wide, 0.05 m mullion held",
        h_axis=0, n_axis=1,
        box=dict(h=[a0 - M, b1 + M], z=[z0 - M, z1 + M], n=[nmin - 0.05, nmax + 0.05]),
        h_rules=[[-1e9, mull_lo, dl], [mull_lo, mull_hi, 0.0], [mull_hi, 1e9, dr]],
        z_rules=[[-1e9, (z0 + z1) / 2.0, nz0 - z0], [(z0 + z1) / 2.0, 1e9, nz1 - z1]],
        current=f"1.66 overall = {a1-a0:.2f} + {b1-b0:.2f} leaves, h {z1-z0:.2f}, sill {z0-ffl:.2f}",
        target=f"each leaf {tw:.2f} x {th:.2f} sill {tsill:.2f}",
    )


plan = [build(o) for o in OPENINGS] + [build_double(), build_bay()]
SLAB = dict(id="ENTREPISO", note="hold top at 3.57 (PA finished floor); soffit 3.27 -> 3.47",
            current="0.30 thick", target="0.10 thick", z_from=3.27, z_to=3.47, tol=0.02)

(ROOT / "logs" / "edit_plan.json").write_text(
    json.dumps({"openings": plan, "slab": SLAB}, indent=1), encoding="utf-8")

print(f"{'id':<8}{'kind':<8}{'cur':<32}{'target':<30}{'h-deltas':<22}z-deltas")
print("-" * 118)
for p in plan:
    hd = " ".join(f"{r[2]:+.3f}" for r in p["h_rules"])
    zd = " ".join(f"{r[2]:+.3f}" for r in p["z_rules"])
    print(f"{p['id']:<8}{p['kind']:<8}{p['current']:<32}{p['target']:<30}{hd:<22}{zd}")
print(f"\nENTREPISO  0.30 -> 0.10 thick, soffit {SLAB['z_from']} -> {SLAB['z_to']} (top held at 3.57)")
