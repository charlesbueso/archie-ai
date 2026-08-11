"""Client/project substrate: SQLite at ~/Archie/archie.db, exposed as MCP
tools so 'open the Juarez house for Omar' works inside a normal Claude
conversation. Stdlib sqlite3 — no new dependencies."""
from __future__ import annotations

import sqlite3
import unicodedata
from datetime import datetime
from pathlib import Path

from .bridge import bridge
from .config import CFG

SCHEMA = """
CREATE TABLE IF NOT EXISTS clients (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  contact_email TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
  id INTEGER PRIMARY KEY,
  client_id INTEGER NOT NULL REFERENCES clients(id),
  name TEXT NOT NULL,
  model_path TEXT NOT NULL,
  brief TEXT DEFAULT '',
  created_at TEXT NOT NULL,
  UNIQUE(client_id, name)
);
"""


def _db() -> sqlite3.Connection:
    con = sqlite3.connect(CFG["db_path"])
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    return con


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _norm(s: str) -> str:
    """Accent- and case-insensitive key for matching names.

    BUG-11: 'Casa Cumbres de Juarez' did not match 'Casa Cumbres de Juárez'.
    For a Mexican product that is a constant papercut — people and agents
    both type without accents. Names are STORED as written and only
    normalized for comparison.
    """
    nfd = unicodedata.normalize("NFD", (s or "").strip())
    stripped = "".join(c for c in nfd if not unicodedata.combining(c))
    return " ".join(stripped.casefold().split())


# --------------------------------------------------------------- clients ---

def create_client(name: str, contact_email: str = "", notes: str = "") -> dict:
    name = name.strip()
    if not name:
        raise ValueError("client name cannot be empty")
    existing = next((c for c in list_clients() if _norm(c["name"]) == _norm(name)), None)
    with _db() as con:
        if existing:
            con.execute(
                "UPDATE clients SET contact_email=?, notes=? WHERE id=?",
                (contact_email or existing["contact_email"],
                 notes or existing["notes"], existing["id"]))
            row = con.execute("SELECT * FROM clients WHERE id=?", (existing["id"],)).fetchone()
            return {**dict(row), "created": False, "updated": True}
        con.execute(
            "INSERT INTO clients(name, contact_email, notes, created_at) VALUES(?,?,?,?)",
            (name, contact_email, notes, _now()))
        row = con.execute("SELECT * FROM clients WHERE name=?", (name,)).fetchone()
    return {**dict(row), "created": True, "updated": False}


def list_clients() -> list[dict]:
    with _db() as con:
        rows = con.execute(
            "SELECT c.*, COUNT(p.id) AS projects FROM clients c "
            "LEFT JOIN projects p ON p.client_id=c.id GROUP BY c.id ORDER BY c.name"
        ).fetchall()
    return [dict(r) for r in rows]


def find_client(name: str) -> dict:
    key = _norm(name)
    matches = [c for c in list_clients() if _norm(c["name"]) == key]
    if not matches:
        matches = [c for c in list_clients() if key and key in _norm(c["name"])]
    if not matches:
        raise ValueError(f"client {name!r} not found — create_client first "
                         f"(existing: {[c['name'] for c in list_clients()]})")
    if len(matches) > 1:
        raise ValueError(f"ambiguous client {name!r}: {[c['name'] for c in matches]}")
    return matches[0]


def delete_client(name: str, delete_projects: bool = False) -> dict:
    """BUG-16: there was no way to remove test data created by mistake."""
    c = find_client(name)
    kids = [p for p in list_projects() if p["client_id"] == c["id"]]
    if kids and not delete_projects:
        raise ValueError(
            f"client {c['name']!r} still has {len(kids)} project(s): "
            f"{[p['name'] for p in kids]}. Pass delete_projects=true to remove them too.")
    with _db() as con:
        con.execute("DELETE FROM projects WHERE client_id=?", (c["id"],))
        con.execute("DELETE FROM clients WHERE id=?", (c["id"],))
    return {"deleted_client": c["name"], "deleted_projects": [p["name"] for p in kids]}


# -------------------------------------------------------------- projects ---

def create_project(client_name: str, name: str, model_path: str, brief: str = "",
                   allow_repoint: bool = False) -> dict:
    name = name.strip()
    if not name:
        raise ValueError("project name cannot be empty")
    mp = str(Path(model_path))
    # BUG-09: the docstring promised the file must exist but nothing checked,
    # so the failure surfaced much later at open_project.
    if not Path(mp).exists():
        raise FileNotFoundError(
            f"model file does not exist: {mp}. Create the project only after the "
            ".skp is saved, or fix the path.")
    if Path(mp).suffix.lower() != ".skp":
        raise ValueError(f"model_path must point to a .skp file (got {Path(mp).suffix!r})")

    client = find_client(client_name)
    existing = next((p for p in list_projects()
                     if p["client_id"] == client["id"] and _norm(p["name"]) == _norm(name)), None)

    with _db() as con:
        if existing:
            # BUG-08: re-registering silently repointed the project at a new
            # file. A typo could send later save_model/open_project calls at
            # the wrong .skp — including one inside .archie/versions.
            if str(Path(existing["model_path"])) != mp and not allow_repoint:
                raise ValueError(
                    f"project {existing['name']!r} already points at "
                    f"{existing['model_path']}. To move it to {mp}, pass "
                    f"allow_repoint=true (this changes which file future edits "
                    f"and saves touch).")
            con.execute("UPDATE projects SET model_path=?, brief=? WHERE id=?",
                        (mp, brief or existing["brief"], existing["id"]))
            row = con.execute(
                "SELECT p.*, c.name AS client FROM projects p JOIN clients c "
                "ON c.id=p.client_id WHERE p.id=?", (existing["id"],)).fetchone()
            return {**dict(row), "created": False, "updated": True,
                    "repointed": str(Path(existing["model_path"])) != mp}
        con.execute(
            "INSERT INTO projects(client_id, name, model_path, brief, created_at) "
            "VALUES(?,?,?,?,?)", (client["id"], name, mp, brief, _now()))
        row = con.execute(
            "SELECT p.*, c.name AS client FROM projects p JOIN clients c "
            "ON c.id=p.client_id WHERE p.client_id=? AND p.name=?",
            (client["id"], name)).fetchone()
    return {**dict(row), "created": True, "updated": False, "repointed": False}


def list_projects(client_name: str = "") -> list[dict]:
    with _db() as con:
        rows = con.execute(
            "SELECT p.*, c.name AS client FROM projects p "
            "JOIN clients c ON c.id=p.client_id ORDER BY c.name, p.name").fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["model_exists"] = Path(d["model_path"]).exists()
        out.append(d)
    if client_name.strip():
        key = _norm(client_name)
        out = [p for p in out if _norm(p["client"]) == key]
    return out


def find_project(project_name: str) -> dict:
    key = _norm(project_name)
    allp = list_projects()
    matches = [p for p in allp if _norm(p["name"]) == key]
    if not matches:
        matches = [p for p in allp if key and key in _norm(p["name"])]
    if not matches:
        raise ValueError(f"no project matching {project_name!r} "
                         f"(existing: {[p['name'] for p in allp]})")
    if len(matches) > 1:
        raise ValueError(f"ambiguous project {project_name!r}: "
                         f"{[(p['client'], p['name']) for p in matches]}")
    return matches[0]


def delete_project(project_name: str) -> dict:
    p = find_project(project_name)
    with _db() as con:
        con.execute("DELETE FROM projects WHERE id=?", (p["id"],))
    return {"deleted_project": p["name"], "client": p["client"],
            "note": "the .skp file and its .archie/versions were NOT touched"}


def open_project(project_name: str) -> dict:
    from .versioning import create_snapshot, model_ref  # late import (cycle)
    p = find_project(project_name)
    if not Path(p["model_path"]).exists():
        raise FileNotFoundError(f"model file missing: {p['model_path']}")
    safety = None
    ref = model_ref()
    if ref.get("path") and ref.get("modified"):
        safety = create_snapshot("auto before switching project", auto=True,
                                 tool="open_project")
    bridge().send("open_model", {"path": p["model_path"], "discard_unsaved": True},
                  timeout=900)
    return {"opened": p["model_path"], "project": p["name"], "client": p["client"],
            "brief": p["brief"], "safety_snapshot": safety}


def set_project_brief(project_name: str, brief: str) -> dict:
    p = find_project(project_name)
    with _db() as con:
        con.execute("UPDATE projects SET brief=? WHERE id=?", (brief, p["id"]))
    return {"project": p["name"], "brief": brief}


def get_project_brief(project_name: str) -> dict:
    p = find_project(project_name)
    return {"project": p["name"], "client": p["client"], "brief": p["brief"],
            "model_path": p["model_path"], "model_exists": Path(p["model_path"]).exists()}
