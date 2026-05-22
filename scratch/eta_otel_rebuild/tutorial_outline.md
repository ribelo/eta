# Tutorial outline: eta-otel as worked Eta example

Sources:

- Ticket .backlog/Eta-5zo.md.
- Current README packages/eta-otel/README.md.
- Current Eta primitive docs in README.md, packages/eta/effect.mli, packages/eta-stream/eta_stream.mli, and packages/eta/resource.mli.

## Reader goal

After reading the tutorial, a user should be able to explain how Eta describes
I/O, concurrency, retries, streams, resources, observability, and shutdown in a
real library rather than a toy example.

## Proposed structure

1. Exporter boundary
   - Public capability adapters: tracer, logger, meter.
   - Why capability methods enqueue and never perform network I/O.

2. Signal streams
   - Span, log, and metric mailboxes.
   - Turning pushed records into Stream.t.
   - Stream.merge for the real merged export stream.

3. Batching
   - Fixed batch sizes.
   - Bounded queue policy and dropped telemetry accounting.

4. HTTP as an Eta leaf
   - Effect.sync around Eio.Net.with_tcp_connect and Eio.Buf_read.
   - Typed export error.

5. Retry and timeout
   - Effect.retry with Schedule.
   - Effect.race for the POST deadline branch.
   - Effect.timeout as an outer guard around each POST race.

6. Lifecycle
   - Effect.acquire_release for start/flush/stop.
   - Effect.Private.daemon for the background exporter.
   - Capabilities.clock for the flush timeout branch.
   - Graceful shutdown ordering.

7. Self-observation
   - Effect.named and Effect.annotate around exporter work.
   - Separate non-exporting tracer/logger/meter.
   - Recursion guard test.

8. Optional primitives
   - Why Effect.blocking is not used for Eio TCP.
   - Why Effect.island is only used if encoding benchmark proves CPU-bound benefit.
   - How Resource.t caches resolved exporter configuration.

9. Tests and benchmarks
   - Network partition.
   - Slow collector.
   - Malformed response.
   - Backpressure overflow.
   - Graceful shutdown.
   - Encoder and end-to-end throughput comparisons.

## Decision

Design the implementation to match this tutorial order. If a primitive cannot be
used honestly in eta-otel, document why instead of adding a fake use.
