# P0 — DuckDB C API Survey + Link Probe

**Status**: completed
**DuckDB version**: v1.5.2
**Link probe**: ✅ `duckdb_open` → create → insert → query → `duckdb_close` all succeed

## Dependency Status

- **Nix package**: `pkgs.duckdb` added to `flake.nix` (version 1.5.2)
- **pkg-config**: NOT available (DuckDB nix package doesn't ship `.pc` files)
- **Header**: `/nix/store/.../duckdb-1.5.2-dev/include/duckdb.h`
- **Shared library**: `/nix/store/.../duckdb-1.5.2-lib/lib/libduckdb.so` (~74 MB)
- **Build workaround**: dune rule uses `find` to locate headers/libs since no pkg-config

## C API Entry Points for Connector

### Lifecycle (Database / Connection separation)
- `duckdb_open(const char *path, duckdb_database *out)` — open/create DB (NULL = in-memory)
- `duckdb_open_ext(const char *path, duckdb_database *out, duckdb_config config, char **err)` — with config
- `duckdb_close(duckdb_database *db)` — close database
- `duckdb_connect(duckdb_database db, duckdb_connection *out)` — create connection
- `duckdb_disconnect(duckdb_connection *conn)` — close connection

**Key insight**: Database is heavy (one per process/file), Connection is cheap (one per fiber/pool-slot).

### Prepare / Bind / Execute
- `duckdb_prepare(duckdb_connection conn, const char *query, duckdb_prepared_statement *out)`
- `duckdb_bind_boolean`, `duckdb_bind_int8/16/32/64`, `duckdb_bind_uint8/16/32/64`
- `duckdb_bind_float`, `duckdb_bind_double`, `duckdb_bind_varchar`, `duckdb_bind_blob`
- `duckdb_bind_null`, `duckdb_bind_hugeint`, `duckdb_bind_decimal`
- `duckdb_execute_prepared(duckdb_prepared_statement stmt, duckdb_result *out)`
- `duckdb_destroy_prepare(duckdb_prepared_statement *stmt)`

**Note**: No `duckdb_bind_uuid` or `duckdb_bind_timestamp` — these require binding as varchar or raw bytes.

### Chunked Results (vectorized iteration)
- `duckdb_fetch_chunk(duckdb_result result)` → `duckdb_data_chunk` (NULL when done)
- `duckdb_data_chunk_get_column_count(chunk)`
- `duckdb_data_chunk_get_size(chunk)` — rows in this chunk
- `duckdb_data_chunk_get_vector(chunk, col_idx)` → `duckdb_vector`
- `duckdb_vector_get_data(vector)` → `void*` (typed array)
- `duckdb_vector_get_validity(vector)` → validity bitmask
- `duckdb_destroy_data_chunk(duckdb_data_chunk *chunk)`

**Key insight**: Chunks are Arrow-like columnar batches. Each vector holds a contiguous array of values for one column. This is the primary iteration API.

### Cancellation
- `duckdb_interrupt(duckdb_connection conn)` — signals running query to stop
- `duckdb_query_progress(duckdb_connection conn)` → `double` (0.0–1.0)

### Errors
- `duckdb_result_error(duckdb_result *result)` → `const char*`
- `duckdb_result_error_type(duckdb_result *result)` → `duckdb_error_type` enum

### Bulk Load (Appender)
- `duckdb_appender_create(duckdb_connection conn, const char *table, duckdb_appender *out)`
- `duckdb_append_bool/int8/16/32/64/uint8/16/32/64/float/double/varchar/blob/null/hugeint/decimal`
- `duckdb_appender_end_row(duckdb_appender appender)`
- `duckdb_appender_flush(duckdb_appender appender)` — flush buffered rows
- `duckdb_appender_close(duckdb_appender appender)` — flush + destroy
- `duckdb_appender_destroy(duckdb_appender *appender)` — destroy without flush

### Type Introspection
- `duckdb_column_count(duckdb_result *result)` — number of columns
- `duckdb_column_type(duckdb_result *result, idx_t col)` → `duckdb_type`
- `duckdb_column_name(duckdb_result *result, idx_t col)` → `const char*`

### DuckDB Type System (`duckdb_type` enum)
- Boolean: `DUCKDB_TYPE_BOOLEAN`
- Integer: `TINYINT`, `SMALLINT`, `INTEGER`, `BIGINT`
- Unsigned: `UTINYINT`, `USMALLINT`, `UINTEGER`, `UBIGINT`
- Float: `FLOAT`, `DOUBLE`
- Decimal: `DECIMAL` (via internal struct with width/scale)
- String: `VARCHAR`
- Binary: `BLOB`
- Temporal: `TIMESTAMP`, `DATE`, `INTERVAL`
- Large int: `HUGEINT` (128-bit)
- UUID: `UUID` (16 bytes)
- JSON: `JSON` (alias for VARCHAR with JSON semantics)
- Composite: `LIST`, `STRUCT`, `MAP`
- Other: `ENUM`, `UNION`, `ARRAY`

**Key insight**: DuckDB's type system is significantly richer than SQLite's (Null/Int/Int64/Float/String/Bool/Bytes).

### Data Chunk API (for Appender / bulk insert)
- `duckdb_create_data_chunk(types[], column_count)` — create empty chunk
- `duckdb_data_chunk_set_size(chunk, size)` — set row count
- `duckdb_vector_assign_string_element(vector, row, str)` — set string value

## Thread Safety Notes

From DuckDB documentation:
1. **Database**: NOT safe to share across OS threads. One database per process.
2. **Connection**: NOT safe to share across OS threads. One connection per thread/fiber.
3. **Multiple connections per database**: YES, this is the intended pattern.
4. **Internal threading**: DuckDB queries use multiple threads by default (`threads=N` where N = host cores).

**Implication for Eta**: Need a connection pool (one connection per blocking-pool slot), same pattern as SQLite. The Database is created once and shared across the pool.

## Differences from SQLite C API

1. **Database/Connection separation**: SQLite has `sqlite3*` (combined); DuckDB separates them.
2. **Chunk iteration**: SQLite is row-at-a-time (`sqlite3_step`); DuckDB is chunk-at-a-time (`duckdb_fetch_chunk`).
3. **Type system**: SQLite is dynamic (types per value); DuckDB is typed per column.
4. **Thread safety**: SQLite allows one connection per thread; DuckDB is stricter (NOT safe to share).
5. **Internal parallelism**: SQLite is single-threaded; DuckDB queries use multiple threads.
6. **Appender**: SQLite has no bulk-load API; DuckDB has first-class Appender.

## Next Steps

P0 confirms DuckDB is reachable and the C API has all required entry points.
The connector shape is clear: Database/Connection separation, chunk iteration, Appender for bulk load.

**Proceeding to P1**: Fairness probe — verify `Effect.blocking ?on_cancel:duckdb_interrupt` doesn't starve co-fibers.
