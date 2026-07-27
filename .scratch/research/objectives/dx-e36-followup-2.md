# Follow-up 2: DX-E36 — rework after review (blocking: cause-shape parity is false)

The review proved with a probe that F2's cleanup-parity claim is false:
the use-winner branch extracts only the cleanup finalizer and discards
the interrupt wrapper even when the cancelled background's cleanup
FAILED. Old: `Finalizer(Suppressed{primary=Interrupt;
finalizer=Fail("Cleanup_failed")})`. New: `Finalizer(Fail(...))` —
evidence lost. And R143 registered the parity claim regardless — the
registry's worst violation kind. `objective.md` and `followup-1.md`
still apply.

## X1 (blocking) — fix the filter rule

The design intent was: ignore only a CLEAN internal cancellation (the
arbiter's mechanical cancel with nothing else wrong). The current
filter also drops the wrapper when the loser exit carries real
diagnostics. Correct rule, in the use-winner branch:

- clean internal cancellation (interrupt-only, no cleanup failure) →
  filtered, as intended;
- ANY other loser content (cleanup failure, defects, composites) →
  render and attach the COMPLETE loser cause, exactly as the old
  `finally (cancel child)` path did (interrupt wrapper preserved).

Prove the shapes now match old-vs-new exactly for body success, typed
failure, and defect — with the probe's exact expected trees committed
as test expectations.

## X2 (blocking) — parity tests that can actually fail

The current tests accept both shapes, check old/new independently, and
render typed errors as `"<typed failure>"`. Rewrite: exact structural
comparison old-shape vs new-shape per case; typed errors rendered with
a real `pp` so cleanup-error provenance is visible in the expectations.
A shape regression must fail the suite.

## X3 (blocking) — registry truth repair

- R143: after X1, the claim and its evidence must match reality (point
  at the X2 tests).
- R141: the same-release test never executes `par` — either add the
  comparative `par` observation the claim needs or reword the claim to
  what is actually pinned (publication-order contract; the `par` match
  is a contract-wording fact, not a test).
- Refresh stale line pointers (R38–R40, R138–R140, R142, and
  `report.md`'s native registration locations).

## X4 — strengthen the weaker evidence

- F3 jsoo: bring it to native parity (hold the losing finalizer,
  assert the result is unresolved, release, check exact failure +
  completed cleanup) instead of aliasing the typed-failure test.
- Add the missing shape: background wins first AND body cleanup then
  fails — assert that diagnostic is preserved, not suppressed.
- "At most one cancellation request": switch cancellation is idempotent
  so the suite cannot observe this. Either instrument a backend to
  count `fail_scope` calls, or reword the claim to the observable
  invariant (finalizers exactly once) — no unprovable claims in the
  contract or registry.

## Protocol

Journal note (micro-predictions), implement, re-run native trio +
mainline js_jsoo, update report + registry, usual signal. Same scope
fence. This file stays uncommitted.
