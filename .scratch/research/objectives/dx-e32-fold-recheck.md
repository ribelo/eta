# Objective: DX-E32 — `fold ~ok:Fun.id` usage-data re-check (F2)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e32`
- Branch: `research/dx-e32-fold-recheck` (already checked out here; do not create others)
- Phase: queued candidate (F2 watch item) · Effort S · Risk low · **measurement + decision experiment with a build contingent**
- Evidence IDs: `V-DX-E32-*` (orchestrator log); your journal is the branch record

## Executor profile

Measure, judge honestly, and — only if the verdict says so — implement a
small, well-documented shorthand. The trap is nostalgia: E23 deleted
`recover` on purpose, and this experiment is not "bring it back because
it was nice" but "does 26 sites of demonstrated frequency earn a special
case under the library's own progressive-disclosure culture". The other
trap is hiding the tension: if `recover` returns, the handle-cluster val
count goes 10 → 11 while the *concept* count claims to stay flat — that
must be argued, not asserted.

## Mission

E23 replaced `recover f` with `fold ~ok:Fun.id ~error:f` — one
both-channel fold, no near-duplicates. Both the E23 executor and the
blind reviewer flagged the noise at pure recovery-only sites (F2 watch
item). 26 sites now carry it. This experiment decides: does a shorthand
earn its val, or does E23's verdict hold?

**Consumption model (standing principle, V-DX-PRINC-1).** 6 of the 10
affected files are in `examples/` — the surface that teaches external
consumers. Weigh that honestly in both directions: teaching code is
where noise costs most, and where a second name also costs most.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/effect.mli` — the `fold` contract and the handle cluster.
3. `.scratch/research/dx/e23/report.md` + the E23 journal — why
   `recover` was deleted; the review evidence that `recover` "could
   easily imply exception recovery" (rated 3 in the old surface).
4. `.scratch/research/dx/e20/report.md` — the progressive-disclosure
   precedent (`intercept_log` + friendly special cases kept).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e32/` **on this branch** (commit
them): `journal.md`, `census.md`, `report.md`.

## The experiment

**Step 1 — Census.** Verify 26 sites / 10 files (orchestrator measured;
hunt for variants it missed — `~ok:(fun x -> x)`, `~ok:(function x ->
x)`, multi-line forms). Classify each: constant default vs. function of
the error; consumer-shaped vs. framework. `census.md`.

**Step 2 — Candidates.**
- **A — verdict holds.** `fold` stays the only both-channel fold; the
  report becomes the record that 26 sites do not earn a special case.
- **B — `recover` returns** as `fold`'s documented special case:
  ```ocaml
  val recover : ('err -> 'a) -> ('a, 'err) t -> ('a, 'outer) t
  (** Pure typed-failure recovery. [recover f eff] is
      [fold ~ok:Fun.id ~error:f eff]. Special case of {!fold} for
      recovery-only sites; the typed channel only — defects,
      interruption, and finalizer diagnostics are not recovered. *)
  ```
  With: docs-first contract; 1-line implementation; the 26 sites
  migrated (examples first — the teaching surface must be consistent);
  parity tests (`recover f ≡ fold ~ok:Fun.id ~error:f` including
  defect/interruption pass-through); law-registry row.
- **C — anything else** (different name, different shape): BLOCKED back
  to the orchestrator with the evidence; do not pick silently.

**Pre-registered gates.** *B promotes* if: census confirms the frequency
(≥ ~20 sites, consumer-shaped present); parity is exact; and the review
does NOT find the exception-misreading re-opened (the decisive
question). *A holds* if census undercuts the frequency claim, or the
review finds `recover` — even framed as `fold`'s special case — reads
as exception-catching (the E23 misreading reborn).

**The tension you must argue (not assert).** B takes the handle cluster
10 → 11 vals while claiming concepts flat. The argument available:
E20's progressive disclosure — a documented special case of one concept
is not a second concept; `recover` is taught AS `fold`'s shorthand, and
the mli cross-refs both ways. If you find that argument weak, say so.

## Protocol

1. **Seal your predictions** in `journal.md` (census, decision,
   review outcome, deltas) — commit before investigation
   (`docs(dx-e32): seal predictions`). Never edit after. (Dual-sealing:
   orchestrator's set is inherited on master; do not read it.)
2. Census first, decision second, implementation (only if B) third.
3. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   Run regardless of outcome; state the code-delta scope.
4. **Mechanical extras** (if B): parity tests, law row, census/footgun
   deltas, the 26-site migration diff.
5. **Red-team pass:** (if B) write the exception-misreading bug — a
   newcomer uses `recover` intending to catch a `failwith`. Show what
   happens (defect surfaces via `Die`) and whether the mli sentence
   prevents the wrong expectation at review time. (If A) red-team the
   other direction: does `fold ~ok:Fun.id` at a teaching site invite
   any wrong reading the shorthand would have prevented?
6. **Report:** census, hypothesis ledger (A/B/C), the tension argument,
   parity evidence (if B), prediction scoring, recommendation.

## Done means

- `E32 READY FOR REVIEW`
- `E32 BLOCKED: <reason>`
- `E32 STOP: <§4.6 stop condition>`

Orchestrator runs the review (decisive question: exception-misreading
re-opened or not) and decides. Rework via follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Code changes only if B, and only the ones B specifies. No other
  surface changes.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e32/` must be committed.
