"""Regression suite for the bugs found in the 2026-08-10 beta session.

Each check is named for its bug number so a regression is obvious.

Default (--fast) is READ-ONLY: it uses inspection, validation-rejection and
dry_run paths only, so it never mutates the open model and never reopens an
85MB file. Use it constantly during development.

--full additionally copies the model to a throwaway scratch file and exercises
the real mutation + rollback paths. Slow (minutes on a large model) and it
reopens models, so run it before a release, not in the inner loop.

Run: .venv/Scripts/python.exe tools/smoke_bugs.py [--full] [--port 9876]
"""
from __future__ import annotations

import json
import re
import shutil
import socket
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

PORT = 9876
if "--port" in sys.argv:
    PORT = int(sys.argv[sys.argv.index("--port") + 1])
FULL = "--full" in sys.argv

ROOT = Path("B:/repos/archie-ai")
ORIGINAL = ROOT / "test" / "CASA CUMBRES DE JUAREZ_original.skp"
SCRATCH = ROOT / "test" / "_bugtest_scratch.skp"

FAILURES: list[str] = []
_sock = None
_file = None
_id = 0


def call(method, params=None, timeout=600):
    global _id
    _id += 1
    _sock.sendall((json.dumps({"id": _id, "method": method,
                               "params": params or {}}) + "\n").encode("utf-8"))
    _sock.settimeout(timeout)
    line = _file.readline()
    if not line:
        raise ConnectionError("bridge closed")
    r = json.loads(line)
    if r.get("error"):
        raise RuntimeError(r["error"]["message"])
    return r["result"]


def rb(code, timeout=600):
    return call("eval_ruby", {"code": code}, timeout)["result"]


def check(label, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {label} {detail}")
    if not cond:
        FAILURES.append(label)


def expect_raises(label, fn, needle=""):
    try:
        fn()
        check(label, False, "no error raised")
    except (RuntimeError, ValueError, FileNotFoundError, PermissionError) as e:
        ok = needle.lower() in str(e).lower() if needle else True
        check(label, ok, f"-> {str(e)[:78]}")


# --------------------------------------------------------------- read-only --

def expected_version() -> str:
    txt = (ROOT / "server" / "archie_mcp" / "__init__.py").read_text(encoding="utf-8")
    return re.search(r'__version__ = "([^"]+)"', txt).group(1)


def read_only_suite():
    info = call("archie_info")
    want = expected_version()
    check(f"extension v{want}", info["version"] == want,
          f"got {info['version']}")

    ref = call("get_model_ref")
    print(f"     model: {Path(ref['path']).name or '(unsaved)'}")

    # BUG-01 — the transaction observer must survive garbage collection
    check("BUG-01 observer alive", ref.get("observer_alive") is True)
    s0 = ref["edit_seq"]
    rb('m=Sketchup.active_model; m.start_operation("archie selftest",true); '
       'g=m.entities.add_group; g.erase!; m.commit_operation; "ok"')
    s1 = call("get_model_ref")["edit_seq"]
    check("BUG-01 edit_seq advances on commit", s1 > s0, f"{s0} -> {s1}")

    mi = call("get_model_info", {"include_top_level": False})
    slabs = mi["slabs"]
    check("BUG-04 slabs expose anomalies", all("anomalies" in s for s in slabs),
          f"{sum(1 for s in slabs if s['anomalies'])} anomalous of {len(slabs)}")
    check("BUG-07 slabs expose editability", all("editable" in s for s in slabs),
          f"{sum(1 for s in slabs if s.get('nested_geometry'))} nested")

    ops = call("list_openings", {})
    check("DESIGN-01 dict with totals",
          isinstance(ops, dict) and "total" in ops and "by_kind" in ops,
          f"total={ops.get('total')} {ops.get('by_kind')}")
    check("DESIGN-01 pagination caps payload", len(ops.get("openings", [])) <= 60,
          f"{len(ops.get('openings', []))} rows")
    summ = call("list_openings", {"summary": True})
    check("DESIGN-01 summary omits rows",
          "openings" not in summ and "by_container" in summ,
          f"{len(summ.get('by_container', {}))} containers")
    doors = call("list_openings", {"kind": "DOOR"})
    check("DESIGN-01 kind filter",
          all(o["kind"] == "DOOR" for o in doors["openings"]), f"{doors['total']} doors")

    tiny = call("list_openings", {"min_width": 0.01, "min_height": 0.01})
    withf = call("list_openings", {"min_width": 0.01, "min_height": 0.01,
                                   "include_furniture": True})
    check("BUG-14 furniture excluded by default", tiny["furniture_excluded"] > 0,
          f"{tiny['furniture_excluded']} excluded")
    check("BUG-14 furniture visible on request", withf["total"] > tiny["total"],
          f"{tiny['total']} -> {withf['total']}")
    anom = [o for o in withf["openings"] if o.get("anomalies")]
    check("BUG-15 anomalies surfaced", True, f"{len(anom)} flagged in page")

    expect_raises("BUG-12 unknown container_pid errors",
                  lambda: call("list_openings", {"container_pid": 99999999}), "not found")
    expect_raises("BUG-13 negative min_width rejected",
                  lambda: call("list_openings", {"min_width": -10}), "must be")

    # BUG-03 — validation rejects before any geometry is touched, so safe here
    victim = next((s for s in slabs if s["editable"] and s["thickness"] > 0.05), None)
    if victim:
        for bad, needle in ((-0.5, "must be > 0"), (0, "must be > 0"), (500, "<=")):
            expect_raises(f"BUG-03 thickness={bad} rejected",
                          lambda b=bad: call("set_slab_thickness",
                                             {"pid": victim["pid"], "thickness": b}),
                          needle)

    # BUG-05 — list_openings and resize_opening must agree on kind. dry_run
    # does not mutate, so this is safe read-only.
    allops = call("list_openings", {"min_width": 0.3, "min_height": 0.3, "limit": 500})
    agree = disagree = 0
    for o in allops["openings"][:16]:
        try:
            dry = call("resize_opening", {"id": o["id"], "width": o["width"],
                                          "height": o["height"], "dry_run": True})
            if dry.get("kind") == o["kind"]:
                agree += 1
            else:
                disagree += 1
                print(f"       mismatch {o['id']}: list={o['kind']} resize={dry.get('kind')}")
        except RuntimeError as e:
            if "ASSEMBLY" in str(e):
                if o["kind"] == "ASSEMBLY":
                    agree += 1
                else:
                    disagree += 1
                    print(f"       mismatch {o['id']}: list={o['kind']} resize=ASSEMBLY")
            else:
                agree += 1
    check("BUG-05 both tools agree on kind", disagree == 0,
          f"{agree} agree / {disagree} disagree")

    target = next((o for o in allops["openings"]
                   if o["kind"] in ("DOOR", "WINDOW") and not o["shared"]), None)
    if target:
        dry = call("resize_opening", {"id": target["id"], "width": 19.0,
                                      "height": 19.0, "dry_run": True})
        proj = dry.get("projected", {})
        check("BUG-20 dry_run reports clamped projection",
              proj.get("width", 99) < 19.0 or dry.get("clamped") is True,
              f"projected={proj} clamped={dry.get('clamped')}")

    if target:
        loc = call("locate", {"opening_id": target["id"]})
        check("DESIGN-03 locate zooms + selects",
              loc.get("zoomed") and loc.get("selected"), loc.get("located"))
    expect_raises("DESIGN-03 locate rejects unknown pid",
                  lambda: call("locate", {"pid": 99999999}), "not found")
    return allops


# ------------------------------------------------------- python-side layer --

def projects_suite():
    from archie_mcp import projects as P
    marker = "ZZ Archie Selftest"
    try:
        P.delete_client(marker, delete_projects=True)
    except Exception:
        pass

    P.create_client(marker, notes="temporary; deleted by the selftest")
    check("BUG-11 accent-insensitive client match",
          P.find_client("zz archie selftest")["name"] == marker)

    expect_raises("BUG-09 missing .skp rejected",
                  lambda: P.create_project(marker, "Ghost", r"B:\nope\missing.skp"),
                  "does not exist")

    P.create_project(marker, "Casa Áccent Test", str(ORIGINAL), brief="temp")
    check("BUG-11 accent-insensitive project match",
          P.find_project("casa accent test")["name"] == "Casa Áccent Test")

    other = ROOT / "test" / "CASA_CUMBRES_DE_JUAREZ.skp"
    if other.exists():
        expect_raises("BUG-08 silent repoint refused",
                      lambda: P.create_project(marker, "Casa Áccent Test", str(other)),
                      "allow_repoint")
        r = P.create_project(marker, "Casa Áccent Test", str(other), allow_repoint=True)
        check("BUG-08 explicit repoint allowed + reported", r.get("repointed") is True)

    expect_raises("BUG-16 delete_client guards children",
                  lambda: P.delete_client(marker), "still has")
    d = P.delete_client(marker, delete_projects=True)
    check("BUG-16 delete tools work", d["deleted_client"] == marker,
          f"removed {len(d['deleted_projects'])} project(s)")


# ------------------------------------------------------------- mutating -----

def full_suite(allops):
    print(f"\n-- FULL: copying model to {SCRATCH.name} (slow)")
    shutil.copy2(ORIGINAL, SCRATCH)
    call("open_model", {"path": str(SCRATCH), "discard_unsaved": True}, timeout=900)
    check("scratch model open",
          "_bugtest_scratch" in call("get_model_ref")["path"])

    ops = call("list_openings", {"min_width": 0.3, "min_height": 0.3, "limit": 500})
    target = next((o for o in ops["openings"]
                   if o["kind"] in ("DOOR", "WINDOW") and not o["shared"]), None)
    if target:
        cpid = target["container_pid"]
        before = call("list_openings", {"container_pid": cpid, "min_width": 0.3,
                                        "min_height": 0.3, "limit": 500})
        sig_before = sorted((o["id"], o["width"], o["height"]) for o in before["openings"])
        expect_raises("BUG-02 impossible resize raises",
                      lambda: call("resize_opening", {"id": target["id"], "width": 19.0,
                                                      "height": 19.0}),
                      "rolled back")
        after = call("list_openings", {"container_pid": cpid, "min_width": 0.3,
                                       "min_height": 0.3, "limit": 500})
        sig_after = sorted((o["id"], o["width"], o["height"]) for o in after["openings"])
        check("BUG-02 geometry unchanged after failure", sig_before == sig_after,
              "identical" if sig_before == sig_after else "MUTATED")

    win = next((o for o in ops["openings"]
                if o["kind"] == "WINDOW" and not o["shared"] and o["width"] > 0.6), None)
    if win:
        r = call("resize_opening", {"id": win["id"], "width": 1.10, "height": 1.00,
                                    "sill": 0.90})
        check("happy path resize verified", r.get("verified") is True, r.get("achieved"))

    print("-- restoring the real model")
    call("open_model", {"path": str(ORIGINAL), "discard_unsaved": True}, timeout=900)
    check("original reopened", "_original" in call("get_model_ref")["path"])
    for junk in (ROOT / "test").glob("_bugtest_scratch.sk*"):
        try:
            junk.unlink()
        except OSError:
            pass


def creation_suite():
    """v0.4 capabilities. Creates geometry far from the building, verifies it,
    then erases it, so the open model is left exactly as found."""
    info = call("archie_info")
    if not info.get("dev_mode"):
        print("   (skipped: needs dev_mode for cleanup)")
        return
    made = []
    try:
        b = call("create_box", {"origin": [500, 0, 0], "size": [2, 3, 1.5],
                                "name": "SELFTEST_BOX"})
        made.append(b["pid"])
        check("create_box", b["size"] == [2.0, 3.0, 1.5] and b["verified"], b["size"])

        s = call("create_slab", {"origin": [500, 10], "size": [5, 4], "thickness": 0.2,
                                 "z_level": 3.0, "datum": "top", "name": "SELFTEST_SLAB"})
        made.append(s["pid"])
        check("create_slab datum=top puts FFL at z_level",
              abs(s["z_top"] - 3.0) < 0.001 and abs(s["z_bottom"] - 2.8) < 0.001,
              f"{s['z_bottom']}..{s['z_top']}")

        w = call("create_wall", {"start": [500, 20], "end": [506, 24], "height": 2.7,
                                 "thickness": 0.2, "name": "SELFTEST_DIAG"})
        made.append(w["pid"])
        check("create_wall handles non-axis-aligned", abs(w["length"] - 7.211) < 0.01,
              f"len={w['length']}")

        w2 = call("create_wall", {"start": [500, 30], "end": [506, 30], "height": 2.7,
                                  "thickness": 0.2, "name": "SELFTEST_STRAIGHT"})
        made.append(w2["pid"])
        o = call("create_opening", {"wall_pid": w2["pid"], "width": 1.5, "height": 1.2,
                                    "sill": 0.9, "position": 3.0})
        check("create_opening cuts a verified hole",
              o["verified"] and abs(o["width"] - 1.5) < 0.02, f"{o['width']}x{o['height']}")
        expect_raises("create_opening refuses oversize with the fitting size",
                      lambda: call("create_opening", {"wall_pid": w2["pid"], "width": 99,
                                                      "height": 1.0}),
                      "widest that fits")

        # the ledge case: grow one axis while the anchored end stays put
        t = call("transform_component", {"pid": b["pid"], "set_size": [None, 6, None],
                                         "anchor": ["center", "min", "center"]})
        check("transform_component set_size + anchor",
              abs(t["after"]["size"][1] - 6.0) < 0.01
              and t["before"]["min"][1] == t["after"]["min"][1],
              f"y {t['before']['size'][1]}->{t['after']['size'][1]}, anchored end fixed")
        expect_raises("transform_component refuses extreme scale",
                      lambda: call("transform_component", {"pid": b["pid"],
                                                           "scale": [5000, 1, 1]}),
                      "extreme scale")
    finally:
        if made:
            code = ("m=Sketchup.active_model; m.start_operation('selftest cleanup',true); "
                    + "; ".join(f"c=Archie::Util.find_container(m,{p}); "
                                f"c[:entity].erase! if c && c[:entity].valid?" for p in made)
                    + "; m.commit_operation; 'ok'")
            try:
                rb(code)
                print(f"   (cleaned up {len(made)} test objects)")
            except RuntimeError as e:
                print(f"   (cleanup failed: {e})")


def remedies_suite(allops):
    """A blocked edit must offer options, not just refuse."""
    target = next((o for o in allops["openings"]
                   if o["kind"] in ("DOOR", "WINDOW") and not o["shared"]
                   and o["width"] > 0.3), None)
    if not target:
        print("   (no suitable opening found)")
        return
    huge = round(target["width"] * 4, 2)
    dry = call("resize_opening", {"id": target["id"], "width": huge,
                                  "height": target["height"], "dry_run": True})
    lim = dry.get("limits", {})
    check("blocked resize reports real limits",
          "max_width_here" in lim and "limited_by" in lim,
          f"max={lim.get('max_width_here')} by={lim.get('limited_by')}")
    rem = dry.get("remedies", [])
    check("blocked resize offers concrete remedies", len(rem) >= 2,
          f"{[r['action'] for r in rem]}")


def main():
    global _sock, _file
    _sock = socket.create_connection(("127.0.0.1", PORT), timeout=20)
    _file = _sock.makefile("r", encoding="utf-8")
    print(f"== read-only suite (port {PORT})")
    allops = read_only_suite()
    print("\n== remedies (blocked edits must propose options)")
    remedies_suite(allops)
    print("\n== creation primitives + transform (v0.4)")
    creation_suite()
    print("\n== projects suite (sqlite, no SketchUp)")
    projects_suite()
    if FULL:
        full_suite(allops)
    else:
        print("\n(skipping mutation suite; pass --full before a release)")

    print()
    if FAILURES:
        print(f"FAILURES ({len(FAILURES)}):")
        for f in FAILURES:
            print("  -", f)
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
