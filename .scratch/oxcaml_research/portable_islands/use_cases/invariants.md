# Portable island reduced invariant checklist

The first useful island prototype needs only these invariants:

1. Worker input values are portable.
2. Worker callbacks are portable.
3. Worker output values are portable.
4. Result order is input order, not completion order.
5. Typed worker failures are materialized as result values.
6. Worker crashes are materialized at the coordinator as worker_die diagnostics.
7. Islands are finite batch operations only.

Deferred from full H3:

- Portable Supervisor: not required for finite CPU maps.
- Portable Resource refresh: not required for explicit CPU offload.
- Online Stream transport: not required for finite batches.
- OTel exporter transport: coordinator-owned exporters remain the baseline.
- H4 telemetry: no island scheduler policy beyond bounded finite batches.
- Full Runtime.run replacement: existing Runtime.run remains same-domain Eio.

Explicit API stance:

Effect.Island is opt-in. A user can tell domains are used because the call site
names Island. The type signature communicates the boundary through portable
callbacks and portable payloads. Existing Effet code keeps its behavior.
Eio effects cannot accidentally enter workers when the callback is checked as
portable.

Batch-only note:

The H3 close-before-drain inbox is not a live stream/exporter transport. It is
safe for finite batches where all work is submitted before results are drained.
Online producer/consumer paths need a real queue and are outside portable
islands v1.
