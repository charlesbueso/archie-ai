# SketchUp ↔ Claude bridge — setup

> **LEGACY** — this documents the week-one validation rig built on vendored
> `sketchup-mcp`. It served its purpose (the hypothesis validated) and is
> superseded by **Archie v0.2**: own extension + typed tools + versioning.
> Start at [README.md](README.md); users install per
> [docs/INSTALL_BETA.md](docs/INSTALL_BETA.md).

A throwaway rig for testing one thing: whether a meeting transcript can be turned
into a useful edit in a real SketchUp model.

Not a product. No auth, no backend, no Docker. When the validation is done this
either gets rebuilt properly or deleted.

---

## ⚠️ Read this before you connect anything

**This bridge gives Claude arbitrary code execution inside SketchUp.**

The MCP server exposes a tool called `eval_ruby` that runs whatever Ruby it is
given inside SketchUp's interpreter. SketchUp's Ruby is not sandboxed. Code sent
through this tool can read, write, and delete any file your user account can
touch — not just the open model.

There is no permission prompt, no dry-run, and no undo for anything outside the
model.

So:

- **Only ever open scratch files while the bridge is running.** Never a real
  project, never a client file, never anything you cannot afford to lose.
- **Stop the server when you are not testing** (Extensions → MCP Server → Stop
  Server). It listens on `127.0.0.1` only, so it is not reachable from the
  network, but a running server plus an open client file is an accident waiting
  to happen.
- Keep a pristine `test/scratch_original.skp` and restore from it between runs.

This is fine for a week of validation on scratch geometry. It is not something
you put in front of a customer.

---

## Prerequisites

| Thing        | Version           | Notes                                        |
| ------------ | ----------------- | -------------------------------------------- |
| Windows      | 10 / 11           |                                              |
| SketchUp     | 2025 (2024+ ok)   | Desktop. Ruby is bundled — no separate install |
| Python       | 3.10+             | On PATH                                      |
| Git          | any recent        | On PATH                                      |
| Claude Code  | any recent        | `claude --version`                           |
| uv           | optional          | Used if present; falls back to venv + pip    |

You do **not** need a standalone Ruby. The `.rbz` is built with .NET zip rather
than upstream's `package.rb`, which would want the `rubyzip` gem.

---

## Install

From the project root:

```powershell
.\setup.ps1
```

That is the whole scripted part. It is idempotent — re-run it any time.

It will:

1. Check prerequisites and locate SketchUp
2. Clone `mhyrr/sketchup-mcp` into `vendor/` at a **pinned commit** and verify
   the layout is what we build against
3. Create `.venv` and install the Python MCP server **from source, editable**
4. Verify the server actually imports (not just that pip exited 0)
5. Build `dist/su_mcp_v1.6.0.rbz`
6. Write `.mcp.json` registering the server with Claude Code at project scope

Add `-IncludeClaudeDesktop` if you also want it in Claude Desktop. See
[Which client](#which-client) below.

### Why the server is installed from source

The PyPI package `sketchup-mcp` is stale — v0.1.17 was uploaded 2025-03-13, the
day the repo was created. The repo has moved since. Installing from source keeps
the Python and Ruby halves version-matched.

### Why the mcp version is pinned

Upstream declares `mcp[cli]>=1.3.0` with no upper bound. Today that resolves to
`mcp` 2.x, which **removed `mcp.server.fastmcp`** — the module the server imports
on its first line. An unconstrained install produces a server that cannot start,
with a `ModuleNotFoundError` that looks like a broken install rather than a
dependency problem.

`setup.ps1` constrains to `mcp[cli]>=1.3.0,<2` at install time. Upstream's
`pyproject.toml` is left untouched.

---

## Manual steps (these need the GUI)

### 1. Install the extension

**SketchUp → Window → Extension Manager → Install Extension**, and pick:

```
dist\su_mcp_v1.6.0.rbz
```

The file is self-built and therefore **unsigned**. If Extension Manager rejects
it: **Window → Preferences → Extensions → Extension Policy → Unrestricted**, then
install again.

**Restart SketchUp.** The extension does not load until you do.

### 2. Confirm it loaded

**Window → Ruby Console**:

```ruby
Sketchup.extensions['Sketchup MCP Server']
```

Should return an extension object, not `nil`.

> Note: the extension's **name** is `Sketchup MCP Server`. `SU_MCP_SERVER` is its
> `product_id`, which is a different field —
> `Sketchup.extensions['SU_MCP_SERVER']` returns `nil` even on a correct install.
> If you looked that up somewhere, that is why it seemed broken.

### 3. Start the bridge

**Extensions → MCP Server → Start Server**

> The menu is **MCP Server**, not "SketchupMCP". Upstream registers it with
> `UI.menu("Plugins")`, which is the menu SketchUp now labels *Extensions*.

The Ruby Console should print:

```
Starting server on localhost:9876...
Server created on port 9876
Server started and listening
```

### 4. Approve the server in Claude Code (once)

Project-scope MCP servers need a one-time trust approval. Run `claude` in the
project root and accept the prompt. Then:

```
/mcp
```

`sketchup` should show as connected.

---

## Which client

**Claude Code, registered at project scope.** That is what `setup.ps1` sets up.

Reasoning:

- **Reproducible.** `.mcp.json` lives in the project. `setup.ps1` regenerates it
  with the right absolute paths on whatever machine it runs on. Claude Desktop's
  config lives in `%APPDATA%` and has to be merged into whatever else is already
  there.
- **Cheap restarts.** Picking up a config change means starting a new `claude`
  session. Claude Desktop has to be fully quit — including from the system tray —
  and closing the window is not enough. That is a genuinely common source of
  "why isn't my server showing up".
- **It tells you what is wrong.** `claude mcp list` runs a health check and
  prints the failure. Claude Desktop gives you a tool icon that is either there
  or not.
- One less app.

Claude Desktop is still worth having if a non-technical person is doing the
evaluation — pasting a long transcript into a chat window is a nicer experience
than a terminal. `setup.ps1 -IncludeClaudeDesktop` merges an entry in and backs
up the existing config to `.bak` first. Both clients can be configured at once;
they will not conflict, but do not run them against SketchUp simultaneously —
the bridge handles one connection at a time.

---

## Known gaps

Things that are wrong with the bridge and are **deliberately not fixed**, because
the point is to test the concept, not to fork the project.

### The first tool call of a session returns the wrong response

Reproducible, and worth understanding because it will bite you.

SketchUp's Ruby server handles **one request per TCP connection** and then closes
the socket ([`main.rb:112`](vendor/sketchup-mcp/su_mcp/su_mcp/main.rb#L112)). The
Python side assumes a persistent connection. On startup it opens one, and on the
first tool call it sends an internal `ping` down that socket **without reading
the reply**. The real request then goes out on an already-closed socket, and the
client reads the stale ping response instead of its own.

Measured against a mock SketchUp on port 9876:

```
call 1 (sent MARKER_1): WRONG -> MOCK: ? ok
call 2 (sent MARKER_2): OK    -> MOCK: evaluated [MARKER_2]
call 3 (sent MARKER_3): OK    -> MOCK: evaluated [MARKER_3]
```

Steady state is correct — after the first failure the socket is detected as dead
and every later call reconnects cleanly.

This only happens when SketchUp's server is already listening when the MCP server
starts, which is the normal order of operations.

**Workaround, and it is in the test prompt already:** make the first call a
throwaway (`eval_ruby` with `1 + 1`) and ignore the result.

### No undo grouping in the bridge

Upstream never calls `model.start_operation` / `commit_operation` anywhere — a
multi-step edit becomes a long tail of individual undo steps.

Fixing this properly means patching upstream, which is out of scope. But it does
not have to be fixed there: `eval_ruby` runs arbitrary Ruby, so the wrapping can
go in the Ruby that Claude sends. The test prompt in
[test/TEST.md](test/TEST.md) instructs exactly that, and the rubric checks that
one Ctrl+Z reverts everything.

### No way to read the model

The bridge exposes ten tools. Nine create or modify geometry
(`create_component`, `transform_component`, `create_dovetail`, …) and one,
`get_selection`, reads only what is currently selected.

There is **no `get_model_info`**. To find out what is in the model, Claude has to
write Ruby introspection code and run it through `eval_ruby`. It works, but it
means the read path is unstructured, and a real version of this would want a
proper tool. Rubric section A in `test/TEST.md` is watching for this.

### Most of the tools are for woodworking

`create_mortise_tenon`, `create_dovetail`, `create_finger_joint`. Upstream was
built for furniture, not buildings. Harmless, but it means the tool list is
mostly noise for architectural work, and `eval_ruby` is doing all the real work.

### Version numbers disagree

`extension.json` says `1.6.0`; `su_mcp.rb` says `ext.version = '1.5.0'`. Cosmetic.
Left alone.

### There are no GitHub releases

The task description mentioned a prebuilt v1.6.0 `.rbz` on the Releases page.
There isn't one — the repo has no releases at all. `setup.ps1` builds the `.rbz`
from source, mirroring what upstream's `package.rb` would produce.

---

## Troubleshooting

### "Could not connect to SketchUp"

The server was not started inside SketchUp. This is the most common one by a
wide margin, and it happens every time you restart SketchUp, because the bridge
does not auto-start.

1. SketchUp is running, with a model open
2. **Extensions → MCP Server → Start Server**
3. Ruby Console says `Server started and listening`
4. Confirm something is listening:

   ```powershell
   Get-NetTCPConnection -LocalPort 9876 -State Listen
   ```

If the Extensions menu has no **MCP Server** entry, the extension is not loaded —
go back to [Confirm it loaded](#2-confirm-it-loaded).

### Port 9876 already in use

The Ruby Console shows `Address already in use` on Start Server, or the bridge
connects but every call behaves strangely.

Find what is holding it:

```powershell
Get-NetTCPConnection -LocalPort 9876 -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess,
    @{n='Process';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
```

Usually one of:

- **A previous SketchUp session** that was closed without stopping the server, or
  crashed. Restart SketchUp.
- **The mock server** (`tools/mock_sketchup.py`) still running from a diagnostic.
- **A second SketchUp instance.** Only one can hold the port; the second's
  Start Server silently fails.

Kill it:

```powershell
Get-NetTCPConnection -LocalPort 9876 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
```

The port is hardcoded to `9876` in both halves. Changing it means editing
upstream, so don't — free the port instead.

### Client not fully restarted

Symptom: you changed config, and the client still shows the old state — server
missing, or listed but never connecting.

**Claude Code:** MCP config is read at session start. Exit the session
(`Ctrl+C` twice or `/exit`) and run `claude` again. Then check:

```powershell
claude mcp list
```

If it says `Pending approval`, run `claude` interactively and accept the prompt —
project-scope servers need explicit trust once.

**Claude Desktop:** closing the window does **not** restart it. It keeps running
in the system tray and holds the old config. Right-click the tray icon → Quit,
or:

```powershell
Get-Process claude -ErrorAction SilentlyContinue | Stop-Process -Force
```

Then start it again.

### Server shows connected but every call errors

Almost always SketchUp's server having stopped underneath a live client. Stop and
restart it from the Extensions menu, then start a new Claude session.

### Verifying the Python half without SketchUp

To work out whether a problem is the bridge or the extension, run the mock:

```powershell
.\.venv\Scripts\python.exe tools\mock_sketchup.py
```

It listens on 9876 and answers like the real extension does. If Claude can talk
to the mock, the Python half and the client config are fine and the problem is
inside SketchUp. **Stop the mock before starting the real server** — they fight
over the port.

### Rebuilding after an upstream change

```powershell
.\setup.ps1
```

Then reinstall the `.rbz` through Extension Manager and restart SketchUp. The
Python half is an editable install, so it picks up changes without reinstalling —
but the Ruby half is copied into SketchUp's plugins folder at install time and
does not.

---

## Layout

```
archie-ai/
├── setup.ps1              one-command install, idempotent
├── SETUP.md               this file
├── .mcp.json              generated — Claude Code server registration
├── dist/
│   └── su_mcp_v1.6.0.rbz  built extension, install via Extension Manager
├── tools/
│   └── mock_sketchup.py   fake SketchUp on 9876, for isolating faults
├── test/
│   ├── SCRATCH_MODEL.md   how to build scratch.skp
│   ├── transcript_es.md   Spanish meeting transcript — the input
│   ├── TEST.md            the prompt and the rubric
│   └── scratch.skp        you build this
└── vendor/
    └── sketchup-mcp/      upstream, pinned, unmodified
```

`.mcp.json` is generated and contains machine-specific absolute paths. `setup.ps1`
rewrites it. Nothing under `vendor/` is modified — every workaround lives in
this project's config, scripts, or prompts.
