# H-S4a Cancellation Safety Probe

Question: does Eta.timeout cancel Eio TCP/TLS/read/write operations safely for
eta-http, without leaking descriptors, fibers, or local permits?

Status: PASS-WITH-CAVEAT. The local fixtures pass, but fiber measurement is a
fixture-managed counter rather than a global Eio runtime census.

Required fixtures:

| Fixture | Status |
| --- | --- |
| Saturated local listener TCP connect blackhole | PASS |
| TLS handshake stall | PASS |
| Header read stall | PASS |
| Body read stall | PASS |
| Upload sink stall | PASS |

P0 taxonomy fixture:

- timeout_taxonomy.ml proves the current caller-facing timeout result is
  Cause.Fail Timeout.
- The losing blocked operation is cancelled and its cleanup path runs.
- Descriptor, fiber, and permit counters for real TCP/TLS operations remain for
  the P1 network matrix.

Current taxonomy hypothesis:

- Caller-visible timeout remains a typed failure: Cause.Fail Timeout.
- Cancellation of the losing operation remains runtime interruption:
  Cause.Interrupt when observed from child/supervisor paths.

Network matrix:

- network_timeout_matrix.ml runs the five required local stalls.
- Every row records fd before/after, fixture-managed fiber before/after, permit
  count, and server-side close/drain evidence where applicable.
