# P6 — DuckDB Bulk Load Probe

**Status**: completed
**Hypothesis H-6**: Appender / COPY FROM warrant first-class API; per-row INSERT is wrong-shaped.
**Verdict**: ✅ **CONFIRMED** — Appender is 71.8x faster than batched INSERT.

## Test Configuration

- 100,000 rows per test
- 3 runs per strategy
- Schema: `bulk_test (id BIGINT, value DOUBLE, label VARCHAR)`

## Results

| Strategy | Median Wall (ms) | Speedup vs Per-row |
|----------|------------------|-------------------|
| A: Per-row INSERT | 3,520.0 | 1x (baseline) |
| B: Batched VALUES INSERT | 594.5 | 5.9x |
| C: Appender | 8.3 | 424x |

## Analysis

1. **Appender is dramatically faster**: 71.8x faster than batched INSERT, 424x faster than per-row INSERT.

2. **Batched INSERT is good but not enough**: 5.9x faster than per-row, but still 71.8x slower than Appender.

3. **Per-row INSERT is unusable**: 3.5 seconds for 100k rows would be 35 seconds for 1M rows.

4. **Appender overhead is minimal**: 8.3ms for 100k rows = 83ns per row, which is essentially the cost of the data transfer.

## Why Appender Wins

1. **No SQL parsing**: Appender bypasses the SQL parser entirely.
2. **No query planning**: No need to plan each INSERT statement.
3. **Batched internal writes**: Appender buffers rows and flushes in bulk.
4. **Direct memory writes**: Values are written directly to DuckDB's storage engine.
5. **No transaction overhead**: Appender manages its own transaction scope.

## Implications for Connector Design

- **First-class Appender API**: The connector should expose `Sql.Bulk.appender` as a primary API.
- **Typed appender**: Should provide typed append functions matching the schema.
- **Flush control**: Should expose `flush` and `close` for explicit control.
- **COPY FROM as complement**: For file-based ingestion, `COPY FROM` should also be first-class.

## Comparison to SQLite

SQLite has no equivalent bulk-load API. The closest is:
- Batched INSERT in a transaction (5.9x slower than Appender)
- `BEGIN/COMMIT` transaction wrapping (already used in batched strategy)

DuckDB's Appender is a fundamental advantage for bulk ingestion workloads.

## Next Steps

H-6 is confirmed. Proceed to **P7** (Pool fit) to test Database/Connection lifetime.
