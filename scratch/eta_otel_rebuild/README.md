# Eta-5zo research: eta-otel flagship rebuild

## Decision question

Can eta-otel be rebuilt so the exporter is a real Eta program: Eta owns
batching, retry, lifecycle, timeout, stream processing, and self-observation,
while raw Eio remains only at external I/O leaves?

The ticket text still says Eta.thunk; the shipped API is Eta.Effect.sync. All
research and implementation in this directory uses Effect.sync.

## Proof obligations

| Obligation | Why it matters | Minimum fair evidence | Current result | Status |
| --- | --- | --- | --- | --- |
| O1. Preserve wire shape | This is a structural rebuild, not an OTLP protocol change. | Encoder JSON smoke tests and golden/path checks stay green. | eta-otel tests pass after the rewrite. | Proven. |
| O2. Eta owns exporter lifecycle | The package should teach Eta idioms. | Export loop expressed with Effect.Private.daemon, Effect.acquire_release, Effect.retry, Effect.race, Effect.timeout, Resource.t, Capabilities.clock, and Stream processing. | eta-otel uses one Eta runtime daemon over merged Stream mailbox batches; raw exporter Eio is limited to HTTP/time leaves. | Proven. |
| O3. Capability methods stay cheap | Tracing/logging/metrics calls run on hot paths. | Enqueue path stays bounded and does not run network I/O. | Capability methods mutate local state and call nonblocking Mailbox.offer only. | Proven. |
| O4. Backpressure is explicit | Exporter queues can overflow under partitions. | Adversarial tests for overflow and slow collector. | Queue capacity is configurable; overflow is drop-with-count and covered by tests. | Proven. |
| O5. Self-instrumentation avoids recursion | Exporter must be observable without exporting its own exporter spans recursively. | Test proving exporter self-spans do not re-enter the export sink. | Export daemons use a private in-memory tracer; recursion test passes. | Proven. |
| O6. Benchmark compare is runnable | Acceptance requires at-or-better throughput/latency. | Baseline encoder and post-rewrite encoder measurements plus e2e local-collector submit+flush benchmark. | Encoder repeat is same-range or better; e2e local collector benchmark beats the hand-rolled baseline on span/log/metric loads. | Proven. |

## Hypothesis ledger

| Candidate | Why it is plausible | Evidence needed to win | Falsifier | Current evidence | Status |
| --- | --- | --- | --- | --- | --- |
| A. Keep public API, internal Eta exporter daemon | Preserves existing create, tracer, logger, meter, flush API while moving loops into Eta. | Tests remain green; raw Eio limited to queue adapter and HTTP leaf; benchmarks no worse. | Capability methods cannot enqueue without raw Eio/concurrency primitives, or Eta actor adds visible latency. | Implemented with one Eta runtime daemon over merged typed signal batch streams. | Accepted. |
| B. Add an Eta-native signal queue/stream source | Makes push ingestion and pull stream consumption an Eta-owned primitive. | Small queue API rejects overflow deterministically and powers eta-otel without raw Eio.Stream in exporter. | Public API is too broad for one package or duplicates existing stream internals. | Implemented as Stream.Mailbox plus to_batch_stream. | Accepted, scoped to eta-stream. |
| C. Expose eta-otel as Resource.t / effectful constructor only | Most honest Eta lifecycle: construction, daemons, and shutdown are scoped effects. | Tutorial reads better; tests can migrate; compatibility wrapper remains possible. | Breaks existing simple Otel.create call sites or forces users to run Eta before they can configure Runtime. | Compatibility create API can start internal Eta daemons without forcing app construction through Eta. | Dominated for this package boundary. |
| D. Algebraic-effect dispatch plus PPX elision for transparent cost | Ticket names this as leading transparent-cost candidate. | Microbench shows no-otel calls are cheaper than object-capability branch/allocation path. | Requires wide runtime/PPX design beyond eta-otel rebuild, or cannot preserve explicit Runtime service boundary. | Untested; high consequence. | Deferred until exporter architecture is stable. |
| E. Keep current hand-rolled Eio exporter | It is small, working, and tested. | It would need to meet tutorial/primitive acceptance. | Current raw-Eio surface remains the main behavior. | 20 tests pass, but it fails the flagship signal requirement. | Rejected for Eta-5zo scope. |

## Current baseline commands

export OPAMROOT=/home/ribelo/projects/ribelo/ocaml/Effet-OxCaml/.opam-oxcaml
eval $(opam env --switch=5.2.0+ox --set-switch)
dune runtest packages/eta-otel --force
dune exec scratch/eta_otel_rebuild/baseline_encoder.exe
dune build scratch/eta_otel_rebuild/mailbox_probe.exe
EIO_BACKEND=posix _build/default/scratch/eta_otel_rebuild/mailbox_probe.exe

## Sources

- Eta ticket: .backlog/Eta-5zo.md.
- Current implementation: packages/eta-otel/eta_otel.ml.
- Current public API: packages/eta-otel/eta_otel.mli.
- Current Eta primitives: packages/eta/effect.mli, packages/eta-stream/eta_stream.mli, packages/eta/resource.mli.

## Phase R decision

Proceed with research-first design. Do not rewrite eta_otel.ml until the
architecture answers the producer queue/lifecycle gap; otherwise the rebuild
will either keep raw Eio in disguise or force a public Eta API by accident.

The first compatibility probe succeeded: a normal constructor can start an
internal Eta daemon that consumes an Eta Stream view of a Mailbox while
synchronous submitters push records. That keeps Candidate A viable. The
producer-side queue is now an eta-stream primitive instead of eta-otel owning
raw Eio.Stream directly.

## Implementation verdict

Eta-5zo implemented Candidate A plus the small Candidate B primitive:

- `Stream.Mailbox` is the producer-side bounded stream source.
- `Stream.Mailbox.to_batch_stream` supports online partial batches.
- `eta-otel` no longer owns raw `Eio.Stream`, `Eio.Fiber.fork_daemon`,
  `take_nonblocking`, or manual `while true` exporter loops.
- Signal batches are merged with `Stream.merge` and exported from one
  `Effect.Private.daemon` with bounded `Stream.flat_map_par` concurrency.
- Export attempts use `Effect.sync`, `Effect.race`, `Effect.timeout`,
  `Effect.retry`, `Effect.acquire_release`, `Effect.scoped`,
  `Stream.run_drain`, and `Effect.Private.daemon`.
- Resolved exporter configuration is cached in `Resource.t`; `flush` races
  `Stream.Drain_counter.await_zero` against a timeout branch that uses
  `Capabilities.clock`.
- Exporter self-spans are recorded through a private in-memory tracer and are
  not re-exported.
- The old dependency benchmark fixtures were migrated to explicit dependency
  passing, and the quick bench gate now completes.

Current verification:

```sh
dune runtest packages/eta-stream packages/eta-otel --force
dune runtest packages/eta packages/eta-stream packages/eta-schema packages/eta-otel packages/ppx_eta --force
dune runtest --force
bash bench/compile/run_compile.sh --quick --filter 'compile.fixture.explicit_deps'
bash bench/run.sh --quick
```

The quick bench wrote `bench/results/eta-5zo-quick-current.json`; new
benchmark labels use `explicit_deps`.

The five-sample encoder repeat wrote
`bench/results/eta-otel-encoder-repeat-current.json`; it is better on
span.100, span.1000, and metric.100, with log.100 in the same range as the
one-sample pre-rebuild encoder baseline.

The e2e local-collector benchmark compares the same scratch executable against
the hand-rolled `HEAD` exporter in `/home/ribelo/projects/ribelo/ocaml/Eta-otel-baseline`.
For 1000 signals and five samples, rebuilt submit+flush means were lower on all
signals: span 3.67ms vs 6.66ms, log 1.59ms vs 5.08ms, metric 0.51ms vs 5.03ms.
