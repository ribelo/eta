# Effet Bench Suite

The bench suite records runtime and compile-time measurements for Effet over
time. It is opt-in infrastructure, not a CI gate.

## What It Measures

| Category | Prefix | Purpose |
| --- | --- | --- |
| Core interpreter | `effect.core.*` | Per-bind, thunk, catch, and typed-failure boundary cost. |
| Overhead controls | `overhead.*` | Paired Effet-vs-minimal-interpreter controls for bind, fail/catch, and setup ratios. |
| Real-use workloads | `realuse.*` | End-to-end programs (fanout, retry, scope, pipeline) that exercise `for_each_par`, `Schedule`/`retry`, `acquire_release`/`scoped`, and bind/catch composition. Each row pays one full Eio runtime setup per sample, matching what a binary entry point pays. |
| Bun + Effect reference | `overhead.ts.*` and `realuse.ts.*` | Same workloads as `overhead.*` and `realuse.*`, run on Bun + Effect v4 (`effect-smol`). Wall time is sampled inside the Bun process so startup is excluded. |
| Concurrency | `effect.concurrency.*` | `par`, `all`, `for_each_par`, `race`, and supervisor costs. |
| Observability | `effect.observability.*` | Tracer, auto-instrumentation, cause construction, trace context, and OTLP adapter cost. |
| Streams | `effet_stream.*` | Representative `effet-stream` pipelines and file reads. |
| Schemas | `effet_schema.*` | Decode, encode, transform, policy, failure, and JSON rendering paths. |
| Package compile time | `compile.<pkg>.*` | Clean and incremental Dune builds for each package. |
| User-code compile time | `compile.fixture.*` | Deep-bind, env-row, schema-heavy, and ppx-heavy workloads. |

## Running

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
nix develop -c bash bench/run.sh --quick --out /tmp/effet-bench.json
```

Runtime-only Dune alias:

```sh
nix develop -c dune build @bench
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
- `machine` with OS, kernel, CPU, OCaml, and Dune versions
- `benchmarks[]` with `name`, `metric`, `unit`, raw `samples`, `mean`,
  `stddev`, `min`, and `max`

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

For the focused "how much does Effet cost?" question, use the overhead ratio
report:

```sh
nix develop -c dune exec bench/overhead.exe -- bench/results/result.json
```

With no file argument, it reads the newest file in `bench/results/`.

## Committing Results

Commit a result when it is useful evidence:

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

## Caveats

- The `overhead.*` controls answer only the core interpreter question. They do
  not yet compare every stream/schema/observability workload against a direct
  hand-written equivalent.
- All OCaml benchmark executables are built with `--profile=release` so
  assertions are stripped and flambda-style optimisations apply when
  available. The `dune build @bench` alias runs in the active profile;
  prefer `bench/run.sh` for performance numbers.
- The `overhead.ts.*` rows require `bun` on `PATH`. If it is missing,
  `bench/run.sh` prints a notice on stderr and produces a result file without
  those rows. The pinned Effect version lives in
  `bench/runtime_overhead_ts/package.json` and the row map is documented in
  `bench/runtime_overhead_ts/README.md`.
- Compile-time benchmarks mutate file timestamps with `touch`; they do not edit
  file contents.
- Runtime concurrent stream workloads can be noisier than pure interpreter
  workloads because they include Eio scheduling.
- The OTLP adapter benchmark uses `Effet_otel.Internal` encoders. It records
  encoding cost, not a live collector round trip.
