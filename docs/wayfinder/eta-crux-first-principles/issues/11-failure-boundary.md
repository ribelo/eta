# Failure, defect, and crash boundary

Type: grilling
Status: open
Blocked by: 05, 07, 08

## Question

How do expected failures, defects, interruption, and cleanup failures cross Eta
Crux computation, driver, and adapter boundaries?

Decide:

- which failures are ordinary action or model values.
- how action-routed expected failures remain distinct from effect defects and
  interruption.
- which framework operations have their own typed errors.
- what a transition exception or `eta_signal` invariant failure does.
- whether a defect stops one dynamic scope or the whole application.
- whether automatic restart exists at any level.
- how `Cause` and suppressed cleanup failures reach the hosted runner and
  explicit driver.
- what diagnostic context is stable and safe to retain.

Source opening and producer typed failures already become terminal actions.
Source defects, finalizer failures, and sends after closed ingress still need
the root and driver rules from this ticket.

The design must fail loudly without one catch-all error type. It must preserve
Eta's typed failure, defect, interruption, and resource-cleanup distinctions.
