/* P0 DuckDB C API link probe — stubs for OCaml FFI.
   Confirms libduckdb is reachable and functional via direct C stubs. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <duckdb.h>
#include <stdio.h>
#include <string.h>

/* ---- duckdb_library_version : unit -> string ---- */
CAMLprim value eta_duckdb_p0_version(value unit_value)
{
  CAMLparam1(unit_value);
  const char *ver = duckdb_library_version();
  if (ver == NULL) {
    caml_failwith("duckdb_library_version returned NULL");
  }
  CAMLreturn(caml_copy_string(ver));
}

/* ---- Helper: raise Failure with context + duckdb error ---- */
static void fail_with_duckdb_error(duckdb_database db, const char *context)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: DuckDB error", context);
  if (db != NULL) {
    duckdb_close(&db);
  }
  caml_failwith(buffer);
}

static void fail_with_conn_error(duckdb_connection conn, const char *context)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: DuckDB connection error", context);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  caml_failwith(buffer);
}

/* ---- smoke_test : unit -> string ----
   Opens in-memory database, creates a table, inserts a row, queries it back.
   Returns "p0_duckdb_smoke=count:N" on success. */
CAMLprim value eta_duckdb_p0_smoke(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  duckdb_connection conn = NULL;
  duckdb_result result;
  const char *err = NULL;

  /* Open in-memory database */
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_duckdb_error(db, "duckdb_open");
  }

  /* Connect */
  if (duckdb_connect(db, &conn) == DuckDBError) {
    fail_with_conn_error(conn, "duckdb_connect");
  }

  /* Create table and insert */
  if (duckdb_query(conn,
      "CREATE TABLE t (id INTEGER, name VARCHAR NOT NULL);"
      "INSERT INTO t VALUES (1, 'eta');",
      &result) == DuckDBError) {
    err = duckdb_result_error(&result);
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "create/insert: %s", err ? err : "unknown");
    duckdb_destroy_result(&result);
    duckdb_disconnect(&conn);
    duckdb_close(&db);
    caml_failwith(buffer);
  }
  duckdb_destroy_result(&result);

  /* Query count */
  if (duckdb_query(conn, "SELECT COUNT(*) FROM t", &result) == DuckDBError) {
    err = duckdb_result_error(&result);
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "select count: %s", err ? err : "unknown");
    duckdb_destroy_result(&result);
    duckdb_disconnect(&conn);
    duckdb_close(&db);
    caml_failwith(buffer);
  }

  /* Extract the count value */
  int64_t count = 0;
  idx_t row_count = duckdb_row_count(&result);
  idx_t col_count = duckdb_column_count(&result);
  if (row_count > 0 && col_count > 0) {
    /* Use the value extraction API */
    duckdb_value value = duckdb_column_data(&result, 0);
    if (value != NULL) {
      /* For INTEGER type, read from the vector */
      /* Simpler: use the deprecated row API for P0 smoke test */
      count = (int64_t)duckdb_value_int64(&result, 0, 0);
    }
  }
  duckdb_destroy_result(&result);

  /* Cleanup */
  duckdb_disconnect(&conn);
  duckdb_close(&db);

  char buffer[64];
  snprintf(buffer, sizeof(buffer), "p0_duckdb_smoke=count:%lld", (long long)count);
  CAMLreturn(caml_copy_string(buffer));
}

/* ---- api_survey : unit -> string ----
   Returns a multi-line string summarizing key C API capabilities. */
CAMLprim value eta_duckdb_p0_api_survey(value unit_value)
{
  CAMLparam1(unit_value);
  char buf[4096];
  int off = 0;

  off += snprintf(buf + off, sizeof(buf) - off,
    "=== DuckDB C API Survey ===\n"
    "Version: %s\n\n"
    "--- Lifecycle ---\n"
    "  duckdb_open / duckdb_open_ext  (Database)\n"
    "  duckdb_close                   (Database)\n"
    "  duckdb_connect / duckdb_disconnect  (Connection)\n\n"
    "--- Prepare / Bind / Execute ---\n"
    "  duckdb_prepare                 (Connection, sql -> PreparedStatement)\n"
    "  duckdb_bind_* family           (bind values to params)\n"
    "  duckdb_execute_prepared        (PreparedStatement -> Result)\n"
    "  duckdb_destroy_prepare         (PreparedStatement)\n\n"
    "--- Chunked Results ---\n"
    "  duckdb_fetch_chunk             (Result -> DataChunk)\n"
    "  duckdb_data_chunk_get_column_count\n"
    "  duckdb_data_chunk_get_vector   (DataChunk, col_idx -> Vector)\n"
    "  duckdb_vector_get_data         (Vector -> void*)\n"
    "  duckdb_vector_get_validity     (Vector -> validity_t)\n"
    "  duckdb_data_chunk_get_size     (DataChunk -> row_count)\n"
    "  duckdb_destroy_data_chunk      (DataChunk)\n\n"
    "--- Cancellation ---\n"
    "  duckdb_interrupt               (Connection)\n"
    "  duckdb_query_progress           (Connection -> double, 0.0-1.0)\n\n"
    "--- Errors ---\n"
    "  duckdb_result_error            (Result -> const char*)\n"
    "  duckdb_result_error_type        (Result -> duckdb_error_type)\n\n"
    "--- Bulk Load (Appender) ---\n"
    "  duckdb_appender_create         (Connection, table -> Appender)\n"
    "  duckdb_append_* family         (append typed values)\n"
    "  duckdb_appender_end_row        (Appender)\n"
    "  duckdb_appender_flush          (Appender)\n"
    "  duckdb_appender_close           (Appender)\n"
    "  duckdb_appender_destroy         (Appender*)\n\n"
    "--- Type Introspection ---\n"
    "  duckdb_column_count            (Result -> idx_t)\n"
    "  duckdb_column_type             (Result, col -> duckdb_type)\n"
    "  duckdb_column_name             (Result, col -> const char*)\n"
    "  duckdb_column_data             (Result, col -> void*)\n"
    "  duckdb_nullmask_data           (Result, col -> bool*)\n\n"
    "--- DuckDB Types (duckdb_type enum) ---\n"
    "  DUCKDB_TYPE_BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT\n"
    "  UTINYINT, USMALLINT, UINTEGER, UBIGINT\n"
    "  FLOAT, DOUBLE, DECIMAL (via internal struct)\n"
    "  VARCHAR, BLOB, TIMESTAMP, DATE, INTERVAL, HUGEINT\n"
    "  UUID, JSON, ENUM, LIST, STRUCT, MAP\n"
    "  UNION, ARRAY (newer versions)\n\n"
    "--- Thread Safety (from docs) ---\n"
    "  - duckdb_database: single-process, NOT safe to share across threads\n"
    "  - duckdb_connection: NOT safe to share across OS threads\n"
    "  - Multiple connections per database: YES (intended pattern)\n"
    "  - DuckDB internal threading: queries use multiple threads by default\n\n"
    "--- Data Chunk API (vectorized iteration) ---\n"
    "  duckdb_create_data_chunk      (types, column_count -> DataChunk)\n"
    "  duckdb_data_chunk_set_size     (DataChunk, size)\n"
    "  duckdb_data_chunk_get_vector   (DataChunk, col_idx -> Vector)\n"
    "  duckdb_vector_assign_string_element (Vector, row, str)\n"
    "  duckdb_list_vector_get_child   (Vector -> Vector, for LIST type)\n"
    "  duckdb_struct_vector_get_child (Vector, idx -> Vector, for STRUCT)\n",
    duckdb_library_version()
  );

  CAMLreturn(caml_copy_string(buf));
}
