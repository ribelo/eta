# P9 — Final Confirmations

**Status**: completed

## H-9: Arrow C-data Interop

**Hypothesis**: The chunk API is sufficient for v1; Arrow zero-copy interop is deferred.
**Verdict**: ✅ **DEFERRED** — Chunk API is sufficient for anchor workload.

### Evidence

From P3 (chunk iteration):
- Chunk iteration is 5-6x faster than materialization at scale
- Direct vector access (`duckdb_vector_get_data`) provides zero-copy semantics
- No per-row allocation overhead

### Rationale for Deferral

1. **Chunk API is sufficient**: The anchor workload (100k-10M rows, analytical queries) runs efficiently with chunk iteration.
2. **Arrow adds complexity**: `duckdb_query_arrow` / `duckdb_arrow_array_stream` require additional C API bindings and Arrow library dependency.
3. **No stated consumer**: No current consumer demands zero-copy Arrow interop.
4. **Future extension**: If needed, Arrow can be added as a separate research lab without changing the connector shape.

### Recommendation

Defer Arrow C-data interop. The chunk API (`duckdb_fetch_chunk`) is the primary scan API for v1. Arrow can be added later if a consumer requires zero-copy interop with Arrow-based systems.

## H-10: Default Extensions Autoload

**Hypothesis**: Default extensions (parquet, json, httpfs) autoload; no special `LOAD` API.
**Verdict**: ✅ **CONFIRMED** — Extensions autoload in DuckDB 1.x.

### Evidence

From P0 (C API survey):
- DuckDB 1.x autoloads default extensions (parquet, json, httpfs)
- No manual `LOAD` statement needed
- Extensions are compiled into the main library

### Verification

```sql
-- These work without explicit LOAD:
SELECT * FROM read_parquet('test.parquet');
SELECT * FROM read_json('test.json');
SELECT * FROM read_csv('test.csv');
```

### Recommendation

The connector does not need to expose a special `LOAD` API. Default extensions are available automatically.

## H-11: No New Eta Primitives

**Hypothesis**: Implementing the DuckDB connector requires no new Eta primitives.
**Verdict**: ✅ **CONFIRMED** — Existing primitives are sufficient.

### Evidence

From P1-P8:
1. **P1 (Fairness)**: `Effect.blocking ?on_cancel:duckdb_interrupt` works correctly. No new primitive needed.
2. **P2 (Cancellation)**: `duckdb_interrupt` integrates with `Effect.blocking ?on_cancel`. Existing cancellation hook works.
3. **P3 (Chunk iteration)**: Chunk iteration uses existing `Effect.blocking` for C API calls.
4. **P6 (Bulk load)**: Appender uses existing `Effect.blocking` for C API calls.
5. **P7 (Pool fit)**: Database/Connection maps to `?database` parameter on existing `Eta_pool.create`.

### Primitives Used

- `Effect.blocking` — for running DuckDB C API calls in systhread
- `Effect.blocking ?on_cancel` — for cancellation via `duckdb_interrupt`
- `Eta_pool.create ?database` — for connection pooling (parameter addition)
- `Eta_pool.with_resource` — for connection checkout/return

### Recommendation

No new Eta primitives are needed. The existing `Effect.blocking ?on_cancel` and `Eta_pool` primitives are sufficient for the DuckDB connector.

## Summary

| Hypothesis | Verdict | Notes |
|------------|---------|-------|
| H-9: Chunk API sufficient | ✅ Deferred | Chunk API is 5-6x faster; Arrow deferred |
| H-10: Extensions autoload | ✅ Confirmed | parquet, json, httpfs autoload in 1.x |
| H-11: No new primitives | ✅ Confirmed | Existing Effect.blocking + Eta_pool sufficient |

## Next Steps

All hypotheses verified. The lab can now close with a final verdict.
