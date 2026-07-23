# Objective: DX-E24c — Schedule-hook channel deletion (implementation)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24c`
- Branch: `research/dx-e24c-hook-deletion` (already checked out here; do not create others)
- Phase: E · Effort M · Risk med (one substantive engine rewrite inside a mechanical deletion)
- Contract: `.scratch/research/dx/e24b/review/DELETION_PROPOSAL.md` (review-corrected; on master)
- Evidence IDs: `V-DX-E24C-*` (orchestrator log); your journal is the branch record

## Executor profile

A large, well-specified deletion: 3→2 type parameters across 8 public
operations, removal of the tap machinery and the suspended-step engine,
E22 census surgery, recipe documentation, negative compile tests. The
contract below is exact — your job is faithful execution plus ONE
substantive piece: rewriting `schedule.ml`'s internal engine to remove
the suspended layer while preserving every schedule law (the 66 E22
properties are your safety net; they must stay green with zero
expectation changes except the census-surgery rows).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Delete the
library's heaviest public type parameter on the evidence that nothing
uses it — and leave behind a Schedule that a newcomer can read in one
sitting.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, no shims, delete old paths, break
   loudly. **E22 policy: the census surgery is part of this contract.**
2. `.scratch/research/dx/e24b/review/DELETION_PROPOSAL.md` — THE
   CONTRACT. Its 7-step slice, ancillaries, E22 slice, recipe guidance,
   demand gate, and required implementation gates are authoritative.
3. `.scratch/research/dx/e24b/report.md` — the decision record (why D
   won; the loss statement you must honor in docs).
4. `lib/eta/schedule.ml` + `.mli` — the whole file, incl. the suspended
   engine you are removing.
5. The drivers: `lib/eta/effect_schedule.ml`, `lib/eta/resource.ml`,
   `lib/stream/eta_stream.ml` + `.mli`, `lib/http/client/retry.ml(i)`.
6. `test/laws/law_properties.ml` schedule rows + LAWS.md — the safety net
   and the surgery table.

## Pre-flight (do FIRST, commit before any deletion)

1. **Reversal-gate check.** Run the D surface census
   (`.scratch/research/dx/e24b/redteam/d-surface.sh` or your own `rg`
   census): confirm ZERO non-test tap producers. If any appeared since
   E24b, STOP — that is the demand signal; report it instead of deleting.
2. **Seal your predictions** in `.scratch/research/dx/e24c/journal.md`:
   migration size, the engine-rewrite approach, which laws you expect to
   be hardest to preserve, census/footgun deltas. Commit first
   (`docs(dx-e24c): seal predictions`).

## The deletion (per the proposal's slice)

1. `Schedule.t`/`driver`: three parameters → two. Remove `tap_input`,
   `tap_output`, the internal tap nodes, `no_hook`, the suspended `step`
   type (`Hook`/`Complete`), and the internal engine
   (`suspended`/`Return`/`Run_hook`/`bind_suspended`/`map_suspended`/
   `run_suspended`). Generalize the existing direct `step` and `next` to
   every two-parameter driver; `step` keeps returning
   `(decision * driver)`.
2. Remove `step_plan` and `step_with_hooks`; Effect, Resource, and
   Stream drivers use the direct `step` across their 3 + 1 + 4
   operations. Update Stream's four internal schedule constructors and
   four fold functions.
3. The 8 public operation signatures take two-parameter schedules.
   Remove the `no_hook` marker from the two HTTP retry signatures and
   from `lib/http/client/retry.ml`'s internal `packed_schedule`.
4. Remove or rewrite the six explicit tap-behavior promises in Effect,
   Resource, and Stream interfaces. Where a promise is removed, the doc
   points at the ordinary recipe (instrument the source effect;
   `Resource.auto`: instrument `load`; Stream: `tap_error` on the source
   before retry / `tap` for emissions) with the honest boundary note
   (schedule-local boundaries no longer exist).
5. Remove all 25 tap constructions (12 pre-E24b fixtures, 6
   ownership-table, 6 suspension/wrapper, 1 output-cancellation
   integration). Replace only operation-level behaviors still required.
6. **E22 surgery** (the corrected slice): delete M65–M67, M95–M105,
   M112, R96, R102; split/rewrite the tap-specific portions of R80/R100;
   preserve M68 (`next`), R94 (`Continue` delay), R95 (`jittered`
   random), and M106–M111's surviving `named` claims via a small no-hook
   replacement property. Recensus LAWS.md.
7. `Eta_js`: through its existing Schedule re-export; mainline JS gates
   must be green.
8. **Ancillaries**: the ternary test annotation at
   `test/core_common/properties_common_suites.ml:12`; the old C/no_hook
   red-team fixtures under `.scratch/research/dx/e24b/redteam/` — rework
   or remove so its `run-all.sh` stays meaningful post-deletion (it is
   merged evidence; keep it runnable); `docs/research/dx.md` and the
   parking-lot entry: E24b's question is now CLOSED by implementation
   (orchestrator will finalize; leave the section accurate in your diff).

## Gates (all required)

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop -c dune build @doc
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force
```

`_build-mainline` for all mainline invocations. Fix-forward up to three
attempts per failure class, then BLOCKED.

## Mechanical extras

- **Compile-negative fixture** (cram-style): ternary `Schedule.t` and
  `tap_input` usage fails with a clear error; snapshot the message.
- **Positive fixture**: a two-parameter custom driver using direct
  `step` compiles and runs.
- **Law preservation proof**: `test/laws` green with zero expectation
  changes except the census-surgery rows — every surviving schedule
  property passes against the new engine.
- Census table: params 3→2, tap vals 2→0, protocol vals
  (`step_plan`/`step_with_hooks` deleted, `step`/`next` generalized),
  Schedule cluster concepts. Footguns: expect −1/+0.
- `docs/api-dx.md`: schedule section updated (2-param signatures,
  recipe guidance replacing tap guidance).

## Red-team (committed under `redteam/` with verdicts)

- (a) Old-style code (ternary type + tap) fails LOUDLY, not silently
  (the compile-negative fixture, with the error text reviewed for
  helpfulness).
- (b) The ordinary recipe survives deletion: the named integration test
  `retry attempts can be observed without schedule taps` passes against
  the new engine (it instruments the source — no taps).
- (c) A schedule-law regression attempt: deliberately break one engine
  invariant (e.g. swap and_then order) in a THROWAWAY commit and show a
  named law catches it — then revert. This proves the safety net covers
  the new engine, not just the old one.

## Review packet (in `.scratch/research/dx/e24c/review/`)

- `sigs-before.md` / `sigs-after.md`: the 8 public signatures.
- `recipe-after.md`: the post-deletion observation recipes as docs will
  show them.
- `QUESTIONS.md`: "what happened to schedule taps, and what do I do
  instead?" (the migration question a user would ask).

## Report

`report.md`: gates summary, engine-rewrite approach, law-preservation
evidence, census/footgun actuals vs. predictions, red-team outcomes,
deviations from the proposal (each justified), promote/hold/kill
recommendation.

## Done means

- `E24C READY FOR REVIEW` / `E24C BLOCKED: <reason>` / `E24C STOP: <§4.6>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/` (except the dx.md status accuracy noted above),
  `.scratch/research/dx-prd-0001.md` beyond the parking-lot entry,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- This is a DELETION experiment: no new public API. If you find the
  engine cannot be removed without changing a surviving law's semantics,
  STOP and report — that would contradict the proposal's core claim.
- Stay in E24c's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e24c/` must be committed;
  `objective.md` stays uncommitted.
