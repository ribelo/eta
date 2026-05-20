# Bun + TypeScript + Effect Reference Bench

Mirrors `bench/runtime_overhead/runtime_overhead.ml` so that each
`overhead.ts.X` row maps 1:1 to the OCaml `overhead.X` row. Wall time is
sampled with `Bun.nanoseconds()` from inside the Bun process, after one
untimed warmup pass and a forced `Bun.gc(true)` between samples. Bun
startup is excluded from every measurement.

## What It Measures

| TS row | OCaml counterpart | Notes |
| --- | --- | --- |
| `overhead.ts.direct.loop.100k` | `overhead.direct.loop.100k` | Plain `for` loop. Host-language lower bound. |
| `overhead.ts.direct.closure_bind.100k` | `overhead.direct.closure_bind.100k` | `bind`/`pure` as anonymous functions. |
| `overhead.ts.mini.bind.100k.{prebuilt,build_run}` | `overhead.mini.bind.100k.{prebuilt,build_run}` | Hand-rolled minimal interpreter over `Pure`/`Bind`. |
| `overhead.ts.mini.fail_catch.100k.{prebuilt,build_run}` | `overhead.mini.fail_catch.100k.{prebuilt,build_run}` | Same interpreter with `Fail`/`Catch`. |
| `overhead.ts.effect.runSync_pure.100k` | `overhead.effet.pure.reused_rt` (×100k) | 100k `Effect.runSync(Effect.succeed(0))` calls. Divide by 100k for per-call cost. |
| `overhead.ts.effect.bind.100k.{prebuilt,build_run}` | `overhead.effet.bind.100k.{prebuilt,build_run}` | `Effect.flatMap` chain over `Effect.succeed`. |
| `overhead.ts.effect.fail_catch.100k.{prebuilt,build_run}` | `overhead.effet.fail_catch.100k.{prebuilt,build_run}` | `Effect.catch` over `Effect.fail`. |

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

## Running

The script is invoked automatically by `bench/run.sh` when `bun` is on
`PATH`. Direct invocation:

```sh
bench/runtime_overhead_ts/run.sh
bench/runtime_overhead_ts/run.sh --quick
bench/runtime_overhead_ts/run.sh --quick --filter 'effect.bind'
```

If `bun` is missing, the wrapper prints a notice on stderr and exits 0
so the OCaml-side bench still produces a result file.

## Apples-to-Apples Caveats

- OCaml is AOT-compiled, Bun is JIT-compiled. The first sample on each
  workload is discarded (untimed warmup) so JIT compilation does not
  dominate sample 0.
- `Bun.gc(true)` is called between samples, mirroring `Gc.compact ()`
  in `bench_lib.ml`, but the JSC heap model and the OCaml heap model are
  not directly comparable. Treat per-row deltas as the headline numbers,
  not absolute values across the language boundary.
- The per-op cost of `Effect.runSync_pure` is the 100k-loop wall divided
  by 100k. The OCaml row times one `runSync` call with a pre-created
  runtime; comparing the two requires that division.
- Effect v4 (`effect-smol`) is a beta and its perf may shift between
  releases. The pinned version is recorded in `package.json` and
  reflected in any committed `bench/results/*.json` snapshot.
