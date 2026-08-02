# Identity and serialized transport equivalence

Type: prototype
Status: open
Blocked by: 06, 10, 13, 16, 17

## Question

Can one Eta Crux application run with an in-process shell or a serialized shell
without changing its semantics or application description?

Run one application through an identity driver and a serialized loopback driver.
Compare:

- inbound message and transition order.
- committed models and typed root outputs.
- staged host-operation requests and resolutions.
- endpoint activation, invocation, and revocation.
- stale and malformed delivery results.
- effect start and cancellation traces.
- synchronous re-entry rejection.
- local-path allocation, remote-handle lookup, and encoding overhead.

Decide whether transport specialization belongs in a driver functor, a runtime
value, or another root-owned seam. The application computation must not depend
on that choice. The local driver must not allocate remote handles or encode
payloads.
