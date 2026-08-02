# Production request-cancellation contract

Type: grilling
Status: claimed
Blocked by: 02

## Question

What exact production contract makes `Supervisor.Scope.request_cancel`
implementation-ready?

Decide:

- the exact public type and module placement.
- the cancellation-request linearization point.
- idempotence and repeated-request behavior.
- races with normal completion and child failure.
- the relation between `request_cancel`, `cancel`, and `await`.
- error and complete `Eta.Cause` preservation.
- ordering for several request operations in one scope program.
- backend obligations and portability constraints.
- negative type checks that preserve structured ownership.
- named executable laws and required law-registry rows.
- the focused and repository-wide production verification commands.

The contract must remain backend-neutral. It must not expose a runtime scope,
cancellation token, or detach operation.
