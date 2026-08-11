"""In-process smoke test of the archie_mcp Python layer against live SketchUp.

Calls the tool implementations directly (no MCP framing) and asserts against
known facts of CASA_CUMBRES_DE_JUAREZ + the saved propuesta copy.
Run: .venv/Scripts/python.exe tools/smoke_archie.py [--mutate]
"""
import sys

sys.stdout.reconfigure(encoding="utf-8")

from archie_mcp import projects, versioning  # noqa: E402
from archie_mcp.bridge import bridge  # noqa: E402


def check(label, cond, detail=""):
    mark = "PASS" if cond else "FAIL"
    print(f"[{mark}] {label} {detail}")
    if not cond:
        FAILURES.append(label)


FAILURES = []


def main():
    b = bridge()

    info = b.send("archie_info")
    check("bridge reachable", info.get("version") == "0.2.0", info)

    ref = b.send("get_model_ref")
    check("CASA model open", "CASA_CUMBRES" in ref.get("path", ""), ref.get("path"))

    mi = b.send("get_model_info", {"include_top_level": False})
    ffls = [s["ffl_z"] for s in mi["storeys"]]
    check("FFL 0.62 present", any(abs(f - 0.62) < 0.03 for f in ffls), ffls)
    check("FFL 3.57 present", any(abs(f - 3.57) < 0.03 for f in ffls), ffls)
    ent = [s for s in mi["slabs"]
           if "PROPUESTA" in s["path"] and abs(s["thickness"] - 0.10) < 0.02
           and abs(s["z_top"] - 3.57) < 0.03]
    check("propuesta entrepiso 0.10 found", len(ent) >= 1,
          [e["pid"] for e in ent])

    ops = b.send("list_openings", {})
    doors = [o for o in ops if o["kind"] == "DOOR"]
    orig_doors = [o for o in doors if "PROPUESTA" not in o["container_path"]]
    prop_doors = [o for o in doors if "PROPUESTA" in o["container_path"]]
    check("original doors found", len(orig_doors) == 5, len(orig_doors))
    check("propuesta doors 0.91x2.13", all(
        abs(o["width"] - 0.91) < 0.02 and abs(o["height"] - 2.13) < 0.02
        for o in prop_doors) and len(prop_doors) >= 4, len(prop_doors))
    w1 = [o for o in ops if "PROPUESTA" in o["container_path"]
          and abs(o["width"] - 1.50) < 0.02 and abs(o["height"] - 1.80) < 0.02
          and abs(o["sill_above_floor"] - 0.50) < 0.03]
    # PB-W1, PA-W2 and the two bay lights were all set to spec (1.50x1.80@0.50)
    check("propuesta spec windows 1.50x1.80 sill 0.50", len(w1) >= 2,
          [o["id"] for o in w1])
    w1 = [o for o in w1 if o["center"][2] < 3.0]  # PB-W1: the ground-floor one
    shared = [o for o in ops if o.get("shared")]
    check("shared geometry flagged", len(shared) > 0, f"{len(shared)} flagged")

    vs = versioning.list_versions()
    check("versions dir resolves", vs.get("model", "").endswith(".skp"),
          vs.get("versions_dir"))

    cl = projects.list_clients()
    print(f"[info] clients in db: {[c['name'] for c in cl]}")

    if "--mutate" in sys.argv:
        mutation_suite(b, w1[0] if w1 else None)

    print()
    if FAILURES:
        print("FAILURES:", FAILURES)
        sys.exit(1)
    print("ALL PASS")


def mutation_suite(b, w1):
    """Round-trip resize on the propuesta window + snapshot/dedup checks."""
    assert w1, "propuesta W1 not found; cannot run mutation suite"
    print("\n--- mutation suite (propuesta only) ---")

    s1 = versioning.create_snapshot("smoke: before mutation suite")
    check("snapshot created", bool(s1.get("file")) or s1.get("deduped"), s1)
    s2 = versioning.create_snapshot("smoke: dedup check")
    check("snapshot deduped", s2.get("deduped") is True, s2)

    dry = b.send("resize_opening", {"id": w1["id"], "width": 1.2, "height": 1.0,
                                    "sill": 0.9, "dry_run": True})
    check("dry_run plans vertices", dry.get("vertices", 0) >= 12, dry.get("vertices"))

    r1 = b.send("resize_opening", {"id": w1["id"], "width": 1.2, "height": 1.0,
                                   "sill": 0.9}, )
    check("resize 1.2x1.0@0.9 verified", r1.get("verified") is True,
          r1.get("achieved"))

    r2 = b.send("resize_opening", {"id": r1["new_id"], "width": 1.5, "height": 1.8,
                                   "sill": 0.5})
    check("resize back 1.5x1.8@0.5 verified", r2.get("verified") is True,
          r2.get("achieved"))

    guard_hit = False
    try:
        shared_ops = [o for o in b.send("list_openings", {}) if o.get("shared")]
        if shared_ops:
            b.send("resize_opening", {"id": shared_ops[0]["id"],
                                      "width": 1.0, "height": 1.0})
    except Exception as e:  # noqa: BLE001
        guard_hit = "shared geometry" in str(e)
    check("shared-geometry edit refused", guard_hit)

    vs = versioning.list_versions()
    print(f"[info] versions now: {len(vs['versions'])}")
    for v in vs["versions"][-4:]:
        print(f"   {v['iso']}  {v['label'][:44]:<44} {v['bytes']//1_000_000}MB")


if __name__ == "__main__":
    main()
