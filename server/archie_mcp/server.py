"""Archie MCP server — the tool surface Claude Desktop / Claude Code sees.

Every tool works in METERS. Every mutating tool auto-snapshots the model
first (sha256-deduped), so one bad edit is never more than one restore away.
"""
from __future__ import annotations

import functools
import inspect

from mcp.server.fastmcp import FastMCP

from . import __version__, calllog, projects, versioning
from .bridge import BridgeDown, bridge
from .config import CFG

mcp = FastMCP("archie")


def logged(fn):
    sig = inspect.signature(fn)

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            bound = sig.bind(*args, **kwargs)
            bound.apply_defaults()
            arg_view = {k: v for k, v in bound.arguments.items()}
        except TypeError:
            arg_view = {}
        calllog.log_call(fn.__name__, arg_view)
        try:
            result = fn(*args, **kwargs)
            calllog.log_result(fn.__name__, result)
            return result
        except Exception as e:  # noqa: BLE001 — logged then re-raised for MCP
            calllog.log_error(fn.__name__, e)
            raise

    return wrapper


# --------------------------------------------------------------- system ----

@mcp.tool()
@logged
def health_check() -> dict:
    """Check the whole Archie chain: is SketchUp reachable, which model is
    open, where snapshots and the project database live. Call this first in a
    session, and whenever another tool reports a connection problem."""
    out = {"archie_mcp": __version__, "port": CFG["port"],
           "home": str(__import__("pathlib").Path(CFG["db_path"]).parent),
           "autosnapshot": bool(CFG.get("autosnapshot", True)),
           "dev_mode": bool(CFG.get("dev_mode", False))}
    try:
        info = bridge().send("archie_info")
        out.update({"sketchup_connected": True,
                    "extension_version": info.get("version"),
                    "sketchup": info.get("sketchup")})
        out["model"] = bridge().send("get_model_ref")
    except (BridgeDown, Exception) as e:  # noqa: BLE001
        out.update({"sketchup_connected": False, "error": str(e)})
    try:
        out["clients"] = len(projects.list_clients())
        out["projects"] = len(projects.list_projects())
    except Exception as e:  # noqa: BLE001
        out["db_error"] = str(e)
    return out


# --------------------------------------------------------- introspection ---

@mcp.tool()
@logged
def get_model_info(include_top_level: bool = True) -> dict:
    """Survey the open SketchUp model: slabs (losas) with thicknesses,
    storey/finished-floor levels, container counts, top-level structure.
    Call this before any editing session on a model you have not inspected
    yet — it is the map every other tool's output is relative to. All values
    in meters."""
    return bridge().send("get_model_info", {"include_top_level": include_top_level})


@mcp.tool()
@logged
def list_openings(container_pid: int = 0, min_width: float = 0.5,
                  min_height: float = 0.5, kind: str = "",
                  summary: bool = False, limit: int = 60, offset: int = 0,
                  include_furniture: bool = False) -> dict:
    """List door/window openings with classification. Doors and windows in
    real models are often just holes in wall solids; this classifies by
    geometry: DOOR = sill <=0.10m above finished floor AND head >=1.95m;
    WINDOW = sill >0.15m; AMBIGUOUS = between (reported honestly, not
    guessed); ASSEMBLY = a spanning recess around a multi-light unit (resize
    its lights individually, never the assembly).

    START WITH summary=true on an unfamiliar model — a full listing can be
    ~180 entries and will crowd out your context. Then narrow with
    kind='WINDOW' / container_pid / limit+offset.

    Each entry's `id` is the handle resize_opening takes; ids change whenever
    geometry moves, so re-list after an edit. `shared: true` cannot be edited
    (instanced geometry). `anomalies` flags things like negative sills.
    Openings inside furniture-sized containers are excluded unless
    include_furniture=true, and the count is reported. Sizes in meters."""
    params: dict = {"min_width": min_width, "min_height": min_height,
                    "summary": summary, "limit": limit, "offset": offset,
                    "include_furniture": include_furniture}
    if container_pid:
        params["container_pid"] = container_pid
    if kind:
        params["kind"] = kind.upper()
    return bridge().send("list_openings", params)


@mcp.tool()
@logged
def get_selection() -> dict:
    """What the user has selected in SketchUp right now — use it when they
    say 'this wall' or 'the window I selected'. Returns pids you can feed to
    other tools."""
    return bridge().send("get_selection")


@mcp.tool()
@logged
def locate(pid: int = 0, opening_id: str = "", select: bool = True,
           zoom: bool = True) -> dict:
    """Point SketchUp's camera at an element and select it, so the user can
    SEE which one you mean. Pass either a container `pid` or an `opening_id`
    from list_openings.

    Use this before editing anything the user described in words ("the window
    on the back wall"): locate it, ask them to confirm what is now on screen,
    then edit. Models have unnamed groups, so without this the user has to
    hunt by orbiting and clicking — which in testing took six attempts to
    find one window."""
    params: dict = {"select": select, "zoom": zoom}
    if opening_id:
        params["opening_id"] = opening_id
    elif pid:
        params["pid"] = pid
    else:
        raise ValueError("pass either pid or opening_id")
    return bridge().send("locate", params)


# ----------------------------------------------------------------- edits ---

@mcp.tool()
@logged
def make_unique(pid: int, deep: bool = True) -> dict:
    """Make instanced geometry independently editable.

    Downloaded and library models are almost entirely component instances —
    editing one would change every copy, so Archie refuses until it is made
    unique. This does that: it uniquifies the whole ancestor chain AND the
    nested geometry inside, then returns the element's NEW pid (copying a
    definition re-issues persistent ids, so the old pid is dead — always use
    `new_pid` afterwards).

    The edit tools call this automatically when needed, so reach for it
    directly only when the user wants to detach something up front. Tell the
    user afterwards how many sibling copies were left untouched."""
    return bridge().send("make_unique", {"pid": pid, "deep": deep}, timeout=600)


@mcp.tool()
@logged
def transform_component(pid: int, move: list = [], scale: list = [],
                        set_size: list = [], anchor: str = "center",
                        auto_unique: bool = True) -> dict:
    """Move, scale or resize ANY container — the general-purpose editor for
    geometry that is neither an opening nor a slab: ledges, sills, parapets,
    furniture, massing blocks.

    - `move`: [dx, dy, dz] metres.
    - `set_size`: [x, y, z] target size in metres; pass null for axes to leave
      alone (e.g. [null, 0.6, null] sets only the Y extent).
    - `scale`: [sx, sy, sz] multipliers, as an alternative to set_size.
    - `anchor`: which part stays put — "min", "center" or "max", or a
      per-axis list like ["center", "min", "center"].

    ANCHOR IS THE IMPORTANT ONE. "Make this ledge stick out 20cm further"
    means: anchor the edge that meets the wall and grow the other. Get the
    current bounds from get_model_info or locate first, decide which end must
    not move, and anchor there — otherwise the element grows in both
    directions and detaches from the building.

    Shared geometry is made unique automatically (reported in `made_unique`);
    say so to the user, since the other copies keep their original form."""
    params: dict = {"pid": pid, "anchor": anchor, "auto_unique": auto_unique}
    if move:
        params["move"] = move
    if scale:
        params["scale"] = scale
    if set_size:
        params["set_size"] = set_size
    return bridge().send("transform_component", params, timeout=600)


@mcp.tool()
@logged
def resize_opening(opening_id: str, width: float, height: float,
                   sill: float = -1.0, dry_run: bool = False,
                   auto_unique: bool = True) -> dict:
    """Resize a door or window opening to width x height metres, keeping it
    centred on its current position. `opening_id` comes from list_openings.
    `sill` = bottom height above that storey's finished floor (pass -1 to
    keep the current sill; doors want sill 0).

    WHEN IT DOESN'T FIT, DO NOT STOP THERE. The result carries `limits`
    (max_width_here, max_height_here, limited_by, free_span) and a `remedies`
    list of concrete options — accept the maximum, extend the host wall, move
    a neighbouring opening, or slide this one along the wall. Present those
    options with their real numbers and consequences and ask the user which
    they want. An architect expects "here's what we'd have to change", not
    "can't do it".

    Auto-snapshots first, verifies INSIDE the undo operation, and rolls the
    model back if the result doesn't match — so a failure leaves nothing
    half-applied. Use dry_run=true to preview; the preview reports the same
    clamped numbers the real edit would produce. Always relay `achieved` and
    `verified`."""
    snap = versioning.auto_snapshot("resize_opening") if not dry_run else None
    params = {"id": opening_id, "width": width, "height": height,
              "dry_run": dry_run, "auto_unique": auto_unique}
    if sill is not None and sill >= 0:
        params["sill"] = sill
    result = bridge().send("resize_opening", params, timeout=600)
    if snap:
        result["snapshot"] = snap
    return result


@mcp.tool()
@logged
def set_slab_thickness(slab_pid: int, thickness: float, datum: str = "top",
                       auto_unique: bool = True) -> dict:
    """Change a slab (losa) to `thickness` metres. `slab_pid` comes from
    get_model_info's slabs list. datum='top' keeps the finished-floor level
    fixed and moves the soffit (almost always what an architect means —
    walls, doors and stairs keep their levels); datum='bottom' keeps the
    soffit and moves the top.

    Shared slabs are made unique automatically so they become editable;
    mention that to the user, since other copies keep their original
    thickness — and offer to apply the change to those too if that's what
    they meant. Auto-snapshots first, verifies inside the undo operation and
    rolls back on mismatch."""
    snap = versioning.auto_snapshot("set_slab_thickness")
    result = bridge().send("set_slab_thickness",
                           {"pid": slab_pid, "thickness": thickness, "datum": datum,
                            "auto_unique": auto_unique},
                           timeout=600)
    if snap:
        result["snapshot"] = snap
    return result


# ------------------------------------------------------------- creation ----
# Primitives rather than high-level generators: a pool, planter, parapet or
# massing study is a composition of these, so the agent can improvise shapes
# nobody hard-coded.

@mcp.tool()
@logged
def create_box(origin: list, size: list, name: str = "") -> dict:
    """Create a rectangular solid. `origin` = [x, y, z] of its lowest corner,
    `size` = [dx, dy, dz], all in metres. The building block for anything
    without a dedicated tool — pool basins, planters, steps, massing studies,
    counters.

    Before placing anything, get the model's bounds from get_model_info so it
    lands in a sensible spot, and CONFIRM the position and size with the user
    rather than guessing — 'in the back garden' needs a coordinate before it
    means anything. Afterwards, call locate() so they can see where it went."""
    return bridge().send("create_box", {"origin": origin, "size": size,
                                        "name": name}, timeout=600)


@mcp.tool()
@logged
def create_slab(origin: list, size: list, thickness: float, z_level: float,
                datum: str = "top", name: str = "") -> dict:
    """Create a horizontal slab (losa). `origin` = [x, y] of a corner,
    `size` = [dx, dy], all metres. `z_level` with datum='top' means z_level is
    the finished floor and the slab hangs below it (the usual architectural
    reading); datum='bottom' means it sits on z_level.

    Use get_model_info's `storeys` to match an existing finished-floor level
    rather than inventing one."""
    return bridge().send("create_slab", {"origin": origin, "size": size,
                                         "thickness": thickness, "z_level": z_level,
                                         "datum": datum, "name": name}, timeout=600)


@mcp.tool()
@logged
def create_wall(start: list, end: list, height: float, thickness: float = 0.15,
                z_base: float = 0.0, name: str = "") -> dict:
    """Create a wall running between two plan points, centred on that line.
    `start`/`end` = [x, y] in metres; any orientation works, not just
    axis-aligned. `z_base` is the level it stands on — match an existing
    finished floor from get_model_info's `storeys`.

    Cut doors and windows into it afterwards with create_opening."""
    return bridge().send("create_wall", {"start": start, "end": end, "height": height,
                                         "thickness": thickness, "z_base": z_base,
                                         "name": name}, timeout=600)


@mcp.tool()
@logged
def create_opening(wall_pid: int, width: float, height: float, sill: float = 0.0,
                   position: float = -1.0, auto_unique: bool = True) -> dict:
    """Cut a NEW door or window through an existing wall (resize_opening only
    changes ones that already exist). `sill` is measured from the WALL'S OWN
    BASE, and `position` is the opening's centre measured along the wall from
    its lower-coordinate end (omit to centre it).

    Works on axis-aligned walls. If the opening cannot fit, the error states
    the widest/tallest that would — offer that to the user instead of
    stopping. Verifies the hole really cut through and rolls back if not."""
    params: dict = {"wall_pid": wall_pid, "width": width, "height": height,
                    "sill": sill, "auto_unique": auto_unique}
    if position is not None and position >= 0:
        params["position"] = position
    snap = versioning.auto_snapshot("create_opening")
    result = bridge().send("create_opening", params, timeout=600)
    if snap:
        result["snapshot"] = snap
    return result


# ------------------------------------------------------------ versioning ---

@mcp.tool()
@logged
def create_snapshot(label: str) -> dict:
    """Save a named version of the model's CURRENT state (including unsaved
    changes) into its .archie/versions folder. Use before risky operations
    and at milestones ('propuesta v1 enviada a Omar'). Byte-identical
    snapshots are deduped automatically."""
    return versioning.create_snapshot(label)


@mcp.tool()
@logged
def list_versions() -> dict:
    """List the open model's saved versions (newest last) with labels,
    timestamps, sizes and which tool created them. Use this before
    restore_version."""
    return versioning.list_versions()


@mcp.tool()
@logged
def restore_version(version_file: str, confirm: bool = False) -> dict:
    """Restore the model to a saved version (file name from list_versions).
    Replaces the working .skp on disk and reopens it in SketchUp; a safety
    snapshot of the current state is taken first, so a restore is itself
    undoable. Requires confirm=true — always ask the user before passing it."""
    return versioning.restore_version(version_file, confirm)


@mcp.tool()
@logged
def save_model() -> dict:
    """Save the open model to its .skp file (like Ctrl+S in SketchUp). The
    previous on-disk state is preserved as a version first, so saving never
    destroys history."""
    prior = versioning.snapshot_disk_state("auto disk state before save", "save_model")
    result = bridge().send("save_model", timeout=900)
    if prior:
        result["previous_disk_state"] = prior
    return result


# --------------------------------------------------------------- projects --

@mcp.tool()
@logged
def create_client(name: str, contact_email: str = "", notes: str = "") -> dict:
    """Register a client (upserts by name; accent- and case-insensitive, so
    'Juarez' finds 'Juárez'). Clients own projects; create the client before
    their first project."""
    return projects.create_client(name, contact_email, notes)


@mcp.tool()
@logged
def delete_client(name: str, delete_projects: bool = False) -> dict:
    """Remove a client from the database. Refuses if they still have projects
    unless delete_projects=true. Never touches any .skp file or its versions —
    only the Archie registry. Confirm with the user before calling."""
    return projects.delete_client(name, delete_projects)


@mcp.tool()
@logged
def delete_project(project_name: str) -> dict:
    """Remove a project from the database. The .skp file and its
    .archie/versions folder are left untouched. Confirm with the user first."""
    return projects.delete_project(project_name)


@mcp.tool()
@logged
def list_clients() -> list:
    """All registered clients with their project counts."""
    return projects.list_clients()


@mcp.tool()
@logged
def create_project(client_name: str, project_name: str, model_path: str,
                   brief: str = "", allow_repoint: bool = False) -> dict:
    """Register a project: a client + a name + the absolute path to its .skp
    model + an optional brief (goals, constraints, agreed changes). The .skp
    must already exist — this is checked now, not later.

    If the project already exists and you pass a DIFFERENT model_path, the
    call is refused unless allow_repoint=true, because silently repointing a
    project sends every later edit and save at the wrong file."""
    return projects.create_project(client_name, project_name, model_path, brief,
                                   allow_repoint)


@mcp.tool()
@logged
def list_projects(client_name: str = "") -> list:
    """All projects (optionally for one client), with model paths and whether
    each model file exists."""
    return projects.list_projects(client_name)


@mcp.tool()
@logged
def open_project(project_name: str) -> dict:
    """Open a project's model in SketchUp by project name — use when the user
    says 'open the Juarez house' / 'abre el proyecto de Omar'. If the current
    model has unsaved changes they are snapshotted first. Returns the
    project brief so you start with its context."""
    return projects.open_project(project_name)


@mcp.tool()
@logged
def get_project_brief(project_name: str) -> dict:
    """Read a project's brief (goals, constraints, agreed changes)."""
    return projects.get_project_brief(project_name)


@mcp.tool()
@logged
def set_project_brief(project_name: str, brief: str) -> dict:
    """Overwrite a project's brief. Keep it current after client meetings —
    the brief is what makes 'apply what we agreed with the client' work in a
    fresh conversation."""
    return projects.set_project_brief(project_name, brief)


# ------------------------------------------------------------- dev escape --

@mcp.tool()
@logged
def eval_ruby(code: str) -> dict:
    """DEVELOPER ESCAPE HATCH — runs arbitrary Ruby inside SketchUp with no
    sandbox. Disabled unless dev_mode is true in ~/Archie/config.json (off
    for beta users). Prefer the typed tools; reach for this only when no
    typed tool can express the operation, and auto-snapshot still runs
    first."""
    # BUG-17: this used to RETURN the error as a successful result, so a
    # caller checking only for exceptions read it as success. Every other
    # tool raises; this one now does too.
    if not CFG.get("dev_mode"):
        raise PermissionError(
            "eval_ruby is disabled (dev_mode=false in ~/Archie/config.json). "
            "Use the typed tools; enable dev_mode only for development.")
    snap = versioning.auto_snapshot("eval_ruby")
    result = bridge().send("eval_ruby", {"code": code}, timeout=600)
    if snap:
        result["snapshot"] = snap
    return result


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
