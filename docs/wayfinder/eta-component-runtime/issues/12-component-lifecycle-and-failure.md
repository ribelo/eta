# Component lifecycle and failure

Type: prototype
Status: open
Blocked by: 08, 11

## Question

Which component-instance state machine preserves Eta failure, cancellation, and
cleanup semantics during activation, deactivation, reactivation, and partial
failure?

Prototype inertial transitions and target changes during asynchronous work.
Decide where typed activation errors live, whether sibling instances continue,
when retries are legal, and how a failed instance returns to service.

The answer must preserve complete Eta causes and must not leak an escaping fiber
handle as the ownership model.
