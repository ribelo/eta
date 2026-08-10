# Structural model reset

Type: grilling
Status: open
Blocked by: 08

## Question

Does Eta Crux need one graph-owned operation that resets every stateful
computation in a structural subtree?

Compare explicit reset actions, keyed-incarnation replacement, and a structural
reset capability. Keep prior-value storage as application-owned state.

Decide whether to adopt, defer with a precise condition, or reject structural
reset. If adopted, specify the API shape, reset authority, traversal boundary,
active-child behavior, and keyed-child behavior. Also specify custom reset
functions, ordering, failure behavior, semantic laws, test controls, ownership,
and migration effects.
