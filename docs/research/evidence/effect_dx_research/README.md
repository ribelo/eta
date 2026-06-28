# Effect DX Research

This note records the evidence behind the small DX additions around
`Effect.map_error`, `Effect.from_result`, `Eta.Syntax`, and `Effect.finally`.

## `map_error`

Eta's typed failure channel is represented by `Cause.Fail`, but `Fail` can live
inside `Suppressed`, `Sequential`, and `Concurrent` causes. A public
`map_error : ('e1 -> 'e2) -> ('a, 'e1) Effect.t -> ('a, 'e2) Effect.t` must
therefore transform every `Fail` node in the cause tree.

A top-level-only implementation would either leave old `'e1` values inside a
cause typed as `'e2` or use an unsafe cast. That would be wrong specifically for
resource cleanup and parallel failure cases, where typed failures commonly sit
under `Suppressed` or `Concurrent`.

Decision: `Effect.map_error` recursively maps all `Cause.Fail` nodes and
preserves defects, interruption, and cause shape.

Regression evidence: `test_effect_map_error_maps_full_cause`.

## `finally`

Effect's reference `ensuring` is implemented as `onExit`, so it runs after
success, failure, defect, or interruption. The reference tests also establish
that finalizers run on interruption and that finalizer failures are not treated
as catchable body failures.

Eta already has finalizer reporting semantics in `Runtime_core.with_finalizers`:

- successful body + failing finalizer returns the finalizer failure;
- failing body + failing finalizer returns `Cause.Suppressed`;
- cleanup runs under cancellation protection.

Decision: `Effect.finally cleanup effect` reuses these semantics for one-shot
cleanup around a single effect. The body does not get a fresh resource scope.
The cleanup does get its own cleanup frame, so nested `acquire_release` calls
inside cleanup are drained before `finally` returns.

Regression evidence:

- `test_effect_finally_success_and_failure`;
- `test_effect_finally_cleanup_failure_after_success`;
- `test_effect_finally_suppresses_cleanup_failure`;
- `test_effect_finally_runs_on_cancellation`;
- `test_effect_finally_cleanup_failure_not_caught_as_body_failure`.

## Deferred

`map_error_case` remains deferred. It needs a separate row-polymorphism design
instead of a broad catch-all helper.

`with_resource_background` remains deferred. The safe recipe is documented with
`Effect.scoped`, `Effect.acquire_release`, and `Effect.with_background`.
