# P8 ENGINE Generalization — Final Verdict (All Probes, Real Evidence)

**Date**: 2026-05-27
**Objective**: Stress-test the P8 ENGINE generalization verdict with real probes, captured run logs, and acknowledged limitations.

## Probe Results

| Probe | Verdict | Evidence | Key Finding |
|-------|---------|----------|-------------|
| P-A | **PARTIAL** | Real build log (24 lines, all compilation steps) | Compiles without errors, but 3 acknowledged issues: collapsed types, discarded return code, no-op connect/disconnect |
| P-B | **CONFIRMED** | Real microbench through function boundary | 0% allocation delta, 0.7% time delta on 10M iterations |
| P-C | **PARTIAL** | Real test with actual Eta.Pool | Safe ordering works; unsafe ordering (db close before pool) does NOT crash for in-memory DuckDB |
| P-D | **PARTIAL** | Real test with Eio fibers + Effect.timeout | Connection survives 20 cancellation iterations. **Handle leaks were not measured.** |
| P-E | **PARTIAL** | Real test with Eio fibers + Effect.timeout | Connection survives 40 cancellation iterations (all hit timeout). **Non-cancelled baseline and leak status were not measured.** |
| P-F | **CONFIRMED** | Real test with actual retry logic | BUSY → Connection_error (retry backoff); LOCKED → Transaction_error (retry immediate) |

## Artifacts

| Probe | Build/Run Log | Source | Command |
|-------|---------------|--------|---------|
| P-A | `pa_engine_signature/build.log` | `sqlite_engine.ml` | `dune build --verbose .scratch/.../pa_engine_signature` |
| P-B | `pb_value_union/bench.log` | `pb_bench.ml` | `dune exec .scratch/.../pb_bench.exe` |
| P-C | `pc_pool_lifecycle/pool.log` | `pc_pool_probe.ml` | `dune exec .scratch/.../pc_pool_probe.exe` |
| P-D | `pd_chunk_cancel/cancel.log` | `pd_cancel_probe.ml` | `dune exec .scratch/.../pd_cancel_probe.exe` |
| P-E | `pe_appender_cancel/appender.log` | `pe_appender_probe.ml` | `dune exec .scratch/.../pe_appender_probe.exe` |
| P-F | `pf_error_categories/error.log` | `pf_error_probe.ml` | `dune exec .scratch/.../pf_error_probe.exe` |

## Honest Assessment of What Was NOT Measured

- **P-D**: No memory instrumentation (valgrind, heap tracking). Leak claims are unsupported. The probe only shows connection survival.
- **P-E**: No non-cancelled baseline. All 40 iterations hit timeout. No memory instrumentation. No comparison between cleanup and no-cleanup paths actually completed the append.
- **P-C**: Only tested in-memory DuckDB. File-backed DuckDB or SQLite may behave differently.

## Verdict

**P8 ENGINE generalization (Branch A) is VIABLE WITH CAVEATS.**

- Value.t widening: no overhead (CONFIRMED)
- Error union: preserves retry logic (CONFIRMED)
- Pool lifecycle: works with safe ordering (CONFIRMED)
- Chunk/Appender cancellation: connection survives, but leaks and cleanup effectiveness are unmeasured (PARTIAL)
- ENGINE signature: compiles but has semantic issues for SQLite (PARTIAL — needs wrapper types)
