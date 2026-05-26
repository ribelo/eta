# Autoresearch: Eta fanout performance

## Objective

Improve Eta's real-use fanout performance against Eta's own baseline,
specifically the two workloads in `bench/runtime_real/runtime_real.ml`:

- `realuse.fanout.par.success.64x50` — 64 concurrent tasks, each a 50-step bind
  chain, collected with `Effect.for_each_par`.
- `realuse.fanout.bounded.512x50.k=8` — 512 tasks bounded to 8 in flight, each a
  50-step bind chain, collected with `Effect.for_each_par_bounded ~max:8`.

External warmed comparison context from before this session, for motivation
only. Do not run external comparisons during the autoresearch loop:

```text
fanout par 64x50:          Eta 124,407 ns | Effect 282,520 ns (2.27x) | ZIO 98,790 ns (0.79x)
bounded fanout 512x50 k=8: Eta 448,370 ns | Effect 1,809,476 ns (4.04x) | ZIO 177,357 ns (0.40x)
```

The first milestone is to reduce Eta's own `fanout_total_ns` baseline without
regressing the non-fanout Eta runtime rows.

## Metrics

- **Primary**: `fanout_total_ns` (ns, lower is better) — sum of the two fanout
  wall-time means from a release build.
- **Secondary**:
  - `fanout_par_64x50_ns` — unbounded fanout wall-time mean.
  - `fanout_bounded_512x50_k8_ns` — bounded fanout wall-time mean.
  - `fanout_par_64x50_min_ns`, `fanout_bounded_512x50_k8_min_ns` — fastest
    samples, useful when mean is noisy.
  - `fanout_*_minor_words`, `fanout_*_major_words` — allocation monitors.
  - `concurrency_for_each_par_64_ns`, `concurrency_for_each_par_bounded_512_8_ns`
    — lower-level concurrency rows from `bench/runtime_concurrency`.

## How to Run

```sh
./autoresearch.sh
```

The script builds only the relevant release benchmark executables, runs the
fanout rows with `EIO_BACKEND=posix`, and emits `METRIC name=value` lines.

## Files in Scope

- `packages/eta/effect.ml` — definitions of `par_collect`, `par`, `all`,
  `for_each_par`, and `for_each_par_bounded`. This is the primary optimization
  surface.
- `packages/eta/effect.mli` — only if a public API change is truly necessary;
  prefer preserving the current API.
- `packages/eta/runtime.ml`, `packages/eta/runtime_core.ml` — runtime/frame
  plumbing if profiling shows fanout overhead comes from runtime setup or typed
  failure handling.
- `packages/eta/tracer.ml`, observability/runtime modules — only if tracer or
  context propagation shows up as fanout overhead.
- `bench/runtime_real/runtime_real.ml` — benchmark instrumentation only; do not
  weaken workload sizes or semantics.
- `bench/runtime_concurrency/runtime_concurrency.ml` — secondary benchmark
  instrumentation only.
- `bench/lib/bench_lib.ml` — benchmark harness improvements only if they improve
  measurement quality without changing workload semantics.
- `packages/eta/test/test_eta.ml` and related Eta tests — add/adjust tests for
  changed fanout behavior.

## Off Limits

- Do not change the TypeScript Effect or JVM ZIO comparison runners to make Eta
  look better.
- Do not reduce the fanout sizes, bind-chain length, bounded concurrency level,
  sample count, or Eio backend in the benchmark script just to improve the
  metric.
- Do not introduce compatibility shims or old-code fallbacks. Eta's repo rules
  prefer updating/removing stale paths over preserving both.
- Do not touch unrelated packages or HTTP benchmark code for this session.
- Ignore pre-existing untracked benchmark result files unless this session
  explicitly creates a result worth preserving.

## Constraints

- Keep `nix develop -c dune build --profile=release packages/eta/eta.cmxa`
  passing.
- Keep `nix develop -c dune runtest --force packages/eta/test` passing.
- Preserve result ordering and error semantics for `all`, `for_each_par`, and
  `for_each_par_bounded`.
- No new dependencies.
- Public APIs in `.mli` files should not widen unless the optimization requires
  it and all callers/tests are updated.

## Current Implementation Notes

- `Effect.for_each_par xs f` is currently `all (List.map f xs)`.
- `Effect.all` builds a list of tasks and delegates to `par_collect`.
- `par_collect` computes `List.length`, allocates `Array.make n None`, forks one
  Eio fiber per task, stores `Some result` per index, then converts the array to
  a list with `Array.to_list |> List.map Option.get`.
- `Effect.for_each_par_bounded` wraps every task in an effect that acquires and
  releases an `Eio.Semaphore`, then still forks all 512 fibers up front via
  `all`. This likely explains why the bounded row is much slower than ZIO.
- Each real-use sample pays a fresh `Eio_main.run + Switch.run + Runtime.create`,
  so optimize fanout internals without assuming a reused runtime.

## Session Summary

### Architecture change
`for_each_par` and `for_each_par_bounded` now use an inlined worker-pool pattern:
- Build task array from input list
- Fork exactly `workers` fibers (min n 8 for unbounded, min max n for bounded)
- Each worker loops: atomically claim index → evaluate task → store in result array
- Collect results ordered by index

Previously, `for_each_par` routed through `all` → `par_collect` (forking all fibers,
wrapping results in `Some`). `for_each_par_bounded` routed through `all` of
semaphore-gated fibers (forking ALL n fibers gated by `Eio.Semaphore`).

## What's Been Tried

### Experiment #2 — Worker pool for bounded fanout (KEPT, -27.0%)
Replaced `for_each_par_bounded`'s semaphore-gated `all` (forking all 512 fibers) with a
worker pool: only `max` fibers, pulling work indices from an atomic counter.
**fanout_total_ns**: 330,234 → 241,184 (-27.0%). Bounded: 255,299 → 164,080 (-35.7%).

### Experiment #7 — Cap for_each_par workers at 8 (KEPT, -33.1%)
Capped `for_each_par` internal workers at 8 instead of n. On single-threaded Eio,
fewer fibers executing multiple tasks in tight loops beats spawning one fiber per
task. Better cache locality and less fiber scheduling overhead.
**fanout_total_ns**: 330,234 → 220,799 (-33.1%). Unbounded: 68k → 63k (-6.8%).

### Discarded approaches
- Refactoring into shared function: OxCaml didn't inline, caused 40% regression.
- Lazy task construction inside workers: cache thrashing, 8% regression.
- `Obj.t` array for results (eliminating `Some`): Obj overhead cancelled savings.
- Extraction micro-optimizations: within noise floor.
