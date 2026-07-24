# Follow-up 1: DX-E27 — not a violation; the dual-sealing design

Your stop was disciplined but the premise is a misreading. Nothing is
wrong with the branch; no history needs correcting.

## What you saw

The branch tip commit `086f64f9 "docs(dx): seal E27 predictions
(V-DX-E27-001)"` touched `.scratch/research/dx-journal.md`. That is the
**orchestrator's** sealed prediction set, committed **on master BEFORE
the branch was cut** — every experiment branch inherits it by design.
This is the programme's dual-sealing protocol:

1. Orchestrator seals predictions in `.scratch/research/dx-journal.md`
   on master before the branch exists (that commit travels with the
   branch as ancestry).
2. Executor seals its OWN, INDEPENDENT predictions in
   `.scratch/research/dx/e<NN>/journal.md` as its first commit ON the
   branch (branch history timestamps the sealing).

The scope fence means: never READ or EDIT the orchestrator's journal
file — reading my predictions would contaminate yours. Its presence in
history is expected, not a violation. `git log` showing the commit
subject is unavoidable and harmless.

## What to do (unchanged from the objective)

1. Create `.scratch/research/dx/e27/journal.md` with YOUR sealed
   predictions (encoding choice, gate placement, measured allocation
   expectation, census/footgun deltas) — commit it FIRST, before any
   code change (`docs(dx-e27): seal predictions`).
2. Continue the objective exactly as written (docs-first, implement,
   gates, tests, measurement, red-team, review packet, report).

Everything else in `objective.md` stands. `E27 READY FOR REVIEW` /
`BLOCKED` / `STOP` when done.

## Note added to future objectives (orchestrator)

"The branch's tip commit on creation contains the orchestrator's sealed
predictions in `.scratch/research/dx-journal.md` — expected, per
dual-sealing. Your own predictions go to
`.scratch/research/dx/e<NN>/journal.md` as your first branch commit."
