# P2 — DuckDB Cancellation Probe

**Status**: completed
**Hypothesis H-2**: `duckdb_interrupt` mid-query returns DUCKDB_INTERRUPTED cleanly and leaves the connection / statement reusable.
**Verdict**: ✅ **CONFIRMED** — interrupt works cleanly, connection survives, statements reusable.

## Test Configuration

- Interrupt delay: 200ms after query start
- Heavy query: CROSS JOIN with range(1,2000) → GROUP BY with AVG/STDDEV/SUM
- 10 interrupt cycles for stability testing
- Interrupt latency measurement: 5 samples

## Results

### Test 1: Basic Interrupt

| Metric | Value |
|--------|-------|
| Query wall time | 200.3ms (interrupted at 200ms) |
| Query completed | false |
| Query interrupted | true |
| Connection reusable | ✅ |

### Test 2: Multiple Interrupt Cycles

| Metric | Value |
|--------|-------|
| Total iterations | 10 |
| All interrupted | ✅ (10/10) |
| All connection_ok | ✅ (10/10) |

### Test 3: Statement Reuse After Interrupt

| Metric | Value |
|--------|-------|
| Simple query after interrupt | ✅ |
| Second interrupt worked | ✅ |
| Connection ok after second | ✅ |

### Test 4: Interrupt Latency

| Metric | Value |
|--------|-------|
| Interrupt latency p50 | 0.187ms |
| Interrupt latency max | 0.205ms |
| Samples | 5 |

## Analysis

1. **Clean interruption**: `duckdb_interrupt` successfully kills mid-query. The query returns with `interrupted=true` rather than completing.

2. **Connection survives**: After interrupt, `SELECT 1` succeeds every time (10/10 cycles).

3. **Statement reuse works**: Can interrupt a query, run a simple query, then interrupt another query on the same connection.

4. **Fast interrupt latency**: Interrupt-to-return is ~0.2ms, well under the 500ms threshold.

5. **No corruption**: No evidence of connection state corruption after interrupt.

## Implications for Connector Design

- **`Effect.blocking ?on_cancel:duckdb_interrupt` is safe**: Can use the same cancellation pattern as SQLite.
- **Connection pooling works**: Interrupted connections can be returned to the pool.
- **Statement preparation works**: Can prepare statements, interrupt mid-execution, and reuse.
- **Timeout semantics work**: Can implement `Effect.timeout` with `duckdb_interrupt` as the cancellation hook.

## Comparison to SQLite

The SQLite cancellation probe (F-Cancel) showed:
- `sqlite3_interrupt` returns in ~5ms
- Connection survives interruption
- Statement reuse works

DuckDB's interrupt is even faster (~0.2ms), likely because DuckDB's internal threading means the interrupt signal is processed more quickly.

## Next Steps

H-2 is confirmed. Proceed to **P3** (chunk vs row iteration) to determine the right scan API shape.
