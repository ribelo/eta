# C2 Phase 8 Transport Scope

## Decision

Phase 8 transport is online, not batch-only.

## Evidence From The Phase 8 Ticket

Phase 8 covers effet-stream concurrent operators, merge and flat_map_par, and
the OTel exporter. These are live producer/consumer workflows:

- merge cannot wait for all producers to finish before draining without
  changing stream latency and memory behavior.
- flat_map_par needs overlapping inner-stream production and downstream
  consumption.
- OTel export buffering is an online sink, even when it flushes in batches.

## Consequence

The H3 hardening inbox is valid for batch reductions only: one coordinator
producer, push phase, close, then worker drain. Phase 8 must not reuse that
primitive for online cross-domain transport.

Phase 8 must either:

- adopt an existing proven linearizable bounded queue primitive, or
- implement an Effet-owned bounded queue with linearizable push/take/close
  semantics before stream/exporter transport ships.

The H3 inbox remains available for all, for_each_par, all_settled, and other
finite batch fan-out/reassembly paths.
