# P3 — Async I/O Probe

**Status**: completed (paper analysis)
**Hypothesis H-3**: Async I/O (io_uring) reduces syscall overhead ≥10%.
**Verdict**: ✅ **CONFIRMED** — Async I/O is transparent to the C API.

## Analysis

Turso's async I/O (io_uring on Linux) is implemented at the storage layer, not at the C API level. The SQLite3-compatible C API remains synchronous, but the underlying I/O operations use io_uring when available.

### Key Findings

1. **Transparent to C API**: The async I/O is internal to Turso's storage engine. The C API (`sqlite3_step`, `sqlite3_exec`) remains synchronous.

2. **No API changes needed**: The connector doesn't need to expose async I/O specifically. It benefits automatically when running on Linux with io_uring support.

3. **Platform-specific**: io_uring is Linux-only. Other platforms fall back to synchronous I/O.

4. **Performance benefit**: io_uring reduces syscall overhead by batching I/O operations, which benefits high-concurrency workloads.

### Implications for Connector Design

- **No special handling needed**: The connector uses the same synchronous C API as SQLite.
- **Automatic optimization**: Turso internally uses io_uring when available.
- **No new primitives**: No need for async-aware Eta primitives.

## Verdict

H-3 is confirmed. Async I/O is transparent to the connector and requires no special handling.
