# Archie beta — install guide / guía de instalación

Archie connects **Claude Desktop** to **SketchUp** so you can inspect and edit
real models by chatting: list doors and windows, resize openings, change slab
thicknesses, keep automatic versions of every change, and organize models by
client and project.

> **None of this needs memorized commands.** Claude reads Archie's tool
> descriptions and works out what to call from whatever you say in your own
> words. Unsure what's possible? Just ask: *"What can Archie do?"*
>
> **Nada de esto requiere comandos exactos** — pídeselo a Claude con tus
> propias palabras. Si tienes dudas: *"¿Qué puede hacer Archie?"*

---

## 🇲🇽 Guía rápida (español)

Necesitas: **SketchUp 2021 o más nuevo (de escritorio)**, **Claude Desktop**
con tu propia cuenta de Claude, y 10 minutos.

1. **Descomprime** `archie-beta-*.zip` en una carpeta permanente (no la
   borres después — Claude usa los archivos de esta carpeta). Por ejemplo
   `Documentos/Archie`.
2. **Instala uv** (una sola vez) — abre la Terminal y pega:
   - Mac: `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - Windows (PowerShell): `irm https://astral.sh/uv/install.ps1 | iex`
3. **Ejecuta el instalador** desde la carpeta descomprimida:
   - Mac: `bash install/install-mac.sh`
   - Windows: clic derecho en `install\install-windows.ps1` → *Run with PowerShell*
4. **Instala la extensión en SketchUp**: Window → Extension Manager →
   *Install Extension* → elige `archie_sketchup_v0.4.0.rbz` de la carpeta.
   Si lo rechaza: Window → Preferences → Extensions → política *Unrestricted*.
   **Reinicia SketchUp.** El servidor de Archie arranca solo.
5. **Cierra Claude Desktop POR COMPLETO** (icono de la bandeja / barra de menú
   → Quit) y ábrelo de nuevo.
6. **Prueba**: abre un modelo `.skp` guardado en SketchUp y dile a Claude:
   *"Corre health_check en Archie"*. Debe responder que SketchUp está
   conectado. Luego prueba: *"Lista las ventanas y puertas del modelo"*.
7. **Organiza por cliente y proyecto** (opcional): *"Registra un cliente
   llamado [nombre] y crea un proyecto con este modelo"*. Después, en
   cualquier chat nuevo: *"Abre el proyecto de [nombre]"* — Claude lee el
   resumen del proyecto automáticamente.

**Seguridad**: trabaja siempre sobre una **copia** del modelo durante la beta.
Archie guarda versiones automáticas en una carpeta `.archie/versions` junto a
tu archivo — *"restaura la versión de antes del cambio"* las recupera.

---

## 🇺🇸 Full guide (English)

### What you need

| Requirement | Notes |
|---|---|
| SketchUp **desktop** 2021+ (2024+ recommended) | SketchUp Free/web has no extension support — desktop only |
| Claude Desktop | Signed into **your own** Claude account (usage bills to you) |
| `uv` | One-line install, step 2 below. No Python setup needed — uv manages it |
| ~500 MB free disk per active project | Automatic versions of an ~85 MB model add up; oldest are pruned automatically |

### Install

1. **Unzip** `archie-beta-<version>.zip` somewhere permanent (e.g.
   `Documents/Archie`). Claude Desktop runs the server from this folder, so
   don't delete or move it afterwards.

2. **Install uv** (once):
   - macOS: `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - Windows (PowerShell): `irm https://astral.sh/uv/install.ps1 | iex`

3. **Run the installer** from the unzipped folder:
   - macOS: `bash install/install-mac.sh`
   - Windows: right-click `install\install-windows.ps1` → *Run with PowerShell*

   It backs up your Claude Desktop config, registers the `archie` server, and
   creates `~/Archie/config.json` with safe defaults. Re-running is safe.

   *Alternative*: double-click `archie-<version>.mcpb` to install through
   Claude Desktop's extension flow instead (Settings → Extensions). Use one
   path or the other, not both.

4. **Install the SketchUp extension**: SketchUp → Window → Extension Manager
   → *Install Extension* → pick `archie_sketchup_v<version>.rbz` from the
   unzipped folder. If Extension Manager refuses (unsigned during beta):
   Window → Preferences → Extensions → set policy to *Unrestricted*, retry.
   **Restart SketchUp.** Archie's bridge autostarts with SketchUp from then
   on — there is nothing to click.

5. **Fully quit Claude Desktop** — closing the window is not enough; use the
   system-tray (Windows) or menu-bar (macOS) icon → Quit — then reopen it.

### First test (2 minutes)

None of the phrases below are magic words — Claude reads Archie's tool
descriptions and works out what to call from whatever you actually say. This
is just a fast, repeatable script to prove everything's wired up.

1. Open any **saved** `.skp` in SketchUp (during beta: work on a **copy** of
   real projects).
2. In Claude Desktop:
   - *"Run health_check on Archie"* → should report SketchUp connected and
     which model is open.
   - *"Survey this model — slabs, storeys, structure"* → `get_model_info`
   - *"List all door and window openings with sizes"* → `list_openings`
3. Try an edit on a copy: *"Make that 1.20 window 1.50 wide and 1.80 tall
   with a 0.50 sill"*. Claude resizes it, verifies the result, and a snapshot
   is saved automatically first.
4. Versioning: *"List versions"* / *"Restore the version from before that
   change"* (Claude will ask you to confirm before restoring).
5. Organize by client — your own words work fine: *"Register a new client
   called Acme and set up a project with this model"*. Later, in any new
   conversation: *"Open the Acme project"* — Claude reads back the project
   brief automatically.

### What Archie can do today (v0.4)

- **Read**: model survey (slabs/losas, storey levels, structure), door &
  window inventory with sizes and sill heights, current selection.
- **Show you where something is**: ask *"show me that window"* and Archie
  points SketchUp's camera at it and selects it. Use this to confirm you and
  Claude mean the same element before editing.
- **Edit**: resize door/window openings (width × height × sill), change slab
  thickness (holding the floor level or the soffit fixed). Every edit is
  verified *before* it is committed — if the wall can't accommodate what you
  asked, the change is rolled back and Claude tells you why. Each edit is one
  Ctrl+Z in SketchUp.
- **Versions**: automatic snapshot before every edit (skipped when nothing
  changed), named snapshots on demand, list + restore. Stored in
  `.archie/versions/` next to each model.
- **Projects**: register clients and projects ("open the Juárez house")
  with a brief Claude reads for context. Accent-insensitive, so *Juarez*
  finds *Juárez*.
- **Move, scale and resize anything**: not just doors and windows — a ledge, a
  sill, a parapet, a block. Say *"make that ledge stick out 20cm further"* and
  it grows from the end you mean, staying attached to the wall.
- **Build new geometry**: boxes, slabs, walls (any orientation), and cutting
  new doors/windows into existing walls. A pool is a handful of boxes, so
  Claude can compose one without a dedicated tool.
- **Works on downloaded models**: library models are almost entirely repeated
  component instances, which normally can't be edited without changing every
  copy. Archie detaches the one you're working on automatically and tells you
  how many siblings it left alone.
- **Offers options instead of refusing**: when a window won't fit, you get the
  real numbers — *"the wall allows 0.67m; I can extend the wall 1.67m, move
  the neighbouring window, or slide this one along"* — and pick.
- **Tells you about problems it finds**: degenerate slabs, openings below
  floor level and other anomalies are reported, never quietly skipped.

Not yet: adding a whole storey in one step, and walls that aren't
axis-aligned when *cutting openings* (creating angled walls is fine).

### Troubleshooting

| Symptom | Fix |
|---|---|
| health_check says SketchUp not reachable | Is SketchUp open? Extensions menu → Archie → Status. If missing, the .rbz isn't installed — step 4. |
| `archie` missing in Claude Desktop | You didn't FULLY quit Claude Desktop (tray/menu-bar → Quit), or step 3 didn't run. |
| "eval_ruby is disabled" | Correct — that developer tool is off for beta. The typed tools cover the supported operations. |
| Port conflict / second copy of SketchUp | Only one SketchUp can hold the port. Edit `~/Archie/config.json` → `"port"` and restart both SketchUp and Claude Desktop. |
| "This was 1 of N copies, I made it independent" | Normal on downloaded models. Archie detached this one so your edit didn't change all N. If you *wanted* all of them changed, say so and it will apply to the rest. |
| An edit says it was "rolled back" | Deliberate: the result didn't match what you asked, so nothing was changed. The message lists what would make it possible — pick one. |

### Privacy & safety notes

- Everything runs **locally**: Claude Desktop ↔ a local server ↔ SketchUp on
  `127.0.0.1`. Your model never leaves your machine through Archie itself
  (normal Claude conversation content goes to Anthropic as usual).
- Tool calls are logged to `~/Archie/logs/mcp_calls.jsonl` on your machine so
  you can audit exactly what was done.
- The arbitrary-code tool (`eval_ruby`) is **disabled** for beta installs.
