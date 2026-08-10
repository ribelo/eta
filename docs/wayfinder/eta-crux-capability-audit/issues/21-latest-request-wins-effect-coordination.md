# Latest-request-wins effect coordination

Type: grilling
Status: open
Blocked by: 08

## Question

Does Eta Crux need a graph-owned protocol that prevents stale asynchronous
effect results from changing the current model?

Compare application sequence tokens, cancellation on replacement, and a
framework-owned generation or result guard. Keep basic change-triggered effects
as application-composable.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, request identity, ordering,
out-of-order completion, child disposal, and same-key reincarnation. Also
specify cancellation, failure behavior, semantic laws, test controls, ownership,
and migration effects.
