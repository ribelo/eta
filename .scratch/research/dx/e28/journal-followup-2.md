# DX-E28 Follow-up 2 — Sealed Micro-predictions

This entry was written after reading `followup-2.md` and before changing the
contract, implementation, tests, registry, or report for W1–W4. It is immutable
after the sealing commit. Actuals and scoring belong in `report.md`.

## W1 — precise non-progress hazard

- With nine barrier participants and omitted `all` admission, exactly eight
  participants will become live.
- Advancing the deterministic test clock will admit no ninth participant and
  complete no child because every admitted worker remains blocked on the
  unadmitted participant.
- Cancelling the group will tear down all admitted participants and leave the
  runtime fiber census empty.
- The corrected contract and R127 will claim only this all-workers-blocked
  condition, and R127 will cite the new discriminating executable test rather
  than inferring non-progress from peak and positive full-fan-out tests.

## W2 — orphan removal

- Repository search will confirm `par_collect` has no caller after the unified
  admission change.
- Deleting it and replacing its module-header mention with `collect_workers`
  will not alter observable behavior or require caller changes.

## W3 — migration-discriminating JS evidence

- For a 12-element `map_effect` chunk whose first wave blocks, `map_par` will
  invoke the mapper exactly eight times before any worker is released.
- Releasing the wave will eventually invoke the mapper exactly 12 times and
  preserve input order and cleanup.
- The former `all (List.map f xs)` implementation would invoke the mapper 12
  times before interpretation reaches the blocked effects, so the new
  intermediate assertion will discriminate the migration.

## W4 — watchdogs

- The fixed nine-participant full-fan-out rendezvous will complete before a
  deterministic watchdog under the correct explicit bound.
- Generated nonempty rendezvous sizes 1–12 will likewise complete before a
  bounded watchdog.
- If explicit admission regresses below participant count, each test will
  produce a focused timeout/cancellation failure rather than hanging.

