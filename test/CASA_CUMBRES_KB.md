# CASA_CUMBRES_DE_JUAREZ — model knowledge base

Inspection of `test/CASA_CUMBRES_DE_JUAREZ.skp` (85 MB, by Omar), done 2026-08-08
entirely through the `eval_ruby` MCP bridge.

This doubles as the template for inspecting any new client model. The method is in
[How this was produced](#how-this-was-produced); the reusable scripts are in `tools/`.

---

## 1. Identity and units

| | |
| - | - |
| Path | `B:\repos\archie-ai\test\CASA_CUMBRES_DE_JUAREZ.skp` |
| Display units | Decimal **metres** (`LengthUnit=4`, `LengthFormat=0`) |
| Top-level entities | 51 (37 groups, 10 component instances) |
| Component definitions | 502 |
| Layers/tags | 20 | 
| Materials | 129 |
| Scenes | 6 (`Scene 1`…`Scene 6`) |

> The Ruby API works in **inches** regardless of display units. Every number in this
> document is metres, converted with `.to_m`. Writing `60` where you meant `60.cm`
> produces 1.52 m and is the most likely silent failure mode.

Layer names reveal the model's provenance — it is an assembly of purchased assets:
`Layer0`, `Defpoints`, `A_MOBILIARIO`, `A-WALL-FULL1`, `Natuzzi`, `PDF3_Geometry`,
plus Chinese (`活動家具`, `系統櫃`, `結構`, `衛浴廚房`, `木作`, `燈具`) and Russian (`Сцена`)
layers from imported furniture.

## 2. Coordinate system and what is actually in the file

The file contains **two unrelated clusters**. Filter on `x < 40` to get the building.

| Cluster | X range | Contents |
| - | - | - |
| **The house** | −0.91 … 12.61 | building, site, vegetation |
| **Sample board** | 50.0 … 66.0 | 12× 1 m³ material swatches, `LOSETA EXTERIOR`, `NUEVO COLOR`, and staged furniture (`living+room`, `Couch3`, `sofAS`). **Not architecture.** |

House footprint: **x 1.37 – 12.61, y 9.23 – 28.79** (≈ 11.2 × 19.6 m).

## 3. Storeys and levels

| Level | Finished floor (z) | Clear height |
| - | - | - |
| PB — planta baja | **0.62** | 2.65 m |
| PA — planta alta | **3.57** | 2.82 m |
| Roof | 6.39 / 8.31 | — |

Finished floor level = **top of slab**. Both FFLs are derived from slab tops, not
assumed, and every sill in this document is measured relative to its own storey's FFL.

## 4. Structural elements

### Slabs (losas)

| Element | z bottom → top | Thickness | Footprint |
| - | - | - | - |
| Ground slab | 0.00 → 0.62 | **0.62 m** | 219.7 m² |
| **Entrepiso** | 3.27 → 3.57 | **0.30 m** | 219.7 m² |
| Roof lower | 6.387 → 6.487 | 0.10 m | 82.6 m² |
| Roof upper | 8.307 → 8.407 | 0.10 m | 82.6 m² |
| Exterior terrace | 0.00 → 0.32 | 0.32 m | 80.8 m² |

The entrepiso carries a 3.35 × 2.67 m void for the stair.

### Wall solids — the three containers that hold all architecture

Everything architectural lives in exactly three places. Everything else is furniture.

| Path | Role | Faces | Notes |
| - | - | - | - |
| `/Group#88/Group#30/Union` | PB wall solid | 79 | manifold |
| `/Group#27/Group#34/Group#28/Group#4` | PA wall solid | 123 | **not manifold** |
| `/Group#51` | East facade panel | 45 | 0.15 m thick, spans both storeys |

`/Group#27/Group#200/...` is a large furniture and millwork container. It produces
hundreds of tiny inner loops (cabinet reveals ~0.15 × 0.03 m) that will pollute any
naive opening sweep. Exclude it.

Wall thicknesses run 0.12 – 0.17 m; 0.15 m is the norm.

## 5. Openings

**There are no `cuts_opening` components in this model.** Every door and every window
is a hard hole cut through wall geometry. Doors and windows are literally the same kind
of object, so they can only be told apart by measurement.

### The discriminator

```
DOOR   <=>  sill <= 0.10 m above FFL   AND   clear height >= 1.95 m
WINDOW <=>  sill  > 0.15 m above FFL
```

Sill alone is **not** sufficient: the facade panel has a band at sill 0.07 m that is only
0.91 m tall — nobody walks through it. The head-height test separates the classes by
1.12 m, versus 0.02 m at the sill boundary, so it is far more robust. Gross aspect ratio
alone also fails, because three of the four real doors are wide multi-leaf sliders that
read "window-ish".

### Inventory — 10 physical openings

| ID | Type | Size (W × H) | Sill | Location | Notes |
| - | - | - | - | - | - |
| PB-D1 | DOOR | 2.29 × 2.14 | 0.03 | (2.38, 23.89) | 2 sliding leaves of 1.12 |
| PB-D2 | DOOR | 1.73 × 2.14 | 0.03 | (9.17, 28.64) | 2 leaves of ~0.85 |
| PB-W1 | WINDOW | 0.90 × 1.12 | 1.04 | (1.38, 14.42) | west wall; 4-loop stepped frame |
| PA-D3 | DOOR | 1.66 × 2.34 | 0.03 | (9.02, 27.44) | **two leaves 0.78 + 0.83, 0.05 mullion** |
| PA-D5 | DOOR | 1.63 × 2.10 | 0.05 | (8.29, 10.39) | balcony slider, 2 leaves |
| PA-W2 | WINDOW | 1.50 × 1.80 | 0.40 | (4.22, 12.31) | already the spec's size |
| PA-W3 | WINDOW | 3.49 × 2.03 bay | 0.48 | (2.77, 24.14) | 2 lights 1.65 + 1.70, 0.05 mullion |
| F1–F3 | NEITHER | 3× 2.40 × 0.91 | 0.07 / 1.55 / 0.12 | (12.61, 18.41) | facade panel bands |

Plus five small secondary openings in the PA solid — 0.30 × 1.20 slots at (12.61, 22.37)
and (12.61, 23.47), 0.40 × 0.50 at (12.61, 16.56), and 0.40 × 0.50 at sill **2.00** at
(1.38, 16.28) and (1.38, 18.13). The last pair is the textbook Mexican *ventila alta de
baño*. All five are architecture and will be swept up by any literal "every window" rule.

### `Group#51` — the east facade panel

A genuine 0.15 m **wall**, not a screen: it is glazed (six 0.01 m translucent panes), it
fills a real 4.14 m gap in the envelope where the return walls terminate at x = 12.46,
and its 45-face census (X:5 / Y:20 / Z:20) matches three rebated two-light window units
exactly. The main wall solids carry **zero** openings behind it, so it is the only thing
lighting that bay.

But its three bands repeat at a **1.48 / 1.52 m pitch that ignores the storey structure**
— the entrepiso simply slots into the gap between bands 2 and 3. It is fenestration
composed as elevation, which is why a per-window spec breaks on it: forcing bands 1 and 2
to 1.80 m tall at sill 0.50 makes them **the same hole**. Geometrically impossible.
Exempt it.

## 6. Modelling conventions (learn these before editing)

1. **Rough opening + reveal.** Every opening is drawn twice: a rough opening and a
   daylight opening inset by a uniform **0.03 – 0.06 m**. An edit that catches one and
   not the other leaves a mismatched frame. Use a selection margin ≥ 0.08 m.
2. **Stepped frames.** Some openings are 3–4 concentric loops across the wall thickness
   with extra vertices *between* the loops. Moving only the loop vertices tears the face.
3. **Mullions are separate solids.** `Group#29` (x 3.50), `Group#31` (x 10.01),
   `Group#32` (x 9.09), `Group#33` (x 4.95) sit inside openings and split them into
   leaves. Per-leaf width — not overall width — is what identifies a door.
4. **Glazing is separate.** 74 thin (~0.01 m) panes, one per physical opening. Where one
   pane spans two loops, those loops are one assembly. Panes are the reliable join key.
5. **Nothing is named.** Every group is auto-named `Group#NNN`, everything sits on
   `Layer0`. There is no semantic information whatsoever — all identification must be
   geometric.
6. **`make_unique` renames definitions.** `Group#4` becomes `Group#222` and so on, so
   name-based lookup breaks immediately after uniquifying. Hold direct node references.

## 7. Gaps and oddities in the model

- **No main entrance.** The PB south wall (y 9.2 – 10.6) contains only 5 cm furniture
  artefacts. PB has four physical openings total.
- **No interior doors at all** — no bedroom, bathroom or closet doors anywhere. For a
  house this size that is 8–12 missing doors, so a door schedule cannot be closed from
  this model alone.
- PA has three uncovered terraces (roof panels do not span them).
- The PA wall solid is **not manifold** — some openings appear on only one face.
- Two `Group#153` / `Group#20` slabs at x ≈ 50 are duplicates of each other.

## 8. How this was produced

Round-tripping hundreds of `eval_ruby` calls is slow. The pipeline dumps the model to
disk **once**, then analyses locally:

| Step | Tool | Output |
| - | - | - |
| 1. Dump the whole node tree with world bounds | inline `eval_ruby` | `logs/model_dump.json` (672 nodes) |
| 2. Dump every inner-loop hole | inline `eval_ruby` | `logs/openings.json` (348 holes) |
| 3. Dump wall-solid loops with vertices | inline `eval_ruby` | `logs/wall_loops.json` |
| 4. Structure / slabs / storeys | `tools/analyze_dump.py` | console |
| 5. Classify openings | `tools/analyze_openings.py` | console |
| 6. Build a per-opening edit plan | `tools/plan_edits.py` | `logs/edit_plan.json` |
| 7. Rebuild copy + apply plan | `tools/apply_spec.rb` | model |

Two rules that came out of getting it wrong first:

- **Move vertices with `transform_by_vectors`, once.** Issuing many
  `transform_entities` calls leaves reveal faces transiently non-planar; SketchUp
  splits and heals them and the openings are destroyed.
- **Never rely on `Sketchup.send_action("editUndo:")`.** It is queued, does not apply
  within the calling `eval_ruby`, and silently no-ops. `apply_spec.rb` is instead
  idempotent — it deletes and rebuilds the copy from the pristine original every run.
