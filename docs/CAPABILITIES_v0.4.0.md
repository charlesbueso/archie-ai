# Archie v0.4.0 — "do it, or say what we'd have to change"

Answers the session where a downloaded house model dead-ended three times.
Every fix below is verified by `tools/smoke_bugs.py` against a real model.

---

## The three dead ends, and what changed

### 1. "No tool for this" → `transform_component`

The ledge protruding under a window was neither an opening nor a slab, so
nothing could touch it and the answer was "do it manually in SketchUp".

```
transform_component(pid, set_size=[null, 0.6, null], anchor=["center","min","center"])
```

Move, scale, or set an exact size on **any** container. The per-axis `anchor`
is what makes *"make it stick out further"* expressible: pin the end that
meets the wall, grow the other. Without it, the element grows both ways and
detaches from the building.

### 2. "5 of 5 slabs are shared, none editable" → `make_unique`

Downloaded and library models are almost entirely component instances. The
shared-geometry guard was right — editing one really would change all copies —
but with no way to detach, it left the user with nothing to do.

`make_unique` uniquifies the whole ancestor chain **and the nested geometry
inside it**. That second half matters: making a node unique only gives it its
own definition, while the children in that definition are still shared with
the original's children, so an edit reaching into nested geometry would still
leak into the other copies.

The edit tools now do this automatically (`auto_unique`, on by default) and
report what happened, so the agent can say *"this slab was 1 of 4 identical
copies; I made this one independent — want the other 3 changed too?"*

Verified end to end on the real model: a shared slab went 0.187 → 0.287 →
0.187 with `verified: true` at each step.

### 3. "Can't do 1.04m" → remedies with real numbers

A blocked resize now returns:

```json
"limits":  { "max_width_here": 0.67, "limited_by": "wall_shell",
             "host_span": [5.61, 6.28], "free_span": [5.61, 6.28] },
"remedies": [
  { "action": "accept_max_width", "width": 0.67 },
  { "action": "extend_host_wall", "extra_needed_m": 1.67,
    "detail": "the host wall spans 5.61–6.28m; it needs 1.67m more length..." },
  { "action": "recentre_opening", "detail": "sliding it along the wall may free up room" }
]
```

The failure message ends with `Offer these to the user rather than stopping.`
The tool descriptions say the same thing in the words the agent reads first.

---

## New: creation primitives

Deliberately primitives, not generators. A pool, planter, parapet or massing
study is a composition of these, so the agent can improvise arrangements
nobody hard-coded — whereas a `create_pool()` with fifteen parameters only
ever makes the pool its author imagined.

| Tool | Notes |
|---|---|
| `create_box(origin, size)` | The building block for everything without a dedicated tool |
| `create_slab(origin, size, thickness, z_level, datum)` | `datum='top'` means `z_level` IS the finished floor and the slab hangs below it |
| `create_wall(start, end, height, thickness, z_base)` | Runs between two plan points, centred on the line — **any orientation**, verified on a diagonal |
| `create_opening(wall_pid, width, height, sill, position)` | Cuts a NEW hole through an existing wall and verifies it really cut through |

A pool is then: one box for the basin void, four for the walls, one for the
floor, one thin slab for coping. The agent can work that out; it does not need
a bespoke tool.

Every creator validates in **metres**, wraps one undo operation, verifies
geometrically, and rolls back on mismatch. Refusals carry the fitting size:
*"opening 99.0m is wider than the wall (6.0m). The widest that fits is about
5.9m."*

---

## Two SketchUp traps found while building this

Both are now encoded as rules in the README.

### `definition.bounds` is stale inside an open operation

It does not refresh until `commit_operation`. Because v0.3.0 moved
verification *inside* the operation (so bad edits roll back), verification was
reading pre-edit geometry and **rolling back perfectly correct edits**. The
vertices were at exactly the requested position the whole time.

Anything measured between `start_operation` and `commit_operation` must use
`Util.world_bbox_live`, which reads actual vertex positions.

Corollary found immediately after: `transform!` changes the entity's *own*
transformation, so a world transform captured before the edit is stale too —
re-resolve the container before measuring. Vertex-moving edits (slabs) don't
have this problem, which is why it surfaced only on `transform_component`.

### Selection tolerance must be smaller than the thing being selected

`set_slab_thickness` picks vertices within a tolerance of a plane. The default
20mm tolerance is larger than a 14mm finish slab, so it selected the top
**and** bottom faces and moved both — the thickness never changed, and it read
as a mysterious verification failure. Tolerance is now clamped to 40% of the
slab's own thickness.

---

## Tool count: 27

New in v0.4.0: `make_unique`, `transform_component`, `create_box`,
`create_slab`, `create_wall`, `create_opening`.

## Still not built

- **Storeys** (`duplicate_storey`) — copy a floor's walls up and add a slab.
  Ambitious and the riskiest of the ideas discussed; wants hard testing.
- **BUG-06** — editing one of two adjacent balcony doors still fuses them into
  an uneditable ASSEMBLY. Carried over from v0.3.0; needs a live repro.
- **Rotated walls in `resize_opening` / `create_opening`** — both assume
  axis-aligned walls. `create_wall` itself handles any orientation.

---

## v0.4.1 — root-level geometry, selection bridge, merge_openings

Three fixes from a session on a downloaded `modern-house.skp`.

### Archie was blind to loose geometry at the model root

`Util.containers` only ever walked groups and component instances. That model
keeps **658 faces loose at the model root**, including whole second-floor
walls — none of it existed as far as Archie was concerned.

The model root is now a pseudo-container (pid `0`, path `(model root)`), so
the same detection code reaches it. On that house it made 3 previously
invisible openings appear immediately.

This is probably the single biggest coverage gap found so far: a model can be
substantially invisible without any error being raised anywhere.

### get_selection couldn't reach any editing tool

Selecting a window in SketchUp yields loose `Face` entities. Every edit tool
takes a container pid or an opening id, and `locate` rejected face pids
outright — so *"resize the window I selected"*, the headline use case, could
never work.

`get_selection` now resolves each selected entity to its owning container
(or reports it as loose root geometry) and returns `nearby_openings` — real
opening ids next to the selection, ready for `resize_opening` or
`merge_openings`. `locate` accepts any entity pid, not just containers.

### merge_openings

Combines adjacent openings into one by cutting away the mullions between
them. Expressed as *"cut the gaps"* rather than *"delete this geometry"*, so
it reuses the verified cut path and the schema stays closed — there is still
no tool that deletes arbitrary geometry.

Validates that the openings share a wall and a plane, overlap vertically, and
aren't already contiguous; rolls back if they don't end up joined.

### The case that still cannot be done, and why

The two windows in question sit in a wall modelled as a **single plane of
zero thickness** (`y = 7.1`, `n-extent [7.1, 7.1]`). There is no material
between them to cut — the "3 bars" are simply adjacent faces. Merging them
means *erasing faces*, which is deliberately outside the schema.

Worth deciding explicitly, because surface-modelled walls are common in
downloaded models and the whole opening model assumes solids with holes:

1. Add a narrowly-scoped `erase_between_openings` that only removes faces
   fully inside the gap rectangle of two named openings — bounded, and not a
   general delete.
2. Accept that surface-modelled walls are out of scope and say so clearly
   when detected (current behaviour: the error explains exactly this).
3. Treat it as a modelling problem and offer to rebuild that wall as a solid
   with `create_wall` + `create_opening`, which are already verified.
