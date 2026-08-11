# Building `scratch.skp`

Build this by hand in SketchUp and save it as `test/scratch.skp`. It should take
about ten minutes.

The exact numbers matter. The transcript in `transcript_es.md` refers to them,
and the rubric in `TEST.md` checks the result against them. If you change a
dimension here, change it there too.

> Everything in this folder is a throwaway scratch file. The bridge exposes
> `eval_ruby`, which runs arbitrary Ruby inside SketchUp. Never point it at a
> real project file. See the security note in `SETUP.md`.

## Units first

Before drawing: **Window → Model Info → Units → Format: Decimal, Metres**.

Do this before anything else. SketchUp's Ruby API works internally in **inches**
regardless of display units, and getting the display units right makes it much
easier to eyeball whether Claude's edits landed at the correct scale.

## The room

One rectangular room. Four walls, one door, one window. No roof, no floor slab —
they only get in the way of seeing what changed.

```
                    NORTH  (move this wall in change #1)
        ┌───────────────────────────────────┐
        │                                   │
        │                                   │
   WEST │         interior 5.00 × 4.00      │ EAST
        │                                   │  ← window on this wall
        │                                   │
        └──────────────┐   ┌────────────────┘
                       └───┘
                    SOUTH   ← door here
```

| Property            | Value                                        |
| ------------------- | -------------------------------------------- |
| Interior footprint  | 5.00 m (east–west) × 4.00 m (north–south)    |
| Wall height         | 2.50 m                                       |
| Wall thickness      | 0.15 m                                       |
| Door                | 0.90 m wide × 2.10 m high, in the SOUTH wall |
| Window              | 1.20 m wide × 1.10 m high, in the EAST wall  |
| Window sill height  | 0.90 m above floor                           |

Centre the door in the south wall and the window in the east wall. Precision to
the centimetre is fine.

## How to build it

1. Draw a 5.00 × 4.00 m rectangle on the ground plane — this is the **interior**
   face.
2. Offset it outward by 0.15 m to get the wall footprint.
3. Erase the inner face so you are left with a ring, then push/pull the ring up
   to 2.50 m. You now have four walls.
4. Draw the door opening on the south wall (0.90 × 2.10, sitting on the floor)
   and push/pull it all the way through. Leave it as a void — no door component
   needed.
5. Draw the window opening on the east wall (1.20 wide × 1.10 high, bottom edge
   0.90 above the floor) and push/pull it through. Also just a void.

## Naming — do this, it matters

Select each wall (triple-click to get the whole connected face set, or select the
faces manually), right-click → **Make Group**, then in **Entity Info** set the
group name.

Use exactly these names:

- `WALL_NORTH`
- `WALL_SOUTH`
- `WALL_EAST`
- `WALL_WEST`

This is the single highest-leverage thing you can do for the test. Without
names, Claude has to infer which wall is which from raw bounding-box geometry,
and you end up testing its spatial reasoning about an unlabelled soup of faces
rather than testing the actual hypothesis — whether it can turn a conversation
into a correct edit.

Naming things is also what a real architect's model would look like, so this is
the realistic case, not a concession.

## Before you save

- Set the camera to an axonometric view where all four walls, the door and the
  window are visible. You want to see changes at a glance.
- **File → Save As** → `test/scratch.skp`.
- Then **make a copy** — `scratch_original.skp`. You will want to re-run the test
  several times, and a pristine copy to restore from is faster than undoing.
