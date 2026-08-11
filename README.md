# Archie — SketchUp for Claude

Edit real SketchUp models from a Claude conversation: typed geometry tools,
automatic snapshot versioning, and client/project management. Claude Desktop
is the chat surface; Archie is the substrate it talks to.

```
Claude Desktop / Claude Code
        │  MCP (stdio)
        ▼
archie-mcp (Python, server/)          ~/Archie/archie.db   clients & projects
        │  NDJSON over TCP 127.0.0.1:9876                  <model>/.archie/   versions
        ▼
Archie extension (Ruby, extension/)   runs inside SketchUp, autostarts
```

## Layout

| Path | What |
|---|---|
| `extension/` | SketchUp Ruby extension: NDJSON-TCP server, typed geometry ops |
| `server/` | Python MCP server (`archie-mcp`): 18 tools, versioning, projects DB |
| `install/` | Beta installers (Claude Desktop config merge, Win + macOS) |
| `tools/build.py` | Builds `dist/`: `.rbz`, `.mcpb`, beta zip |
| `tools/smoke_*.py` | Live test suites (raw TCP, in-process, full MCP stdio) |
| `docs/` | `INSTALL_BETA.md` (user guide EN/ES), `RUNBOOK.md` (operator guide) |
| `dashboard/` | Static page tailing the tool-call log |
| `test/` | Validation-phase assets: models, TEST.md protocol, CASA knowledge base |
| `vendor/`, `setup.ps1`, `SETUP.md` | **Legacy** validation rig (upstream sketchup-mcp) — superseded by the above |

## The 21 tools

- **System**: `health_check`
- **Read**: `get_model_info` (slabs, storeys, structure), `list_openings`
  (door/window inventory + classification; `summary=true` first on an
  unfamiliar model), `get_selection`, `locate` (point the camera at an
  element and select it)
- **Edit** (auto-snapshot first, verified *inside* the undo operation and
  rolled back if verification fails): `resize_opening`, `set_slab_thickness`
- **Versions**: `create_snapshot`, `list_versions`, `restore_version`,
  `save_model`
- **Projects**: `create_client`, `delete_client`, `create_project`,
  `delete_project`, `list_clients`, `list_projects`, `open_project`,
  `get_project_brief`, `set_project_brief`
- **Dev-only** (off unless `dev_mode: true`): `eval_ruby`

All I/O is in **meters** (SketchUp's Ruby API is inches internally; the
extension converts at the boundary).

## Engineering rules the code encodes

Learned the hard way against a real 85 MB client model — see
`test/CASA_CUMBRES_KB.md` for the full war story:

1. Move vertices with **one `transform_by_vectors`** call; sequential
   transforms let SketchUp split transiently-non-planar faces and destroy
   openings.
2. Select vertices by **region**, not loop membership — stepped window frames
   carry vertices between the loops.
3. Clamp region margins against **sibling openings** (mullions sit 5 cm away)
   and clamp deltas to the wall shell (floor-level sills land cleanly).
4. Target by **persistent id + position**, never by name (`make_unique`
   renames definitions) and never `entityID` (doesn't survive reload).
5. Refuse edits on **shared/instanced geometry** — including via instanced
   *ancestors*, which per-definition `count_instances` misses.
6. Snapshot dedup keys on a **transaction counter** (`edit_seq` via model
   observers): `save_copy` bytes differ even for an unchanged model, and
   `Model#guid` does not change on edits.
7. Never rely on `Sketchup.send_action("editUndo:")` — queued, silently
   unreliable. Restores are file-level.
8. **Keep Ruby references to observers.** `add_observer(Foo.new)` lets the
   instance be garbage collected and the callbacks stop firing *silently and
   permanently*. This disabled the entire snapshot safety net in v0.2
   (BUG-01). Anything safety-critical must also work without the observer.
9. Cluster/classify geometry at one canonical threshold and filter only for
   display — two call sites with different minimum sizes disagreed about
   whether the same hole was a WINDOW or an ASSEMBLY (BUG-05).
10. Verify a mutation *inside* its undo operation and `abort_operation` when
    verification fails, so a bad edit is never left in the model (BUG-02).
11. Flag anomalies, never omit them. A degenerate slab dropped from the
    inventory became invisible orphaned geometry the user could not find or
    repair (BUG-04).

## Dev quickstart

```powershell
# Python side (editable)
uv pip install -e ./server --python .venv/Scripts/python.exe

# Ruby side: copy extension/ into SketchUp's Plugins dir (build.py makes the .rbz)
.venv/Scripts/python.exe tools/build.py

# live smoke suites (SketchUp open with a saved model, extension running)
.venv/Scripts/python.exe tools/smoke_bugs.py            # regression, ~40s, read-only
.venv/Scripts/python.exe tools/smoke_bugs.py --full     # + mutation & rollback (slow)
.venv/Scripts/python.exe tools/smoke_tcp.py             # raw bridge
.venv/Scripts/python.exe tools/smoke_mcp_stdio.py       # full MCP protocol

# probe arbitrary Ruby during development (needs dev_mode)
.venv/Scripts/python.exe tools/probe.py some_probe.rb 9876

# dashboard for the tool-call log
.venv/Scripts/python.exe -m http.server 8000   # then open /dashboard/
```

Config lives in `~/Archie/config.json` (port, autostart, `dev_mode` gating
`eval_ruby`, snapshot budget). Both halves read the same file.

## Beta distribution

`tools/build.py` → `dist/archie-beta-<v>.zip` → send to the user →
they follow `INSTALL_BETA.md` inside it. Details in `docs/RUNBOOK.md`.
