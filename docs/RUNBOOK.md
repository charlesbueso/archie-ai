# Archie runbook (operator / developer)

## Daily development loop

1. SketchUp open with a saved model; Archie extension autostarts its server
   on the port in `~/Archie/config.json` (dev machine: **9877**, product
   default **9876**).
2. Edit Ruby in `extension/archie_mcp/` → hot-patch the running server
   without restarting SketchUp (works because dev_mode=true):

   ```
   .venv/Scripts/python.exe tools/smoke_tcp.py eval_ruby \
     '{"code":"[\"util\",\"introspect\",\"edit\",\"versioning\"].each { |f| load \"B:/repos/archie-ai/extension/archie_mcp/#{f}.rb\" }; \"patched\""}'
   ```

   (`server.rb`/`main.rb` changes need a SketchUp restart, or reinstall the
   .rbz.) **Also copy changed files to the Plugins dir** or the next SketchUp
   launch runs stale code:
   `C:\Users\papia\AppData\Roaming\SketchUp\SketchUp 2025\SketchUp\Plugins\archie_mcp\`
3. Edit Python in `server/archie_mcp/` → editable install picks it up on the
   next server spawn; a running Claude session keeps the old process until
   the session restarts.
4. Test tiers (each assumes the tier below passed):
   - `tools/smoke_tcp.py` — raw bridge, read-only
   - `tools/smoke_archie.py --mutate` — tool implementations + versioning
     round-trip (mutates the PROPUESTA copy only, restores spec state)
   - `tools/smoke_mcp_stdio.py` — full MCP protocol as Claude Desktop speaks it

## Config (`~/Archie/config.json`)

| Key | Default | Notes |
|---|---|---|
| `port` / `host` | 9876 / 127.0.0.1 | Both halves read this file — they cannot disagree |
| `autostart` | true | Extension starts its server when SketchUp loads |
| `dev_mode` | false | Gates `eval_ruby` (both halves check it) |
| `autosnapshot` | true | Snapshot before every mutating tool |
| `max_versions` | 20 | Snapshot files kept per model (manifest keeps full history) |
| `log_dir` | ~/Archie/logs | Tool-call JSONL; dev machine points at repo `logs/` for the dashboard |

## Versioning internals

- `<model dir>/.archie/versions/*.skp` + `manifest.jsonl` (append-only).
- Snapshots are `model.save_copy()` of in-memory state; the working file is
  untouched. Restore = safety-snapshot → open version → `save_copy` onto the
  working path (three-step dance because Windows locks the open file) →
  reopen working file.
- Dedup: manifest stores `edit_seq` (extension-side transaction counter). If
  unchanged since the last snapshot, no copy is written at all.
- `save_model` first preserves the previous on-disk state as a version.

## Ports & processes

| Who | What |
|---|---|
| SketchUp (Archie extension) | TCP listener on the configured port |
| `archie-mcp.exe` (per Claude session) | stdio ↔ that TCP port |
| Dashboard | `python -m http.server 8000` in repo root → `/dashboard/`; reads `logs/mcp_calls.jsonl` |

Health: ask Claude to run `health_check`, or `tools/smoke_tcp.py` directly.
Port stuck (SketchUp crashed): find with
`Get-NetTCPConnection -LocalPort 9877 -State Listen` and restart SketchUp.

## Release procedure

1. Bump `server/archie_mcp/__init__.py` `__version__` and
   `extension/archie_mcp/server.rb` `VERSION` + `archie_mcp.rb` `ex.version`.
2. `.venv/Scripts/python.exe tools/build.py` → `dist/`.
3. Run all three smoke suites against the freshly-installed .rbz (reinstall
   via Extension Manager, restart SketchUp).
4. Ship `dist/archie-beta-<v>.zip` to beta users (see INSTALL_BETA.md).
   Before wide release: sign the .rbz at
   https://extensions.sketchup.com/extension/sign (server-side, OS-agnostic)
   so users skip the Unrestricted-policy step.

## Known limitations (v0.2)

- `resize_opening` assumes axis-aligned walls (fine for CASA + scratch;
  rotated buildings need transform-local math — roadmap).
- No `move_wall` typed tool yet; complex ops go through dev-mode `eval_ruby`.
- Multi-light assemblies: resize each light; the spanning recess is refused.
- Restore reopens the model (~30–60 s on an 85 MB file) — expected, not a hang.
- The full restore→reopen cycle passed its file-level tests; the end-to-end
  reopen was deliberately not fired repeatedly against the live 85 MB model.
  Exercise it once per release on a scratch model.

## Security posture

- Bridge binds `127.0.0.1` only. No auth on the socket — same-machine trust,
  matching the validation rig; add a token before any multi-user scenario.
- `eval_ruby` (arbitrary unsandboxed Ruby) requires `dev_mode: true` in the
  user's own config file; beta default is off, and the Python side refuses
  before even reaching Ruby.
- Every tool call is logged locally to `mcp_calls.jsonl` for audit.
