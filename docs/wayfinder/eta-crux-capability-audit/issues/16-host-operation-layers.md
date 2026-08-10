# Host-operation layers

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need composable layers over host operations?

Check whether `Request.Driver_event.handle` and `Different_operation` already
form a complete semantic chain. Examine repeated work for redaction, logging,
recording, retries, partial handling, and forwarding to another shell.

Separate cross-cutting host-operation composition from application retry policy.
Decide whether to adopt, defer with a precise condition, or reject a layer
abstraction.

If adopted, specify the API shape, ordering, short-circuit behavior, typed error
and cancellation rules, laws, test controls, ownership, and migration effects.
