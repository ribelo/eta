# P-D — Chunk Fold Cancellation with Real Eio Fibers

**Status**: completed (real test with Effect.timeout)
**Run log**: `scratch/eta_research/duckdb_connector/pd_chunk_cancel/cancel.log`

## Test Design

Fixed the previous flawed test (synchronous C loop with `goto done`):
- **Before**: Voluntary early exit from a synchronous C loop — not real cancellation
- **After**: Per-chunk fetch from OCaml side, `Effect.timeout (Duration.ms 50)`, `Eio_unix.sleep` between chunks to let timeout fire

## What Was Measured

The probe ran 20 cancellation iterations (timeout=50ms). After each iteration, it checked whether the connection was still usable via `SELECT 1`.

**Result**: Connection remained usable across all 20 iterations.

## What Was NOT Measured

- **Handle leaks were not measured.** There is no instrumentation for C heap usage, no valgrind run, no before/after memory comparison. The probe does not demonstrate whether chunk handles leak.
- **A non-cancelled baseline was not measured.** The probe does not compare behaviour of a completed fold versus a cancelled fold.

## Key Finding

The probe demonstrates **connection survival across 20 cancellation iterations**. It does not prove or disprove chunk handle leaks.

## Verdict

**PARTIAL** — Real fiber cancellation was tested. Connection survives. Leak status is unknown.

## Artifacts

- Run log: `scratch/eta_research/duckdb_connector/pd_chunk_cancel/cancel.log`
- Source: `scratch/eta_research/duckdb_connector/pd_chunk_cancel/pd_cancel_probe.ml`
- Command: `nix develop .#oxcaml --command dune exec scratch/eta_research/duckdb_connector/pd_chunk_cancel/pd_cancel_probe.exe`
