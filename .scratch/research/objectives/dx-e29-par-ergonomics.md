# Objective: DX-E29 — Concurrent product ergonomics (`par3`/`par4`)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e29`
- Branch: `research/dx-e29-par-ergonomics` (already checked out here; do not create others)
- Phase: queued candidate · Effort S · Risk low · **frequency-gated sugar experiment**
- Evidence IDs: `V-DX-E29-*` (orchestrator log); your journal is the branch record

## Executor profile

Small API-shape experiment with an honest kill path. The difficulty is not
implementation (trivial) but judgment hygiene: the repo shows ~zero
frequency for the pain this sugar treats, and the experiment's value is
deciding whether E9b's structural forcing justifies it anyway. You must
present the frequency evidence straight, not flatter the sugar.

## Mission

E9b made concurrency explicit: `Effect.par` is THE user spelling for
concurrent products. Three fetches concurrently today means
`Effect.par (Effect.par a b) c` → `((a * b) * c)` — nested tuples, awkward
pattern matches. The explicit form should be pleasant, not penance. But
T4: sugar follows demonstrated frequency, not symmetry — and the E6 lesson
(`with_2`/`with_3` killed: helpers must carry execution strategy, not just
cardinality) and the `sync_option` lesson (killed: zero usage evidence)
are the two traps at your feet.

**Consumption model (standing principle, V-DX-PRINC-1).** Eta is consumed
primarily by EXTERNAL consumers. In-repo unusedness is not evidence of
unnecessity — the consumers who feel the pain are downstream and invisible
to a repo census. We close complexity inside to provide a nice interface
outward. Frequency gates apply only when no structural need exists; here a
candidate structural need exists (E9b forces the concurrent-product shape
onto downstream code). Your job is to weigh BOTH signals honestly — not to
treat the census as a verdict, and not to wave the structural argument
through unexamined.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/effect.mli` — `par`, `all`, `map_par`; `effect_concurrent.ml`
   for the machinery (`par_eval`, `collect_workers`).
3. `.scratch/research/dx/e6/report.md` — why `with_2`/`with_3` died
   (cohort preferred the explicit ladder; "names must carry execution
   strategy, not just cardinality" — now a standing review criterion).
4. `.scratch/research/dx/e28/report.md` §V-DX-E28-02 — the census method
   for frequency questions.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Candidates below; build the hypothesis ledger, test the serious ones.
Artifacts in `.scratch/research/dx/e29/` **on this branch** (commit them):
`journal.md`, `report.md`, `census.md`.

## The experiment

**Design questions (settle each with evidence):**

1. *Frequency.* Verify the orchestrator's count (nested-`par` sites: 2,
   one test file) and hunt for anything it missed — different spacings,
   `par` via `Syntax`, partial applications, pipeline nests. Then answer
   BOTH parts: (a) is the pain demonstrated in-repo? (b) is the structural
   argument true — does E9b actually force this shape onto downstream
   consumers, and would par3/par4 serve them? Per the consumption model,
   a negative (a) does NOT kill the experiment when (b) is true; report
   both findings separately and let the review weigh them.
2. *Shape.* Candidates:
   - **A — `par3` / `par4`** flat tuples:
     ```ocaml
     val par3 : ('a,'err) t -> ('b,'err) t -> ('c,'err) t -> ('a * 'b * 'c, 'err) t
     val par4 : (* same, four *)
     ```
     Arity cap 4 (OCaml practical tuple limit; E6's with_3 cap precedent).
   - **B — a builder** (`Effect.Par` applicative chain or similar) — more
     machinery; only if A's arity cap is shown to bite in practice.
   - **C — kill** — nested `par` + flattening map is fine; arity sugar is
     furniture. This is a respectable outcome with real evidence value.
3. *Semantics inheritance.* `par3`/`par4` must behave as flattened nested
   `par`: fail-fast cancels ALL siblings on first failure; tuple order =
   argument order; cancellation/finalizer parity; blueprint
   names/footprints aggregate all children (like `all`). No new semantics
   of your own.

**Pre-registered gates.** *Promote* A (both vals, one concept) if: the
semantics inherit cleanly with tests; the PR review prefers flat tuples
over the status quo; and the frequency evidence is reported straight
(whatever it says). *Kill* if the review finds flat tuples no clearer
than nested `par` + flattening map, or reads the pair as arity furniture
(the `sync_option`/`with_2` pattern). *BLOCKED* if you find the shape
question genuinely forks (e.g., builder B demonstrably better — bring
evidence, don't pick silently).

## Protocol

1. **Seal your predictions** in `journal.md`: frequency findings, the
   decision, census/footgun deltas, the review outcome. Commit before
   code (`docs(dx-e29): seal predictions`). Never edit afterward.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. **Frequency census first** (`census.md`), decision second.
3. **Docs-first** if building: `.mli` contract (≤ 8 lines each; cross-ref
   `par` and the arity-cap rule "beyond 4, use `Effect.all` or nested
   `par`").
4. **Implement the smallest honest answer** (or none, if C wins — then
   the report IS the deliverable).
5. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   Pure-addition changes: state that and run them anyway. ≤ 3 fix
   attempts per failure class, then BLOCKED.
6. **Mechanical extras** (if building): tests per design question 3
   (order, fail-fast each position, sibling cancellation, finalizer
   parity, blueprint metadata aggregation); law-registry rows for any
   law-bearing mli claims; census +2 vals; footgun delta.
7. **Red-team pass** (if building): write the pattern the sugar is meant
   to prevent (nested `par` with a 3-tuple pattern match that mismatches
   the nesting — `((a, b), c)` vs `(a, b, c)`). Does `par3` make that
   bug class unwritable? Does it introduce any new one?
8. **Report** in `report.md`: frequency evidence, hypothesis ledger
   (A/B/C with statuses), semantics-inheritance evidence, census/footgun
   actuals vs. sealed predictions (scored), red-team, and your
   promote/hold/kill recommendation against the pre-registered gates.

## Done means

- `E29 READY FOR REVIEW`
- `E29 BLOCKED: <reason>`
- `E29 STOP: <§4.6 stop condition>`

Orchestrator verifies and runs the PR-style oracle review (the kill gate
lives there). Rework via follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E29's surface: `par3`/`par4` (if built), their tests, their
  docs. No changes to `par`, `all`, `map_par`, or Syntax.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e29/` must be committed.
