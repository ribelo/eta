# DX-E24d Journal — Retry cause alignment

Branch: `research/dx-e24d-retry-cause-alignment`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24d`

## Predictions (sealed)

Sealed before production code, public prose, tests, or ledger edits. Wrong
predictions remain as evidence and will be scored in the final report.

1. **Intentionality.** History will show that bare-`Cause.Fail` matching in
   `retry` predates the shared `stripped_uncatchable` / `first_typed_failure`
   boundary, while `retry_or_else` adopted that boundary later without an
   explicit rationale for keeping `retry` narrower. Predicted verdict:
   accidental divergence.
2. **Alignment.** `retry` should use the shared boundary: a composite primary
   tree containing typed failures and no defect, interruption, or finalizer
   diagnostic is retryable, and the predicate and schedule see the first typed
   failure in cause order.
3. **Uncatchable composites.** A composite containing any uncatchable
   diagnostic will not invoke the predicate or schedule and will preserve the
   original cause unchanged.
4. **Terminal causes.** Predicate rejection and schedule exhaustion will
   preserve the original composite cause, not collapse it to the selected
   `Cause.Fail`. This matches `catch_some`'s non-recovery path. I predict
   `retry_or_else` is coherent because its terminal paths deliberately replace
   the source through `or_else`, whereas `retry` has no replacement effect.
5. **Blast radius.** Existing bare-failure retry tests and all
   `retry_or_else` behavior will remain unchanged. Only tests or callers that
   relied on catchable typed composites being terminal without consulting the
   predicate/schedule can observe the new behavior.
6. **Debt.** New named tests will close the `retry` half of CD-E22-006. The
   independent `retry_or_else` current-runtime failure-path debt will remain as
   a narrower dated row unless the existing R82 matrix already closes it.
7. **Gates.** The focused suite and all five required Nix gates will pass after
   the minimal implementation, prose, test, ledger, and changelog changes.

## Execution log

No production edits preceded the sealed predictions commit.
