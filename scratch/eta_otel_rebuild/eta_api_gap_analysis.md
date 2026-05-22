# Eta API gap analysis for eta-otel

Sources:

- packages/eta/effect.mli
- packages/eta-stream/eta_stream.mli
- packages/eta/resource.mli
- packages/eta-otel/eta_otel.mli
- Current external evidence in external_exporter_analysis.md

## What Eta can express today

| Need | Existing Eta primitive | Fit |
| --- | --- | --- |
| Same-domain I/O leaf | Effect.sync | Good for Eio.Net, Eio.Buf_read, Eio.Time.now. |
| Export timeout | Effect.timeout | Good. |
| Retry export | Effect.retry plus Schedule | Good for retrying typed network/export errors. |
| Runtime-owned export daemon | Effect.Private.daemon | Usable, but private. Ticket explicitly asks to exercise it. |
| Scoped shutdown | Effect.acquire_release, Effect.scoped | Good for resource-like exporter lifecycle. |
| Stream processing | Eta_stream.Stream | Good for pull processing; producer side is the gap. |
| Merge signal streams | Stream.merge | Implemented by merging typed per-signal batch streams before export. |
| Cached config/resource | Resource.t | Implemented for resolved exporter configuration. |
| Self-instrumentation | Effect.named, Effect.annotate, Effect.log, Effect.metric_update | Good if runtime uses non-exporting observer. |
| Legacy blocking I/O | Effect.blocking | Not needed for current Eio TCP leaf; include only if a sync client is added. |
| CPU offload | Effect.island / Effect.Island.map | Only justified if encoding benchmark shows CPU-bound benefit. Baseline encoder cost is small. |

## Gaps

### G1. Producer queue / mailbox

Stream.from_eio_stream can consume an Eio.Stream.t, but eta-otel capability
methods need to push ended spans, logs, and metrics into the exporter. Eta does
not expose a producer-side stream queue or actor mailbox.

Probe:

- scratch/eta_otel_rebuild/mailbox_probe.ml starts an internal Eta daemon from
  a normal constructor and consumes a Stream.from_eio_stream mailbox.
- Command: dune build scratch/eta_otel_rebuild/mailbox_probe.exe && EIO_BACKEND=posix _build/default/scratch/eta_otel_rebuild/mailbox_probe.exe.
- Result: mailbox_probe ok.

Implementation follow-up:

- packages/eta-stream now exposes Mailbox.create, Mailbox.offer, Mailbox.close,
  Mailbox.dropped, Mailbox.to_stream, and Mailbox.to_batch_stream.
- packages/eta-stream also exposes Stream.grouped for finite upstream grouping.
- eta-stream tests cover grouped batches, mailbox close/drop behavior, and
  online partial batches from Mailbox.to_batch_stream.

Interpretation: the compatibility API can survive an internal Eta actor rewrite,
and eta-otel no longer needs to own raw Eio.Stream queues. Raw queue mechanics
remain inside eta-stream as an Eta primitive.

Current choices:

- Add an eta-stream mailbox/source abstraction.

This gap is closed for Eta-5zo. The exporter consumes mailboxes through Eta
streams, and eta-otel itself no longer owns Eio.Stream queues.

### G2. Nonblocking enqueue policy

Current capability methods may block when Eio.Stream capacity is full.
OpenTelemetry Rust evidence says hot-path callbacks should not block. Eta has
no public bounded nonblocking queue with drop/reject/coalesce policy.

Implementation follow-up:

- Mailbox.offer is nonblocking and returns Enqueued, Dropped, or Closed.
- eta-otel increments in-flight only for accepted telemetry and exposes
  Eta_otel.Internal.dropped for overflow tests.
- The eta-otel backpressure overflow test verifies producers do not wait for a
  collector recovery path.

### G3. Runtime-owned daemons from library constructors

Effect.Private.daemon starts background work when interpreted by a Runtime.
Eta_otel.create is currently an ordinary function that receives sw, net, and
clock, not an Eta effect. To use Eta lifecycle fully, eta-otel needs either:

- an internal runtime used only by eta-otel;
- an effectful/scoped constructor;
- a compatibility wrapper around a scoped constructor.

Implementation follow-up:

Eta_otel.create keeps the compatibility constructor, creates an internal Eta
runtime on the caller's switch, builds a cached config Resource.t, and starts
one Effect.Private.daemon that consumes the merged signal stream.

### G4. Transparent no-otel cost

The current Runtime always calls object capabilities, but noop capabilities are
small. The ticket's algebraic-effect plus PPX elision idea is plausible but
wider than eta-otel. It needs its own benchmark fixture before changing Runtime.

### G5. Repo-wide benchmark gate

The benchmark runner had stale dependency-fixture labels after the public Effect
type lost the environment parameter. That was fixed rather than excluded:

- bench/runtime_* Runtime.create calls use only explicit runtime services.
- typecheck fixtures now call Effect.sync with unit callbacks.
- the old dependency-row fixture is renamed to explicit_deps.
- compile benchmark labels now use compile.fixture.explicit_deps.

This gap is closed for current code and current benchmark artifacts.

## Decisions

1. G1 is closed by adding eta-stream Mailbox, Mailbox.to_batch_stream, and
   Stream.grouped.
2. G2 is closed for Eta-5zo by nonblocking Mailbox.offer plus overflow tests.
3. G3 is closed by the compatibility constructor plus internal Eta runtime
   daemon.
4. Stream.merge, Resource.t, Effect.race, and Capabilities.clock are exercised
   in eta-otel itself after the primitive audit.
5. G5 is closed by migrating current benchmark fixtures to explicit_deps and
   restoring the quick bench gate.
6. Defer transparent-cost PPX/algebraic-effect design unless the exporter
   rebuild exposes measurable overhead in no-otel configurations.
