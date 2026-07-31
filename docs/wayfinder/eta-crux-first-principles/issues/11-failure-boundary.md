# Failure, defect, and crash boundary

Type: grilling
Status: open
Blocked by: 05, 07

## Question

How do expected failures, defects, interruption, and cleanup failures cross Eta
Crux computation, driver, and adapter boundaries?

Decide:

- which failures are ordinary action or model values.
- which Eta typed failures can be staged-effect results.
- which framework operations have their own typed errors.
- what a transition exception or `eta_signal` invariant failure does.
- whether a defect stops one dynamic scope or the whole application.
- whether automatic restart exists at any level.
- how `Cause` and suppressed cleanup failures reach the hosted runner and
  explicit driver.
- what diagnostic context is stable and safe to retain.

The design must fail loudly without one catch-all error type. It must preserve
Eta's typed failure, defect, interruption, and resource-cleanup distinctions.
