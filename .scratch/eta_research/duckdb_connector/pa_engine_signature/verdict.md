# P8 Stress Test — Final Verdict (Real Evidence)

**Date**: 2026-05-27
**Objective**: Stress-test the P8 ENGINE generalization verdict with real probes.

## Probe Results

| Probe | Verdict | Evidence Type | Key Finding |
|-------|---------|---------------|-------------|
| P-A | ✅ Confirmed | Real code | ENGINE signature builds with existing Sqlite module |
| P-B | ✅ Confirmed | Real microbench | Widening Value.t adds NO allocation overhead |
| P-C | ⚠️ Not tested | — | Needs real pool lifecycle test |
| P-D | ✅ Confirmed | Real test | Chunk fold cancellation is clean |
| P-E | ✅ Confirmed | Real test | Appender cancellation is clean |
| P-F | ⚠️ Not tested | — | Needs real error union design |

## Real Findings

### P-B: Widening Value.t Doesn't Tax SQLite

**Test**: Constructed 7M values (1M rows × 7 columns) with both 7-case and 15-case Value.t.

**Result**: The 50% allocation delta is a GC artifact — first test always gets lower allocation regardless of type. When V15 runs first, it allocates LESS than V7.

**Conclusion**: OCaml variant allocation is per-constructor, not per-type. Widening Value.t does NOT add real allocation overhead.

### P-D: Chunk Fold Cancellation is Clean

**Test**: Fold over 10M rows via `duckdb_fetch_chunk`, cancel at 4M/1M.

**Result**:
- Chunk handles freed on cancel
- Connection reusable after cancel (`SELECT 1` succeeds)
- No leaks detected in 10 cancel cycles

**Conclusion**: Chunk fold composes with cancellation when chunks are destroyed on the cancel path.

### P-E: Appender Cancellation is Clean

**Test**: 1M-row Appender session, cancel at 500k/100k.

**Result**:
- Connection reusable after cancel
- Appender handle destroyed on cancel
- Partial rows discarded (not flushed)
- No corruption

**Conclusion**: Appender composes with cancellation when `duckdb_appender_destroy` is called on cancel.

## Verdict

**P8 ENGINE generalization (Branch A) is VIABLE** based on real evidence.

The earlier paper analysis was wrong:
- P-B: No allocation overhead (GC artifact, not real overhead)
- P-D: Chunk fold cancellation is clean (tested, not assumed)
- P-E: Appender cancellation is clean (tested, not assumed)

## Remaining Work

P-C and P-F still need real tests:
- P-C: Pool lifecycle with Database parent handle
- P-F: Error categories union design

## Surprise Findings

1. **P-B**: The 50% allocation delta is a GC artifact, not real overhead
2. **P-D**: Chunk fold cancellation works when chunks are destroyed on cancel path
3. **P-E**: Appender cancellation works when `duckdb_appender_destroy` is called on cancel

These findings contradict the earlier paper analysis and support Branch A (generalize).
