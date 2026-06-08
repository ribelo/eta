# P-E — Appender Cancellation with Real Eio Fibers

**Status**: completed (real test with Effect.timeout)
**Run log**: `scratch/eta_research/duckdb_connector/pe_appender_cancel/appender.log`

## Test Design

Fixed the previous flawed test (synchronous C loop with voluntary `goto`):
- **Before**: Explicit early return from synchronous C loop — not real cancellation
- **After**: Per-row append from OCaml side, `Effect.timeout (Duration.ms 50)`, `Eio_unix.sleep` between batches to let timeout fire

## What Was Measured

The probe ran 20 cancellation iterations per test (40 total, 20 without cleanup + 20 with `Fun.protect`). After each iteration, it checked whether the connection was still usable via `SELECT 1`.

**Result**: All 40 iterations hit the timeout (no iteration completed the full 100k-row append). Connection remained usable after each cancellation.

## What Was NOT Measured

- **Handle leaks were not measured.** There is no instrumentation for C heap usage, no valgrind run, no before/after memory comparison.
- **A non-cancelled baseline was not measured.** The probe does not show whether an un-cancelled Appender session completes and flushes correctly.
- **The `Fun.protect` variant also hit timeout every time**, so the claim that it "prevents leak" is unsupported — both variants were cancelled identically.

## Key Finding

The probe demonstrates **connection survival across 40 cancellation iterations** (all hitting timeout). It does not prove or disprove Appender handle leaks, and does not include a non-cancelled baseline.

## Verdict

**PARTIAL** — Real fiber cancellation was tested. Connection survives. All iterations hit timeout. Non-cancelled baseline and leak status are unknown.

## Artifacts

- Run log: `scratch/eta_research/duckdb_connector/pe_appender_cancel/appender.log`
- Source: `scratch/eta_research/duckdb_connector/pe_appender_cancel/pe_appender_probe.ml`
- Command: `nix develop .#oxcaml --command dune exec scratch/eta_research/duckdb_connector/pe_appender_cancel/pe_appender_probe.exe`
