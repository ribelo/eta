# Host-owned streaming operations

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need a host-owned operation that can resolve many times?

Check the current composition of `Source`, `Host_operation`, `Requester`, and
exported endpoints for process output, file watching, server-sent events,
websockets, and host lifecycle events.

Compare a many-response host operation, a source bound to a host adapter, and the
current application-wired composition. Decide which layer owns desired-set
reconciliation, item admission, completion, failure, cancellation, and stale
emissions.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, semantic laws, backpressure,
test controls, transport behavior, ownership, and migration effects.
