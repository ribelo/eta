# P9 — Final Confirmations

**Status**: completed

## H-9: CDC (Change Data Capture)

**Hypothesis**: CDC can be exposed as a reactive stream via Eta's Channel primitive.
**Verdict**: ⚠️ **DEFERRED** — CDC is experimental, not production-ready.

### Evidence

From Turso documentation:
- CDC is listed as an experimental feature
- No C API for CDC currently exposed
- Implementation details not documented

### Recommendation

Defer CDC integration. The basic connector is sufficient for the anchor workload. CDC can be added later when it becomes production-ready.

## H-10: Vector Search

**Hypothesis**: Vector search works natively with the typed builder.
**Verdict**: ⚠️ **EXTENSION-NEEDED** — Vector queries need builder extensions.

### Evidence

From P5 (builder coverage):
- `vector_distance_cos()` cannot be expressed in current builder
- Need `Expr.vector_distance_cos` extension
- Vector data type can be treated as BLOB/Bytes

### Recommendation

Add `Expr.vector_distance_cos` to the typed builder. This is a clean extension that fits within the existing builder shape.

## H-11: No New Eta Primitives

**Hypothesis**: Implementing the Turso connector requires no new Eta primitives.
**Verdict**: ✅ **CONFIRMED** — Existing primitives are sufficient.

### Evidence

From P1-P8:
1. **P1 (Fairness)**: `Effect.blocking` works correctly with Turso
2. **P2 (Concurrent writes)**: BEGIN CONCURRENT works with MVCC
3. **P3 (Async I/O)**: Transparent to C API
4. **P6 (Encryption)**: Transparent to C API
5. **P7 (Pool fit)**: Same model as SQLite

### Primitives Used

- `Effect.blocking` — for running Turso C API calls in systhread
- `Effect.blocking ?on_cancel` — for cancellation via `sqlite3_interrupt`
- `Eta_pool.create` — for connection pooling
- `Eta_pool.with_resource` — for connection checkout/return

## Summary

| Hypothesis | Verdict | Notes |
|------------|---------|-------|
| H-9: CDC as reactive stream | ⚠️ Deferred | CDC is experimental |
| H-10: Vector search with builder | ⚠️ Extension-needed | Need `Expr.vector_distance_cos` |
| H-11: No new primitives | ✅ Confirmed | Existing Effect.blocking + Eta_pool sufficient |
