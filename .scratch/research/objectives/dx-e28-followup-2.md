# Follow-up 2: DX-E28 — rework after review (four items)

The unified-admission implementation is sound; the contract and evidence
around it are not yet. Four findings, all verified by the orchestrator.
`objective.md` and `followup-1.md` still apply.

## W1 (blocking) — the deadlock claim is overstated, and R127 overclaims proof

The mli says "a child waiting on an unadmitted sibling deadlocks." False as
an absolute: with bound 2, child A can wait on initially-unadmitted C while
B completes, freeing a worker that admits C — no deadlock. The true hazard
is: **when ALL admitted workers are blocked on unadmitted work**, the group
cannot make progress. And registry row R127 registers the deadlock behavior
as proved while its cited tests only prove peak admission and full-fan-out
success — a law-registry violation (AGENTS.md law gate).

Fix both halves:
- Reword the mli warning precisely (all-workers-blocked condition; keep it
  one sentence and keep the full-fan-out recipe beside it).
- Add a discriminating bounded-barrier test (test clock, deterministic):
  9 participants that each require all 9 live to proceed, bound omitted
  (= 8). Assert: exactly 8 admitted; advancing the clock completes nothing
  (group cannot progress); then cancel the group and assert cleanup leaves
  no pending fibers. That is the deadlock claim made observable
  (non-progress + clean teardown), and it is what R127 must point to.
  Update the mli/registry wording to match what the test discriminates.

## W2 — orphaned `par_collect`

`all_eval` was its only caller. `lib/eta/effect_concurrent.ml:87-96` is now
dead code, and the module header (line 1) still advertises `par_collect`
and omits `collect_workers`. Delete the function and fix the header.
(AGENTS.md: delete old paths; orphans created by your change are yours to
remove.)

## W3 — JS migration tests do not discriminate the migration

The new js_stream tests would pass if `map_effect` were reverted to
`all (List.map f xs)` — post-E28, both spellings cap at 8. The actual
value of the migration is mapper laziness: old code invoked `f` on all 12
elements eagerly at blueprint/admission; `map_par` invokes `f` only as
workers admit inputs. Add the discriminating test: 12 inputs whose effects
block; assert the mapper invocation count is 8 (admitted) while the first
wave is blocked — the old implementation would show 12. Update the report's
"lazy mapper invocation" claim to point at it.

## W4 — rendezvous hangs instead of failing on regression

The 9-participant rendezvous is a real barrier, but an admission regression
would hang the suite indefinitely. Wrap it (and the generated qcheck
variant) in a watchdog (test-clock timeout or bounded cancellation) so a
regression produces a focused failure, not a hang.

## Protocol

Journal note (micro-predictions for W1–W4), implement, re-run native trio
and the mainline JS suites (`test/js_jsoo test/js_stream test/http_js`
+ `test/laws`), update report + registry, and the usual signal. Same scope
fence. This file stays uncommitted.
