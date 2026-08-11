"""Snapshot-on-write versioning.

Design (validated against an 85MB production model):
- A snapshot is `model.save_copy()` of the CURRENT IN-MEMORY state into
  <model dir>/.archie/versions/<ts>--<label>.skp. The working file on disk is
  never touched, so snapshots are safe mid-edit with unsaved changes.
- sha256 dedup: a snapshot byte-identical to the previous one is discarded,
  so auto-snapshots cost nothing when nothing changed.
- restore = safety-snapshot current state, copy the version file over the
  working file, reopen. NEVER built on SketchUp's native undo —
  send_action("editUndo:") is queued and silently no-ops.
- manifest.jsonl beside the versions is the provenance log (append-only).
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import time
from datetime import datetime
from pathlib import Path

from .bridge import bridge
from .config import CFG


def _slug(label: str) -> str:
    s = re.sub(r"[^\w\-]+", "-", label.strip().lower()).strip("-")
    return (s or "snapshot")[:48]


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def model_ref() -> dict:
    return bridge().send("get_model_ref")


def _dirs(model_path: str) -> tuple[Path, Path]:
    root = Path(model_path).parent / ".archie"
    vdir = root / "versions"
    vdir.mkdir(parents=True, exist_ok=True)
    return vdir, root / "manifest.jsonl"


def _manifest_rows(manifest: Path) -> list[dict]:
    if not manifest.exists():
        return []
    rows = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def create_snapshot(label: str, auto: bool = False, tool: str | None = None) -> dict:
    ref = model_ref()
    if not ref.get("path"):
        return {"skipped": True,
                "reason": "model has never been saved — use SketchUp's Save As once, "
                          "then snapshots work"}
    vdir, manifest = _dirs(ref["path"])
    rows = _manifest_rows(manifest)
    last = rows[-1] if rows else None

    # Dedup on the extension's transaction counter (edit_seq): bumped on
    # every commit/undo/redo, reset (safely, toward extra snapshots) on
    # SketchUp restart. File bytes can't be the key (save_copy embeds a
    # timestamp) and Model#guid proved static across edits in SU2025.
    # Skipping BEFORE save_copy means an unchanged 85MB model costs nothing.
    seq = ref.get("edit_seq")
    # BUG-01 belt-and-braces: only trust edit_seq for dedup when the extension
    # confirms its transaction observer is actually alive. If the observer is
    # dead the counter is frozen and deduping would silently disable the whole
    # safety net, so fall through and take the snapshot.
    observer_ok = ref.get("observer_alive", False)
    if (observer_ok and last and seq is not None and last.get("edit_seq") == seq
            and last.get("model") == Path(ref["path"]).name
            and (vdir / last.get("file", "")).exists()):
        # BUG-18: say which file the caller's snapshot request resolved to
        return {"deduped": True, "file": last.get("file"),
                "identical_to": last.get("file"), "label": label,
                "edit_seq": seq, "auto": auto, "tool": tool,
                "reason": "model unchanged since that snapshot"}

    ts = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    tmp = vdir / f".tmp-{ts}-{int(time.time()*1000) % 1000}.skp"
    bridge().send("save_copy", {"path": str(tmp)}, timeout=600)
    sha = _sha256(tmp)

    final = vdir / f"{ts}--{_slug(label)}.skp"
    tmp.rename(final)
    # BUG-19: every entry carries the same keys, so callers never have to
    # guess whether a field is missing or meaningfully absent.
    entry = {
        "ts": time.time(), "iso": datetime.now().isoformat(timespec="seconds"),
        "label": label, "file": final.name, "sha256": sha,
        "bytes": final.stat().st_size, "auto": auto, "tool": tool,
        "model": Path(ref["path"]).name, "edit_seq": seq,
        "observer_alive": observer_ok,
    }
    with manifest.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    _prune(vdir)
    return entry


def _prune(vdir: Path) -> None:
    """Disk budget: keep the newest max_versions snapshot files."""
    keep = int(CFG.get("max_versions", 20))
    files = sorted(vdir.glob("*.skp"))
    for old in files[:-keep] if len(files) > keep else []:
        old.unlink(missing_ok=True)


def snapshot_disk_state(label: str, tool: str) -> dict | None:
    """Preserve the CURRENT ON-DISK .skp as a version before overwriting it.

    Distinct from create_snapshot, which captures in-memory state via
    save_copy. Used by save_model so the previous saved state is never lost.
    Writes through the same manifest schema as everything else (BUG-19).
    """
    ref = model_ref()
    path = ref.get("path")
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    vdir, manifest = _dirs(path)
    sha = _sha256(p)
    rows = _manifest_rows(manifest)
    if rows and rows[-1].get("sha256") == sha:
        return {"deduped": True, "file": rows[-1].get("file"),
                "identical_to": rows[-1].get("file"), "label": label,
                "auto": True, "tool": tool,
                "reason": "on-disk file already captured"}
    ts = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    dest = vdir / f"{ts}--{_slug(label)}.skp"
    shutil.copy2(p, dest)
    entry = {
        "ts": time.time(), "iso": datetime.now().isoformat(timespec="seconds"),
        "label": label, "file": dest.name, "sha256": sha,
        "bytes": dest.stat().st_size, "auto": True, "tool": tool,
        "model": p.name, "edit_seq": ref.get("edit_seq"),
        "observer_alive": ref.get("observer_alive", False),
    }
    with manifest.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    _prune(vdir)
    return entry


def auto_snapshot(tool: str) -> dict | None:
    """Called before every mutating tool. Fails CLOSED (raises) if a snapshot
    was expected but could not be written — versioning is the safety story."""
    if not CFG.get("autosnapshot", True):
        return None
    return create_snapshot(f"auto before {tool}", auto=True, tool=tool)


def list_versions() -> dict:
    ref = model_ref()
    if not ref.get("path"):
        return {"model": None, "versions": [],
                "note": "model has never been saved"}
    vdir, manifest = _dirs(ref["path"])
    out = []
    for row in _manifest_rows(manifest):
        f = vdir / row.get("file", "")
        out.append({**row, "exists": f.exists()})
    return {"model": ref["path"], "versions_dir": str(vdir), "versions": out}


def restore_version(version_file: str, confirm: bool) -> dict:
    if not confirm:
        return {"restored": False,
                "note": "pass confirm=true to restore — this replaces the working "
                        "file on disk with the chosen version and reopens it "
                        "(a safety snapshot of the current state is taken first)"}
    ref = model_ref()
    if not ref.get("path"):
        raise RuntimeError("no saved model is open; cannot restore")
    model_path = Path(ref["path"])
    vdir, _ = _dirs(str(model_path))
    src = vdir / version_file
    if not src.exists():
        raise FileNotFoundError(f"version not found: {src}")
    safety = create_snapshot("auto before restore", auto=True, tool="restore_version")

    # Write the working file only while SketchUp does NOT have it open, or
    # Windows' file lock rejects the copy. Sequence:
    #   1. open the version in SketchUp   -> releases the working file's lock
    #   2. save_copy version -> working   -> version content lands on the
    #                                         canonical path (path unlocked)
    #   3. reopen the working file         -> user ends on the working file,
    #                                         now containing the version
    b = bridge()
    b.send("open_model", {"path": str(src), "discard_unsaved": True}, timeout=900)
    b.send("save_copy", {"path": str(model_path)}, timeout=900)
    b.send("open_model", {"path": str(model_path), "discard_unsaved": True}, timeout=900)
    return {"restored": True, "version": version_file,
            "model": str(model_path), "safety_snapshot": safety}
