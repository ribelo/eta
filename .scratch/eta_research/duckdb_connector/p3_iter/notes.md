# P3 — DuckDB Chunk Iteration Probe

**Status**: completed
**Hypothesis H-3**: Chunk-native iteration via `duckdb_fetch_chunk` is the right primary scan shape.
**Verdict**: ✅ **CONFIRMED** — chunk iteration is 5-6x faster than materialization at scale.

## Test Configuration

- 3 runs per strategy per scale
- Scales: 1k, 100k, 1M, 10M rows
- Strategy A: Full materialization (pull all rows, iterate)
- Strategy B: Chunk iteration (`duckdb_fetch_chunk` loop)
- Query: `SELECT id, value FROM test_data;`

## Results

| Rows | A: Materialize (µs) | B: Chunk (µs) | B/A Ratio | Match |
|------|---------------------|---------------|-----------|-------|
| 1,000 | 224 | 211 | 0.94x | ✅ |
| 100,000 | 1,452 | 583 | 0.40x | ✅ |
| 1,000,000 | 14,560 | 2,816 | 0.19x | ✅ |
| 10,000,000 | 138,850 | 24,761 | 0.18x | ✅ |

## Analysis

1. **Chunk iteration wins at all scales**: At 1k rows, it's slightly faster (0.94x). At 10M rows, it's 5.6x faster (0.18x).

2. **Scaling advantage**: The ratio improves with scale because chunk iteration avoids the overhead of materializing the entire result set.

3. **Results match perfectly**: Both strategies produce identical row counts and sums, confirming correctness.

4. **No allocation penalty**: Chunk iteration accesses data directly from the vector buffer (`duckdb_vector_get_data`), avoiding per-row allocation.

## Why Chunk Iteration Wins

1. **Zero-copy access**: `duckdb_vector_get_data` returns a pointer to the column's data array. No per-row allocation.

2. **Cache-friendly**: Processing chunks of contiguous data is cache-efficient.

3. **No materialization overhead**: Materialization copies all data into OCaml values. Chunk iteration reads directly from DuckDB's internal buffers.

4. **Streaming semantics**: Can process data as it arrives without waiting for the entire result.

## Implications for Connector Design

- **Primary API**: Chunk iteration (`duckdb_fetch_chunk`) should be the primary scan API.
- **Fold-based consumption**: The connector should expose a `fold_chunks` function that processes chunks one at a time.
- **Vector access**: The `duckdb_vector_get_data` API allows direct access to typed arrays, avoiding per-row decoding overhead.
- **Batched processing**: Can process multiple rows per chunk without per-row function call overhead.

## Comparison to SQLite

SQLite's iteration is row-at-a-time (`sqlite3_step`), which requires:
1. One function call per row
2. Per-row value extraction
3. Per-row allocation for OCaml values

DuckDB's chunk iteration avoids all three by providing vectorized access to column data.

## Next Steps

H-3 is confirmed. Proceed to **P4** (type coverage inventory) to assess DuckDB's type system.
