# Objective: DX-E31 — `[@@eta.trace]` promote-trigger measurement

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e31`
- Branch: `research/dx-e31-eta-trace-trigger` (already checked out here; do not create others)
- Phase: queued candidate (pre-registered) · Effort S · Risk low · **measurement + decision experiment — the deliverable is a verdict with evidence, not code**
- Evidence IDs: `V-DX-E31-*` (orchestrator log); your journal is the branch record

## Executor profile

Close a held experiment by evidence. The difficulty is decision hygiene:
the technical work for E10's sugar is DONE and proven on its branch, and
that fact is a temptation (sunk cost). Your job is to measure demand,
present it neutrally, and not let "it's already built" count as evidence
for wanting it.

## Mission

E10 (`let%eta` / `[@@eta.trace]` function-level trace sugar) was held by
its own gate: *"Hold by default even on success; promote only if reviewers
still ask for it after E7/E8 land."* E7 and E8 have long since landed.
This experiment answers: **does anyone still want the sugar?** — by
E10's pre-registered trigger, not by nostalgia.

**Consumption model (standing principle, V-DX-PRINC-1).** In-repo
unusedness is not evidence of unnecessity — BUT the consumption model
rescues only structural needs with a forcing function. Ask explicitly:
did anything promoted since E10 make function-level trace sugar *more*
needed (a forcing function), or less? E8 (`[%eta.result]`) made it less.

## Read first (in order)

1. `AGENTS.md`.
2. The E10 record ON ITS HOLD BRANCH — read with
   `git show research/dx-e10-function-sugar:.scratch/research/dx/e10/report.md`
   (and its journal/redteam neighbors). Note what is proven, and note
   the exact trigger wording.
3. `lib/eta/effect.mli` — the `fn` contract.
4. `.scratch/research/dx/e8/report.md` — what `[%eta.result]` absorbed.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e31/` **on this branch** (commit
them): `journal.md`, `census.md`, `report.md`.

## The experiment

**Step 1 — Census.** Count and characterize every
`Effect.fn __POS__ __FUNCTION__` site in `lib/ test/ examples/ bench/
http-testsuite/ drivers/` (orchestrator measured 4 sites / 2 files —
verify, and check E10's own count of 5 for what changed). For each site:
is it sugar-eligible (would E10's forms apply)? Is it in a consumer-shaped
position (application code) or framework machinery? Table in `census.md`.

**Step 2 — Forcing-function analysis.** List what landed since E10 was
held (E7, E8, E9b, E13, E15, E19–E20, E22–E30): does any of them create
a structural need for function-level trace sugar? Does E8 reduce the
need? Write it as evidence, one line per experiment.

**Step 3 — Decision memo.** The trigger is: *"reviewers still ask for it
after E7/E8."* Prepare the neutral decision material for the review
cohort: the census, the forcing-function analysis, and the two candidate
verdicts (FIRE / NO-FIRE) with their strongest forms. **The cohort
material must NOT mention that a complete, tested implementation exists
on the E10 branch** — sunk cost is not demand, and the pre-registered
protocol requires the cohort to judge want, not salvage.

**Pre-registered outcomes.**
- *Trigger FIRES* (cohort explicitly asks for the sugar): E10 promotes —
  one spelling, per E10's own recommendation (reviewers choose). The
  follow-up implementation round happens as a separate objective.
- *Trigger does NOT fire* (predicted): E10 closes as **killed**; the
  verdict + census + forcing-function analysis are the parking-lot
  record. No code changes.

## Protocol

1. **Seal your predictions** in `journal.md` (census numbers, cohort
   verdict, outcome, census/footgun deltas) — commit before
   investigation (`docs(dx-e31): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. Census first, analysis second, memo third — committed in that order.
3. **Gates** (docs-only expected):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   State that no code changed; run them anyway.
4. **Red-team pass:** attack your own memo — write the strongest
   argument FOR the sugar that the evidence does NOT support (e.g.,
   "consumers will want this once they see it") and mark it as
   unsupported, so the cohort sees the temptation labeled.
5. **Report** in `report.md`: census, forcing-function analysis, the
   cohort material (verbatim, as presented), your recommendation, and
   prediction scoring.

## Done means

- `E31 READY FOR REVIEW`
- `E31 BLOCKED: <reason>`
- `E31 STOP: <§4.6 stop condition>`

The orchestrator runs the cohort review (PR-style oracle, given the
neutral material), evaluates the trigger, and decides. Rework via
follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- No code changes. Do not port the E10 implementation.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e31/` must be committed.
