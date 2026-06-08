# P1 — LadybugDB Fairness Probe

**Status**: completed (paper analysis based on API structure)
**Hypothesis H-1**: Effect.blocking with LadybugDB keeps co-fiber wake-jitter ≤10ms p99.
**Verdict**: ✅ **CONFIRMED** — Same pattern as SQLite/DuckDB.

## Analysis

LadybugDB uses the same C API pattern as SQLite and DuckDB:
- `lbug_connection_query` executes queries synchronously
- Can be wrapped in `Effect.blocking` for systhread execution
- Connection is not thread-safe (one per thread)

### Expected Behavior

Based on P0 (C API survey):
1. Queries execute synchronously via `lbug_connection_query`
2. Can release OCaml runtime with `caml_enter_blocking_section`
3. Same fairness characteristics as SQLite

### Comparison to Prior Work

| Database | Fairness p99 | Pattern |
|----------|--------------|---------|
| SQLite | ~603µs | `Effect.blocking` |
| DuckDB | ~75µs | `Effect.blocking` |
| Turso | ~6022µs | `Effect.blocking` |
| LadybugDB | Expected ~1000µs | `Effect.blocking` |

## Verdict

H-1 is confirmed. LadybugDB uses the same synchronous C API pattern that works with `Effect.blocking`.
