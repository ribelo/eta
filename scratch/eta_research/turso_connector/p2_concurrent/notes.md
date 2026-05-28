# P2 — Turso Concurrent Write Probe

**Status**: completed
**Hypothesis H-2**: BEGIN CONCURRENT allows concurrent writes without SQLITE_BUSY.
**Verdict**: ✅ **CONFIRMED** — All 1600 inserts succeeded with 0 busy errors.

## Test Configuration

- 16 fibers, 100 inserts per fiber
- MVCC enabled via `PRAGMA journal_mode = 'mvcc'`
- BEGIN CONCURRENT for each insert transaction

## Results

| Metric | Value |
|--------|-------|
| Expected total | 1,600 |
| Total inserted | 1,600 |
| Total busy errors | 0 |
| Actual row count | 1,600 |

### Per-Fiber Results

- Fiber 0: 100 inserted, 0 busy, 16.0ms
- Fibers 1-15: 100 inserted each, 0 busy, ~0.7ms each

## Analysis

1. **BEGIN CONCURRENT works**: With MVCC enabled, all concurrent writes succeed without SQLITE_BUSY errors.

2. **MVCC is required**: Without `PRAGMA journal_mode = 'mvcc'`, BEGIN CONCURRENT fails with "Concurrent transaction mode is only supported when MVCC is enabled".

3. **Conflict handling**: The documentation says conflicts can occur when two transactions modify the same rows. In our test, each fiber inserts unique rows, so no conflicts.

4. **Performance**: The first fiber (fiber 0) took 16ms (likely due to table creation overhead), while subsequent fibers took ~0.7ms each.

## Key Findings

1. **MVCC must be enabled**: `PRAGMA journal_mode = 'mvcc'` is required before BEGIN CONCURRENT.

2. **Conflict detection**: Turso detects conflicts at commit time and returns SQLITE_BUSY or conflict errors.

3. **Retry logic needed**: Applications must implement retry logic for conflict errors.

4. **Non-overlapping writes succeed**: When fibers write to different rows, all succeed without conflicts.

## Implications for Connector Design

- **Enable MVCC by default**: The connector should enable MVCC when creating databases.
- **BEGIN CONCURRENT as default**: Use BEGIN CONCURRENT instead of BEGIN for write transactions.
- **Retry logic**: Implement automatic retry with backoff for conflict errors.
- **Pool integration**: Connection pool should support concurrent writers.

## Comparison to SQLite

| Feature | SQLite | Turso |
|---------|--------|-------|
| Concurrent writes | ❌ Single writer | ✅ Multiple writers with MVCC |
| BEGIN CONCURRENT | ❌ Not supported | ✅ Supported |
| Conflict detection | N/A | ✅ At commit time |
| Retry logic | N/A | ✅ Required |

## Next Steps

H-2 is confirmed. Proceed to **P3** (async I/O probe).
