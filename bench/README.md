# Eta Bench Suite

The bench suite records runtime and compile-time measurements for Eta over
time. It is opt-in infrastructure, not a CI gate.

Package-level optimization status is tracked separately in
[.scratch/research/planning/optimization-matrix.md](../.scratch/research/planning/optimization-matrix.md).

## What It Measures

| Category | Prefix | Purpose |
| --- | --- | --- |
| Core interpreter | `effect.core.*` | Per-bind, sync leaf, catch, typed-failure boundary, and interruptibility-fence cost. Both bind shapes are measured: `bind_source_nested` grows the chain on the source side, `bind_continuation_nested` grows it inside the continuation. Each has a `prebuilt` and a `build_run` variant so an interpretation regression is distinguishable from a construction regression. |
| Runtime setup | `eta.setup.*` | The one row that deliberately pays a full `Eio_main.run` + `Runtime.create` per sample, because a binary entry point pays it. Every other row reuses one process-wide runtime. |
| Overhead controls | `overhead.*` | Paired Eta-vs-minimal-interpreter controls for bind, fail/catch, and setup ratios. |
| Real-use workloads | `realuse.*` | End-to-end programs (fanout, retry, scope, pipeline) that exercise `map_par`, `Schedule`/`retry`, `acquire_release`/`scoped`, and bind/catch composition. Each row pays one full Eio runtime setup per sample, matching what a binary entry point pays. |
| Concurrency | `effect.concurrency.*` | `par`, `all`, `map_par`, `race`, and supervisor costs. |
| Observability | `effect.observability.*` | Tracer, auto-instrumentation, cause construction, trace context, and OTLP adapter cost. |
| Blueprint construction | `effect.construction.*` | Allocation and wall time for deep map, bind, and preserve-backed construction chains. |
| Queue | `eta.queue.*` | Unbounded fill/drain and try-offer/poll bookkeeping, plus a capacity-1 bounded rendezvous and a multi-producer bounded row that actually exercise the block-on-full and block-on-empty paths. |
| Pubsub | `eta.pubsub.*` | Publish/receive on an unbounded hub, four-subscriber fanout, the `Drop_new` full-hub decision path, and a capacity-1 backpressure rendezvous. |
| Semaphore | `eta.semaphore.*` | Uncontended acquire/release, and acquisition through a single permit from several fibers. |
| Promise | `eta.promise.*` | Settled-read path, and the park/wake handoff. The `via_par` row includes one `Effect.par` per operation by construction. |
| Channel | `eta.channel.*` | Bounded rendezvous at capacity 1 and capacity 64. |
| Pool | `eta.pool.*` | Warm lease checkout/checkin, and checkout under more borrowers than resources. |
| Mutable_ref | `eta.mutable_ref.*` | `update` and `compare_and_set` through the effect boundary. |
| Cancellation | `eta.cancel.*` | Scope exit with a child parked on `never`, with and without an interrupt finalizer. |
| Streams | `eta_stream.*` | Representative `eta_stream` pipelines and file reads. |
| HTTP/WebSocket | `http.ws.*` | WebSocket codec encode/decode and local loopback echo cost. |
| HTTP server loop | `METRIC h1_*`, `METRIC h2_*` | In-process H1/H2 server loop throughput and allocation without socket/client noise. |
| Schemas | `eta_schema.*` | Decode, encode, transform, policy, failure, and JSON rendering paths. |
| Runtime watchlist | `overhead.eta.*`, `realuse.retry.*` | Focused regression rows for direct-runtime bind, fail/catch, warm pure, and retry cost. |
| Package compile time | `compile.<pkg>.*` | Clean and incremental Dune builds for native package directories tracked by `bench/compile/run_compile.sh`. |
| User-code compile time | `compile.fixture.*` | Deep-bind, explicit-deps, schema-heavy, and ppx-heavy workloads. |

## Methodology

The shared harness in `bench/lib/bench_lib.ml` applies the following to every
row in every package. Ignoring any of it produces numbers that move for reasons
unrelated to the code under test.

- **One warmup invocation per workload is measured and then discarded.** The
  first invocation pays one-time costs a steady-state consumer does not pay per
  operation. Before this was added, the first sample ran up to 10x the
  subsequent ones.
- **Monotonic timing.** `Unix.gettimeofday` returns absolute epoch seconds in a
  double, which quantizes to ~238 ns and is subject to clock steps. The harness
  uses `Mtime_clock` instead.
- **`median` is the number to read.** It is emitted alongside `mean`, `stddev`,
  `min`, `max`, and the raw samples. `bench/compare` uses the median.
- **GC parameters are pinned and the major heap is primed once per process.**
  Major-heap pacing otherwise depends on how much earlier rows allocated: the
  same 100k-node workload measured 2.4x faster in a full run than when selected
  alone with `--filter`. Samples call `Gc.full_major`, not `Gc.compact`;
  compacting per sample was what made the dependence observable.
- **`ops` and the per-operation rows.** Each workload records how many measured
  operations one invocation performs. When that count exceeds 1, the harness
  emits derived `wall_ns_per_op` and `allocated_words_per_op` rows. Prefer them
  over the totals, which include whatever fixed cost the invocation carries.
- **Cheap operations are looped inside the measured region.** A single bind, a
  single sync leaf, or a single catch is far below both the clock resolution and
  the cost of entering a runtime, so a row that measured one of them measured
  nothing.
- **`--quick` is 3 samples, the default is 7.** Never 1: the warmup sample is
  discarded, and one surviving sample carries no dispersion.

## Running

Benchmarks build and run under the `release` profile by default, because that is
the profile that carries `-O3 -unbox-closures` and therefore the profile
consumers ship. Override with `BENCH_PROFILE`. The profile is recorded in the
result file's `machine` block.

Full run:

```sh
nix develop -c bash bench/run.sh
```

Quick run:

```sh
nix develop -c bash bench/run.sh --quick
```

Filter by benchmark name:

```sh
nix develop -c bash bench/run.sh --quick --filter 'effect.core.bind_right'
```

Write to an explicit file:

```sh
nix develop -c bash bench/run.sh --quick --out /tmp/eta-bench.json
```

Runtime-only Dune alias:

```sh
nix develop -c dune build @bench
```

Focused runtime watchlist:

```sh
nix develop -c dune build @watchlist-bench
```

Focused in-process HTTP server loop benchmark:

```sh
nix develop -c dune exec bench/http_server_loop/bench_server_loop.exe -- --quick
```

`dune runtest` does not run benchmarks.

## Output

The default output path is:

```text
bench/results/<UTC timestamp>-<commit sha>.json
```

Each file contains:

- `schema_version`
- `commit`, `commit_time`, `run_time`
- `dirty`
- `machine` with OS, kernel, CPU, OCaml, Dune versions, and the build `profile`
- `benchmarks[]` with `name`, `metric`, `unit`, `ops`, raw `samples`, `mean`,
  `median`, `stddev`, `min`, and `max`

Rows with `ops > 1` are accompanied by derived `wall_ns_per_op` and
`allocated_words_per_op` rows carrying the same `ops` value.

Runtime rows report `allocated_words` as
`minor_words + major_words - promoted_words`, alongside the three raw GC
counters, so promoted allocations are not counted twice.

Cross-machine results are not directly comparable. Use the machine fingerprint
before treating a delta as a regression.

## Comparing

```sh
nix develop -c dune exec bench/compare.exe -- bench/results/old.json bench/results/new.json
```

With no file arguments, it compares the two newest files in `bench/results/`:

```sh
nix develop -c dune exec bench/compare.exe
```

The compare tool prints a per-metric delta table. It has no failure threshold
and does not act as a gate.

It lists rows present on only one side and warns on stderr when the two row sets
differ or when the recorded machine fingerprints - including the build profile -
differ. Neither warning changes its exit code.

For the focused "how much does Eta cost?" question, use the overhead ratio
report:

```sh
nix develop -c dune exec bench/overhead.exe -- bench/results/result.json
```

With no file argument, it reads the newest file in `bench/results/`.

## Committing Results

`bench/results/*.json` is ignored by Git. Move a result into
`.scratch/research/evidence/bench-results/` or a more specific evidence directory
when it is useful evidence:

- before a release or tag
- after a performance-sensitive change
- when investigating a suspected regression

Avoid committing dirty-tree results unless the commit message explains why.

## Bisecting A Regression

1. Pick a metric from `bench/compare`.
2. Start `git bisect` with a known good and bad commit.
3. At each step, run a focused quick bench:

   ```sh
   nix develop -c bash bench/run.sh --quick --filter '<metric prefix>' --out /tmp/bench.json
   ```

4. Compare against the good baseline.
5. Mark the bisect step good or bad based on the metric movement.

A filtered run is comparable to a full run only because the harness pins GC
parameters and primes the heap; measured agreement between a full run and a
single-row filtered run is within ~7%. `bench/compare` still warns that the row
sets differ, which is expected for this workflow.

## Caveats

- Package-owned runtime benchmark sources live under `lib/<pkg>/bench/`. Root
  `bench/` owns shared harness code, cross-package runtime benches, HTTP server
  loop benches, compile-time fixtures, result files, and comparison tools.
- OCaml benchmark executables are built in the active Dune profile. Use the
  same profile for both baseline and candidate runs when comparing results.
- Compile-time benchmarks mutate file timestamps with `touch`; they do not edit
  file contents.
- Runtime concurrent stream workloads can be noisier than pure interpreter
  workloads because they include Eio scheduling.
- The OTLP adapter benchmark uses `Eta_otel.Internal` encoders. It records
  encoding cost, not a live collector round trip.
