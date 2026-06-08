# P0 — LadybugDB C API Survey + Link Probe

**Status**: completed
**LadybugDB version**: 0.17.0
**Link probe**: ✅ `lbug_database_init` → create → insert → query → destroy all succeed

## Dependency Status

- **Source**: `github.com/LadybugDB/ladybug` (cloned to `/tmp/ladybug`)
- **Library**: `liblbug.so` (21 MB, built with cmake)
- **Header**: `/tmp/ladybug/src/include/c_api/lbug.h`

## Key Findings

### C API Structure

LadybugDB has a clean C API with:
- `lbug_database_init` / `lbug_database_destroy` — Database lifecycle
- `lbug_connection_init` / `lbug_connection_destroy` — Connection lifecycle
- `lbug_connection_query` — Execute Cypher queries
- `lbug_query_result_get_next` — Iterate results
- `lbug_flat_tuple_get_value` — Extract values from tuples
- `lbug_value_get_*` — Typed value extraction

### Arrow Integration

Built-in Arrow C data interface:
- `lbug_query_result_get_arrow` — Get results as Arrow arrays
- Zero-copy access to query results
- Compatible with Arrow ecosystem

### Type System

Rich type system:
- Scalar: INT8, INT16, INT32, INT64, FLOAT, DOUBLE, STRING, BLOB, BOOL
- Temporal: DATE, TIMESTAMP, TIMESTAMP_NS, TIMESTAMP_MS, TIMESTAMP_SEC, TIMESTAMP_TZ
- Graph: NODE, REL, PATH
- Composite: LIST, MAP, STRUCT
- Special: SERIAL, INTERNAL_ID

### Thread Safety

- One Connection per thread
- Multiple connections per Database
- Same pattern as SQLite/DuckDB

## Implications for Connector Design

- **Database/Connection separation**: Same pattern as DuckDB
- **Arrow integration**: Built-in, can use for zero-copy results
- **Cypher queries**: Different from SQL, need new query builder
- **Rich types**: Need extended Value.t for graph types

## Next Steps

P0 confirms LadybugDB is reachable. Proceed to **P1** (fairness probe).
