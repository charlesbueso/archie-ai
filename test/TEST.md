# The test

One hypothesis:

> meeting transcript → Claude (with SketchUp MCP) → useful edit in a real SketchUp model

Everything here exists to get a yes or no on that, fast.

## Before you start

1. `scratch.skp` is open in SketchUp and built per [SCRATCH_MODEL.md](SCRATCH_MODEL.md).
2. **Extensions → MCP Server → Start Server**. Ruby Console shows
   `Server started and listening`.
3. `scratch_original.skp` exists so you can reset between runs.
4. In the project directory, run `claude`, then `/mcp` — `sketchup` shows as
   connected.

## The prompt

Paste this whole block into Claude. It references the transcript by path, so run
Claude from the project root.

```text
You are helping an architect apply changes agreed in a client meeting to a
SketchUp model. You are connected to SketchUp through an MCP bridge.

Some context on the tooling before you start:

- The only tool that matters here is eval_ruby. It runs Ruby inside SketchUp.
  The other tools (create_component, dovetail, mortise_tenon, etc.) are for
  woodworking and are not useful for this.
- The very first eval_ruby call of a session can return a stale response from
  the bridge's internal handshake. So make your first call a throwaway:
  eval_ruby with the code `1 + 1`. Ignore whatever comes back. Then start
  working for real.
- The SketchUp Ruby API works in INCHES internally, always, no matter what the
  document's display units say. This model is metric. Convert explicitly:
  use `1.m` / `60.cm` to go metric-to-internal, and `.to_m` to go back.
- Wrap every change to the model in a single undo operation:

      model = Sketchup.active_model
      model.start_operation('Cambios reunión 12 mayo', true)
      begin
        # ... all edits here ...
        model.commit_operation
      rescue => e
        model.abort_operation
        raise e
      end

  One operation for the whole set of changes, so the architect can undo it with
  one Ctrl+Z. This matters. Do not skip it.

Now do this, in order:

STEP 1 — Read the model.
Inspect the current geometry and report back, in metres: the interior
dimensions, the wall height, the wall thickness, the size and position of the
door, and the size and position of the window. Name the groups you found.
Do not change anything yet.

STEP 2 — Read the transcript.
Read test/transcript_es.md. It is a raw, unedited transcript of a meeting in
Spanish between an architect and two clients. It is conversational and messy:
people change their minds mid-sentence, numbers get revised, and some things
that get discussed are explicitly deferred.

List the changes that were actually agreed. For each one, quote the line of the
transcript that settles it. Also list anything that was discussed but decided
against, and say why you are excluding it.

STEP 3 — Wait.
Show me steps 1 and 2 and stop. Do not touch the model until I say go.

STEP 4 — Only after I say go: apply the changes, in one undo operation, and
tell me what you did.
```

The stop at step 3 is deliberate. Most of what you are evaluating is whether it
*understood* — if it misreads the transcript you already have your answer, and
you have not spent a model edit finding out.

## What should come out

The agreed changes, all three:

| # | Change | From | To |
| - | ------ | ---- | -- |
| 1 | North wall moves outward (north) | interior depth 4.00 m | 4.60 m |
| 2 | East window widens | 1.20 m wide | 1.80 m wide |
| 3 | Ceiling / wall height rises | 2.50 m | 2.70 m |

Unchanged, and it should say so:

- Door stays 0.90 × 2.10 m ("esa no la toques")
- Window height stays 1.10 m, sill stays 0.90 m ("la altura la dejamos como está")
- Wall thickness stays 0.15 m
- Interior width stays 5.00 m
- **No toilet / no partition in the corner** — deferred to a later phase
  ("déjalo. Eso lo vemos más adelante")

The traps, in rough order of how much they tell you:

- **The toilet.** Elena asks for one, they discuss it, they drop it. If Claude
  builds it, it cannot tell a request from a decision. That is the single most
  informative failure in this test.
- **50 vs 60 vs 70 cm.** Marta offers up to 70. Elena says half a metre. Javier
  pushes for more. Elena lands on 60. Only 60 is correct.
- **"El doble" on the window.** Elena says double (2.40), Marta talks her down,
  they settle on 1.80. Only 1.80 is correct.
- **2.20 / 2.60 m.** Those are the dining table, not the building. Anything that
  treats them as a dimension of the room is badly confused.
- **Units.** 60 cm is `60.cm`, not `60` (which is 60 inches — 1.52 m). This is
  the most likely silent failure and the hardest to spot by eye.

## Checking the result

Paste this into the SketchUp Ruby Console after the edit. Read-only.

```ruby
Sketchup.active_model.entities.grep(Sketchup::Group).each { |g|
  bb = g.bounds
  printf("%-12s  min(%6.2f,%6.2f,%6.2f)  size(%5.2f x %5.2f x %5.2f) m\n",
         g.name.empty? ? '(unnamed)' : g.name,
         bb.min.x.to_m, bb.min.y.to_m, bb.min.z.to_m,
         bb.width.to_m, bb.height.to_m, bb.depth.to_m)
}
nil
```

Every wall should report a Z size of **2.70**. `WALL_NORTH` should sit 0.60 m
further north than it did. `WALL_EAST` should still be 0.15 m thick.

## Rubric

Score each line. Anything in **bold** is disqualifying on its own.

### A — Did it read the model? (step 1)

- [ ] Reported interior dimensions correctly as 5.00 × 4.00 m
- [ ] Reported wall height correctly as 2.50 m
- [ ] Reported wall thickness correctly as 0.15 m
- [ ] Found the door and the window and gave roughly correct sizes
- [ ] Reported in **metres**, not inches — **fail if it reports 196.85 for 5 m
      and does not notice**
- [ ] Identified walls by group name rather than guessing from coordinates

### B — Did it interpret the transcript? (step 2)

- [ ] Got all three agreed changes
- [ ] **Excluded the toilet, and said why**
- [ ] Landed on 60 cm, not 50 or 70
- [ ] Landed on 1.80 m, not 2.40
- [ ] Did not treat the table dimensions as building dimensions
- [ ] Noted the things explicitly left alone (door, window height, sill)
- [ ] Quoted actual transcript lines rather than paraphrasing vaguely

### C — Would an architect keep the geometry? (step 4)

This is the one that decides it.

- [ ] **Everything landed at the right scale** — check with the Ruby snippet
      above, not by eye
- [ ] North wall moved 0.60 m; it did not stretch, scale, or duplicate
- [ ] The wall still meets the east and west walls — **no gaps, no overlaps at
      the corners**
- [ ] Window is 1.80 m wide, still 1.10 m high, sill still at 0.90 m
- [ ] Window is still a clean opening through the wall — not a floating rectangle
      or a hole with leftover faces
- [ ] All four walls are 2.70 m; they did not get scaled non-uniformly
- [ ] Door untouched
- [ ] Nothing extra appeared in the model
- [ ] **One Ctrl+Z reverts the whole thing** — if it takes eleven undos, the
      operation wrapping did not work
- [ ] Group names survived

### Verdict

Pick one:

- **KEEP** — an architect would accept this and carry on working. Every C item
  passes.
- **FIX** — the intent was right, the execution needs cleanup. B passes, C has
  gaps that are quick to repair by hand.
- **UNDO** — an architect would hit Ctrl+Z and do it manually. Any bold item
  failed.

**UNDO means the feature dies in its current form.** It does not necessarily
mean the idea is dead — note *where* it broke, because it discriminates:

- Failed at **A** → the read path is the problem. There is no model-inspection
  tool in this bridge; everything goes through `eval_ruby`, so Claude has to
  write introspection code before it can do anything. That is fixable with a
  proper `get_model_info` tool.
- Failed at **B** → the transcript-understanding is the problem. That is the
  cheapest thing to fix and the least interesting, because it is just prompting.
- Failed at **C** → **this is the real signal.** Manipulating existing geometry
  in SketchUp — moving a wall while keeping its junctions clean, resizing an
  opening without wrecking the surrounding face — is genuinely hard through a
  scripting API. If it fails here while passing A and B, the bottleneck is
  geometry manipulation, and that is the thing you would actually have to build.

Write down which one it was. That answer is the point of the week.

## Re-running

Close without saving, reopen `scratch_original.skp`, save it as `scratch.skp`.
Restart the MCP server in SketchUp (Stop, then Start) so the bridge does not
hold a stale socket.

Worth running two or three times. The first-call quirk and the reconnect
behaviour described in [../SETUP.md](../SETUP.md) make single runs noisy, and
you want to know whether a failure is the concept or the plumbing.
