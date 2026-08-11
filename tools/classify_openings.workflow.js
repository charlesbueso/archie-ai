export const meta = {
  name: 'classify-openings-casa-juarez',
  description: 'Independently classify architectural openings as door/window/neither for CASA_CUMBRES_DE_JUAREZ',
  phases: [
    { title: 'Classify', detail: 'four independent lenses over the opening inventory' },
    { title: 'Verify', detail: 'adversarial check of the contested openings' },
    { title: 'Synthesize', detail: 'single reconciled classification' },
  ],
}

const CONTEXT = `
You are analysing a real SketchUp model of a two-storey house in Mexico:
CASA_CUMBRES_DE_JUAREZ. Working directory: b:/repos/archie-ai

CRITICAL RULE: Do NOT call any sketchup MCP tools. SketchUp's bridge accepts
only one connection and the main session owns it. Work ONLY from these files:
  - logs/openings.json   (every inner-loop hole found in the model, world coords)
  - logs/model_dump.json (full node tree with world bounding boxes)
  - tools/analyze_openings.py, tools/analyze_dump.py (the extraction analysis)
You may read them and run python (.venv/Scripts/python.exe) over them.

ESTABLISHED FACTS (already verified, trust these):
- Finished floor levels: PB (ground) = z 0.62, PA (upper) = z 3.57.
- Slabs: ground 0.62 thick, entrepiso 0.30 thick (z 3.27-3.57),
  roof slabs already 0.10 thick, exterior terrace 0.32 thick.
- There are NO cuts_opening components. Every door and window is a hard hole
  cut through wall faces. Both doors and windows are literally just holes.
- Architectural openings live in exactly three containers:
    /Group#88/Group#30/Union              -> PB (ground) wall solid
    /Group#27/Group#34/Group#28/Group#4   -> PA (upper) wall solid
    /Group#51                             -> a separate thin panel at x=12.46,
                                             0.15 m thick, 4.14 wide, 5.77 tall,
                                             spanning z 0.62 to 6.39 (both storeys)
  /Group#27/Group#200/... is furniture and millwork, NOT architecture.

THE 21 UNIQUE ARCHITECTURAL OPENINGS (sill = height of hole bottom above that
storey's finished floor):

  container    W     H    sill  storey  position(x,y,z)        normal
  PB walls   2.29  2.14   0.03   PB    (2.38, 23.89, 0.65)   (0,-1,0)
  PB walls   1.73  2.14   0.03   PB    (9.17, 28.64, 0.65)   (0,-1,0)
  facade     2.40  0.91   0.07   PB    (12.61,18.41, 0.69)   (1,0,0)
  facade     1.12  0.79   0.13   PB    (12.46,18.47, 0.75)   (-1,0,0)
  facade     1.10  0.79   0.13   PB    (12.46,19.65, 0.75)   (-1,0,0)
  PB walls   0.90  1.12   1.04   PB    (1.38, 14.42, 1.66)   (-1,0,0)
  PB walls   0.80  1.02   1.09   PB    (1.38, 14.47, 1.71)   (-1,0,0)
  facade     2.40  0.91   1.55   PB    (12.61,18.41, 2.17)   (1,0,0)
  facade     1.12  0.79   1.61   PB    (12.46,18.47, 2.23)   (-1,0,0)
  facade     1.10  0.79   1.61   PB    (12.46,19.65, 2.23)   (-1,0,0)
  PA walls   0.78  2.34   0.03   PA    (9.02, 27.44, 3.60)   (0,-1,0)
  PA walls   0.83  2.34   0.03   PA    (9.85, 27.44, 3.60)   (0,-1,0)
  PA walls   1.63  2.10   0.05   PA    (8.29, 10.39, 3.62)   (0,-1,0)
  facade     2.40  0.91   0.12   PA    (12.61,18.41, 3.69)   (1,0,0)
  facade     1.12  0.79   0.18   PA    (12.46,18.47, 3.75)   (-1,0,0)
  facade     1.10  0.79   0.18   PA    (12.46,19.65, 3.75)   (-1,0,0)
  PA walls   1.50  1.80   0.40   PA    (4.22, 12.31, 3.97)   (0,-1,0)
  PA walls   1.40  1.70   0.45   PA    (4.27, 12.50, 4.02)   (0,-1,0)
  PA walls   3.49  2.03   0.48   PA    (2.77, 24.14, 4.05)   (0,1,0)
  PA walls   1.65  1.93   0.53   PA    (2.82, 23.89, 4.10)   (0,-1,0)
  PA walls   1.70  1.93   0.53   PA    (4.52, 23.89, 4.10)   (0,-1,0)

NOTE ON PAIRS: some rows are the two faces of ONE physical opening seen through
a wall of finite thickness (e.g. 1.50x1.80 at y=12.31 and 1.40x1.70 at y=12.50
are 0.19 apart -- likely one window with a reveal/frame; 3.49x2.03 at y=24.14
versus 1.65x1.93 + 1.70x1.93 at y=23.89 is likely one recessed bay containing
two sashes split by a mullion). Determining which rows are the same physical
opening is part of the job.

THE SPEC to be applied (from the client, Omar), deliberately ambiguous to test
door-vs-window discrimination:
  1. Every WINDOW opening -> 1.50 m wide x 1.80 m high, sill 0.50 m above
     finished floor.
  2. Every slab including the entrepiso -> 0.10 m thick.
  3. Every DOOR opening -> 2.13 m high x 0.91 m wide.
`

phase('Classify')

const LENSES = [
  {
    key: 'sill',
    prompt: `${CONTEXT}

YOUR LENS: the sill-height / threshold rule. A door must be walkable: its
opening bottom sits at (or within a threshold tolerance of) the finished floor.
A window's opening bottom sits meaningfully above it. Classify every one of the
21 rows as DOOR, WINDOW, NEITHER (facade screen / structural / not an
inhabitable opening), or DUPLICATE-OF another row. State the sill threshold you
use and defend it. Flag any row where this rule alone is ambiguous.`,
  },
  {
    key: 'proportion',
    prompt: `${CONTEXT}

YOUR LENS: dimension and proportion. Human-passable doors cluster near
0.80-1.00 m wide and 2.00-2.40 m tall (portrait, tall). Windows are typically
wider-than-tall or near-square and never full height. Openings that are very
wide and short (e.g. 2.40 x 0.91) are neither -- they read as slot/band
glazing or louvre bands. Classify all 21 rows as DOOR / WINDOW / NEITHER /
DUPLICATE and justify from proportion alone. Note where proportion disagrees
with what a sill-height rule would say.`,
  },
  {
    key: 'context',
    prompt: `${CONTEXT}

YOUR LENS: architectural context and element identity. Read logs/model_dump.json
and characterise /Group#51 specifically: a 0.15 m thin panel, 4.14 x 5.77,
standing at x=12.46 on the east edge, spanning BOTH storeys continuously, with
its holes repeating at three z levels (0.75, 2.23, 3.75) in an identical
pattern. Is that a wall with windows, or is it a facade screen / celosia /
brise-soleil / stair-shaft screen? A repeating pattern that ignores storey
boundaries is strong evidence. Decide whether its openings are 'windows' in the
sense a spec would mean. Also identify which PB/PA wall openings are exterior
vs interior (doors between rooms vs entry doors) using the node tree geometry.`,
  },
  {
    key: 'code',
    prompt: `${CONTEXT}

YOUR LENS: Mexican residential practice and building norms. Typical Mexican
residential door leaf: 2.10-2.13 m high, 0.90 m (main/bedroom) or 0.70-0.80 m
(bathroom) wide. Typical window sill (antepecho): 0.90-1.00 m in habitable
rooms, ~1.80 m or higher for bathroom privacy windows, ~0.50 m for
floor-adjacent picture windows. Note that the spec's 2.13 x 0.91 is exactly
7'-0" x 3'-0". Judge each of the 21 rows against these norms, classify
DOOR / WINDOW / NEITHER / DUPLICATE, and say which existing openings ALREADY
comply with the spec targets.`,
  },
]

const classified = await parallel(
  LENSES.map((l) => () =>
    agent(l.prompt, {
      label: `classify:${l.key}`,
      phase: 'Classify',
      schema: {
        type: 'object',
        required: ['rows', 'notes'],
        properties: {
          rows: {
            type: 'array',
            items: {
              type: 'object',
              required: ['position', 'w', 'h', 'sill', 'verdict', 'reason'],
              properties: {
                position: { type: 'string' },
                w: { type: 'number' },
                h: { type: 'number' },
                sill: { type: 'number' },
                verdict: { type: 'string', enum: ['DOOR', 'WINDOW', 'NEITHER', 'DUPLICATE'] },
                confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
                reason: { type: 'string' },
              },
            },
          },
          notes: { type: 'string' },
        },
      },
    })
  )
)

const good = classified.filter(Boolean)
log(`${good.length}/4 lenses returned`)

// Find rows where the lenses disagree -- those are what deserve adversarial work.
const tally = {}
for (const res of good) {
  for (const r of res.rows || []) {
    const k = r.position
    tally[k] = tally[k] || { w: r.w, h: r.h, sill: r.sill, votes: [] }
    tally[k].votes.push({ verdict: r.verdict, reason: r.reason })
  }
}
const contested = Object.entries(tally).filter(([, v]) => {
  const s = new Set(v.votes.map((x) => x.verdict))
  return s.size > 1
})
log(`${contested.length} contested openings of ${Object.keys(tally).length}`)

phase('Verify')

const verdicts = await parallel(
  contested.slice(0, 8).map(([pos, v]) => () =>
    agent(
      `${CONTEXT}

CONTESTED OPENING: ${pos}  (W=${v.w}, H=${v.h}, sill=${v.sill})

Independent classifiers disagreed about it:
${v.votes.map((x, i) => `  lens ${i + 1}: ${x.verdict} -- ${x.reason}`).join('\n')}

You are the deciding architect. Consider that the client's stated purpose in
writing an ambiguous spec was specifically to test whether door and window can
be told apart when "both are just holes in a wall". Decide: DOOR, WINDOW, or
NEITHER. Then answer the practical question: if the spec were applied literally
to this opening, would the result be architecturally defensible or absurd?
Default to NEITHER (leave it alone) if applying the spec would destroy a
deliberate design composition.`,
      {
        label: `verify:${pos.slice(0, 22)}`,
        phase: 'Verify',
        schema: {
          type: 'object',
          required: ['position', 'final', 'apply_spec', 'rationale'],
          properties: {
            position: { type: 'string' },
            final: { type: 'string', enum: ['DOOR', 'WINDOW', 'NEITHER'] },
            apply_spec: { type: 'boolean' },
            rationale: { type: 'string' },
          },
        },
      }
    )
  )
)

phase('Synthesize')

const final = await agent(
  `${CONTEXT}

Four independent classifiers produced these results:
${JSON.stringify(good, null, 1).slice(0, 14000)}

Adversarial re-decisions on the contested openings:
${JSON.stringify(verdicts.filter(Boolean), null, 1).slice(0, 6000)}

Produce the single reconciled answer an architect would act on. For every
physical opening (after merging duplicate faces of the same hole) give:
its identity, whether it is a DOOR / WINDOW / NEITHER, and whether the spec
should be applied to it. Then give the concrete edit list: for each opening the
spec DOES apply to, state current W x H x sill and target W x H x sill.
Spec targets: windows 1.50w x 1.80h sill 0.50; doors 0.91w x 2.13h sill 0.
Also give a clear recommendation on which slabs should be taken to 0.10 m and
which datum (slab top / finished floor, versus slab soffit) should be held
fixed, reasoning as a practising architect about what keeps the building
coherent.`,
  {
    label: 'synthesize',
    phase: 'Synthesize',
    schema: {
      type: 'object',
      required: ['openings', 'slabs', 'summary'],
      properties: {
        openings: {
          type: 'array',
          items: {
            type: 'object',
            required: ['id', 'classification', 'apply_spec'],
            properties: {
              id: { type: 'string' },
              classification: { type: 'string', enum: ['DOOR', 'WINDOW', 'NEITHER'] },
              apply_spec: { type: 'boolean' },
              current: { type: 'string' },
              target: { type: 'string' },
              note: { type: 'string' },
            },
          },
        },
        slabs: {
          type: 'array',
          items: {
            type: 'object',
            required: ['name', 'change', 'reason'],
            properties: {
              name: { type: 'string' },
              current_thickness: { type: 'number' },
              change: { type: 'boolean' },
              datum: { type: 'string' },
              reason: { type: 'string' },
            },
          },
        },
        summary: { type: 'string' },
      },
    },
  }
)

return final
