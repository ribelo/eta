# Objective: DX-E9b — Honest `and*`: sequential everywhere, concurrency spelled `Effect.par`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e9b`
- Branch: `research/dx-e9b-honest-and-star` (already checked out here; do not create others)
- Phase: C (syntax & PPX) · Effort S–M · Risk low–med
- Evidence IDs: `V-DX-E9B-*` (orchestrator log); your journal is the branch record

## Executor profile

A semantics swap with a safety argument, not a comprehension argument.
The implementation already exists (the held E9 branch's `Applicative`
module — port it); the work is honest migration (two `and*` files),
law tests (mostly written — port them), and a red-team that proves the
invited bug is now *unwriteable*. Judgment call: which existing `and*`
sites want concurrency (`Effect.par`) vs. are fine sequential.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The design
rule for this experiment is the **least astonishment principle**: `and*`
does what OCaml intuition says (sequencing); anything that forks fibers
must be spelled `Effect.par` at the exact spot. The E9 hold (V-DX-E9-002)
showed module-switched `open`s carry no semantics — the meaning must live
in the operator/combinator at the call site.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/syntax.ml` / `syntax.mli` — current `and*`/`and+` = `Effect.par`.
3. **The E9 branch** `research/dx-e9-syntax-parallel-applicative`
   (pushed): its `Applicative` implementation (`lib/eta/syntax.ml` there)
   and its law tests (`test/core_common/effect_common_suites.ml` there,
   tests Effect 55–61) are yours to port. Its journal/report
   (`.scratch/research/dx/e9/`) explain the hold.
4. The two `and*` usage files: `examples/background_lifecycle.ml`,
   `test/api_dx/api_dx_examples.ml`.
5. `docs/api-dx.md` — syntax guidance you'll rewrite.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: (a) the sequential product obeys its laws (executable);
(b) the red-team proves the old invited bug is unwriteable and the
residual surprise is perf-only; (c) migration is semantics-preserving
per call site, each with a one-line justification in your journal.

Working artifacts in `.scratch/research/dx/e9b/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The contract (exact)

```ocaml
(* lib/eta/syntax.ml — the whole change *)
let ( and* ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
let ( and+ ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
```

- `and*`/`and+` STAY in `Syntax` (no submodules; the E9 split is dead).
- Sequential product: left settles fully, then right runs; nothing forked;
  left failure skips right (fail-fast by sequencing).
- `Effect.par` is UNCHANGED — the explicit concurrent spelling.
- No compatibility shim: the old par-`and*` is deleted (AGENTS.md).

## Protocol (predictions commit FIRST and separately; then step commits)

1. **Seal your predictions** in `.scratch/research/dx/e9b/journal.md`:
   expected review answers, migration split for the 2 files (which sites
   go `Effect.par`), two likeliest reviewer misreadings. Commit before any
   code change (`docs(dx-e9b): seal predictions`). Never edit afterward.
2. **Docs-first.** Rewrite the `syntax.mli` docs for `and*`/`and+` before
   implementing: ≤ 5 lines each — "strict left-to-right; nothing is
   forked; for concurrency use {!Effect.par}". The doc must also state
   the migration rule of thumb: "`and*` sequences; `Effect.par` races."
3. **Implement the smallest change.** Port the E9 branch's `Applicative`
   as top-level `Syntax.and*`/`and+`. Migrate the 2 usage files — each
   site: keep behavior via `Effect.par` if it wanted concurrency, else
   sequential `and*`; one-line justification per site in your journal.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
   ```
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - Law tests (port from the E9 branch, adapt to top-level `Syntax`):
     strict left-to-right (ordered side-effect log); right-waits-for-left
     (promise gate); fail-fast by sequencing; interrupt-left-skips-right.
     `Effect.par` laws are already covered by existing par tests — cite.
   - Census: syntax operators 5 vals (unchanged count), modules 1
     (unchanged). Footguns: expect −1/+0 with the documented
     perf-surprise. Update `docs/api-dx.md` `and*` guidance.
6. **Red-team pass** in `.scratch/research/dx/e9b/redteam/` with verdicts:
   (a) the old invited bug — order-sensitive transfer written with `and*`
   — run it, show the ordered execution log: **observably sequential,
   correct by construction**; (b) a program that WANTED concurrency but
   used `and*` — show it is correct-but-serialized (both effects run, in
   order, no cancellation on failure; the only cost is latency);
   (c) docs-claim check: grep the mli for any remaining implication that
   `and*` is concurrent.
7. **Review packet** in `.scratch/research/dx/e9b/review/`, labeled (the
   orchestrator blinds it):
   - `transfer.ml` — the order-sensitive debit/credit transfer written
     with `and*` (the safe shape).
   - `loads.ml` — concurrent user/perms loads written with `Effect.par`.
   - `MANIFEST.md`, `QUESTIONS.md`: "how many fibers fork in transfer?",
   "if debit fails does credit run?", "is the effect order guaranteed in
   transfer?", "what does `Effect.par` do in loads?", "where would you
   look for the concurrency in loads?"
8. **Report** in `.scratch/research/dx/e9b/report.md`: gates summary, law
   evidence, census/footgun actuals vs. sealed predictions, red-team
   outcome, deviations, and your promote/hold/kill recommendation against
   the pre-registered decision rule (in the sealed orchestrator
   predictions, restated in your journal).

## Done means

Your final message ends with exactly one of:

- `E9b READY FOR REVIEW`
- `E9b BLOCKED: <reason>`
- `E9b STOP: <§4.6 stop condition>`

The orchestrator verifies, runs the independent review, and decides per
the pre-registered rule.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E9b's surface: `lib/eta/syntax.*`, the 2 usage files,
  `docs/api-dx.md`, syntax tests, README syntax mention if present.
  Do NOT touch `Effect.par` or anything else in `effect_core.ml`.
  Adjacent footguns → journal follow-ups.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e9b/` must be committed.
