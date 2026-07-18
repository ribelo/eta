# Bun + TypeScript + Effect Reference Bench

Mirrors `bench/runtime_overhead/runtime_overhead.ml` so that each
`overhead.ts.X` row maps 1:1 to the OCaml `overhead.X` row. Wall time is
sampled with `Bun.nanoseconds()` from inside the Bun process, after a
timed warmup for each workload and a forced `Bun.gc(true)` between measured
samples. Bun startup is excluded from every measurement.

## What It Measures

| TS row | OCaml counterpart | Notes |
| --- | --- | --- |
| `overhead.ts.direct.loop.100k` | `overhead.direct.loop.100k` | Plain `for` loop. Host-language lower bound. |
| `overhead.ts.direct.closure_bind.100k` | `overhead.direct.closure_bind.100k` | `bind`/`pure` as anonymous functions. |
| `overhead.ts.mini.bind.100k.{prebuilt,build_run}` | `overhead.mini.bind.100k.{prebuilt,build_run}` | Hand-rolled minimal interpreter over `Pure`/`Bind`. |
| `overhead.ts.mini.fail_catch.100k.{prebuilt,build_run}` | `overhead.mini.fail_catch.100k.{prebuilt,build_run}` | Same interpreter with `Fail`/`Catch`. |
| `overhead.ts.effect.runSync_pure.100k` | `overhead.eta.pure.reused_rt` (×100k) | 100k `Effect.runSync(Effect.succeed(0))` calls. Divide by 100k for per-call cost. |
| `overhead.ts.effect.bind.100k.{prebuilt,build_run}` | `overhead.eta.bind.100k.{prebuilt,build_run}` | `Effect.flatMap` chain over `Effect.succeed`. |
| `overhead.ts.effect.fail_catch.100k.{prebuilt,build_run}` | `overhead.eta.fail_catch.100k.{prebuilt,build_run}` | `Effect.catch` over `Effect.fail`. |

The TS mini interpreter uses an explicit frame stack, not host recursion,
because JS engines blow the stack around 10k frames; the OCaml mini
interpreter survives recursive evaluation only because OCaml's stack is
much larger. Both are still a "what would you write without a library?"
denominator for their host language.

Only the `wall_ns` metric is emitted on the TS side. Bun does not expose
a stable, finalisation-free heap-diff API equivalent to OCaml's
`Gc.quick_stat`, so `minor_words` / `major_words` are intentionally
omitted rather than zero-filled. `bench/compare.exe` keys on
`name|metric`, so the missing metrics simply don't appear in the diff
table.

## Pinned Effect Version

```text
effect@4.0.0-beta.70   (effect-smol)
```

Pinned in `package.json`. `bun install --frozen-lockfile` is used by
`run.sh` so a stale lockfile fails loudly.

## Real-Use Rows

`realuse.ts.*` rows mirror `bench/runtime_real/runtime_real.ml` 1:1.
Each exercises a slice of the API for which Effect-v4 has a fair
counterpart:

| TS row | OCaml counterpart | Workload |
| --- | --- | --- |
| `realuse.ts.fanout.par.success.64x50` | `realuse.fanout.par.success.64x50` | 64 concurrent tasks, each a 50-step bind chain. `Effect.all([…], { concurrency: "unbounded" })` ↔ `Effect.map_par`. |
| `realuse.ts.fanout.bounded.512x50.k=8` | `realuse.fanout.bounded.512x50.k=8` | 512 tasks bounded to 8 in flight. |
| `realuse.ts.retry.flaky.fail4_then_ok` | `realuse.retry.flaky.fail4_then_ok` | Operation fails 4 times before succeeding; retried with `Schedule.recurs(10)`; loop ×100 to escape the timer floor. |
| `realuse.ts.pipeline.bind_catch.1k` | `realuse.pipeline.bind_catch.1k` | 500 binds → fail-and-catch boundary → 500 binds. |
| `realuse.ts.scope.acquire_release.64` | `realuse.scope.acquire_release.64` | 64 nested `Effect.acquireRelease` inside one `Effect.scoped`. |

All workloads are synchronous (no real I/O, no real timers) so wall
time is dominated by the runtime/interpreter, not by the kernel.

## Running

The script is invoked automatically by `bench/run.sh` when `bun` is on
`PATH`. Direct invocation:

```sh
bench/runtime_overhead_ts/run.sh
bench/runtime_overhead_ts/run.sh --quick
bench/runtime_overhead_ts/run.sh --quick --filter 'effect.bind'
bench/runtime_overhead_ts/run.sh --samples 30 --warmup-ms 5000
```

If `bun` is missing, the wrapper prints a notice on stderr and exits 0
so the OCaml-side bench still produces a result file.

## Apples-to-Apples Caveats

- OCaml is AOT-compiled, Bun is JIT-compiled. Each workload is warmed for
  2 seconds by default before sampling, or 100 ms with `--quick`. Use
  `--warmup-ms` for longer steady-state runs.
- `Bun.gc(true)` is called between samples, mirroring `Gc.compact ()`
  in `bench_lib.ml`, but the JSC heap model and the OCaml heap model are
  not directly comparable. Treat per-row deltas as the headline numbers,
  not absolute values across the language boundary.
- The per-op cost of `Effect.runSync_pure` is the 100k-loop wall divided
  by 100k. The OCaml row times one `runSync` call with a pre-created
  runtime; comparing the two requires that division.
- Effect v4 (`effect-smol`) is a beta and its perf may shift between
  releases. The pinned version is recorded in `package.json` and reflected
  in promoted benchmark evidence snapshots.
