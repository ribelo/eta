# P0 — Turso C API Survey + Link Probe

**Status**: completed
**Turso version**: 3.42.0 (SQLite compatible)
**Link probe**: ✅ `sqlite3_open` → create → insert → query → `sqlite3_close` all succeed

## Dependency Status

- **Source**: `github.com/tursodatabase/turso` (cloned to `/tmp/turso`)
- **Library**: `libturso_sqlite3.so` (64 MB, built with `cargo build --release -p turso_sqlite3`)
- **Header**: `/tmp/turso/sqlite3/include/sqlite3.h`
- **Thread safety**: Same as SQLite — one connection per thread

## Key Findings

### SQLite Compatibility

Turso implements the SQLite3 C API fully. All standard functions work:
- `sqlite3_open`, `sqlite3_close`
- `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_finalize`
- `sqlite3_bind_*`, `sqlite3_column_*`
- `sqlite3_interrupt`
- `sqlite3_errmsg`, `sqlite3_errcode`

### Turso-Specific Features

1. **BEGIN CONCURRENT**: MVCC for concurrent writes (no SQLITE_BUSY)
2. **Vector data type**: Native vector search with `vector_distance_cos()`
3. **Encryption at rest**: Encryption key at database open time
4. **Async I/O**: io_uring support on Linux
5. **CDC**: Change Data Capture for reactive processing
6. **Memory safety**: Implemented in Rust

### Differences from SQLite C API

1. **Missing `sqlite3_column_int`**: Only `sqlite3_column_int64` available
2. **Vector type**: New data type for embeddings
3. **Encryption**: New parameter at open time
4. **Async I/O**: Transparent, no API changes needed

## Implications for Connector Design

- **Drop-in replacement**: Turso can be used as a drop-in replacement for SQLite
- **Same connector shape**: Can reuse the existing SQLite connector pattern
- **Additional features**: BEGIN CONCURRENT, vector search, encryption
- **No new primitives needed**: Existing `Effect.blocking` works

## Next Steps

P0 confirms Turso is reachable and compatible with SQLite C API.
Proceed to **P1** (fairness probe) to verify co-fiber jitter.
