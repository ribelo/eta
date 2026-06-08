# concurrent_data_research

Effet-bl1 lab: compare thin Effect-shaped wrappers for common Eio concurrency
data primitives against direct Eio usage.

Files:

- wrappers.ml: minimal candidates for Queue, Deferred, Pubsub, and Latch.
- fixtures.ml: paired wrapper-vs-direct Eio fixtures.
- runtime_smoke.ml: executable assertions and tracing check.

The wrappers deliberately stay close to Eio:

- Queue is an Eio.Stream plus typed close/fail state.
- Deferred is an Eio.Promise carrying an OCaml result.
- Pubsub is per-subscriber Eio.Streams plus a drop-if-full policy.
- Latch is Eio.Condition plus a counter.

The lab question is whether this remains thin enough to justify public Effet API
surface after typed errors, tracing names, and close/fail states are added.
