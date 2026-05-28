/* P3 DuckDB chunk iteration probe — C stubs for OCaml FFI.
   Compares chunk vs materialized iteration strategies. */

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <duckdb.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* ---- Helper: raise Failure with context ---- */
static void fail_with_error(const char *context, const char *detail)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail ? detail : "unknown");
  caml_failwith(buffer);
}

/* ---- duckdb_open_memory : unit -> nativeint ---- */
CAMLprim value eta_duckdb_p3_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed to open in-memory database");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- duckdb_connect_db : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_p3_connect(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  duckdb_connection conn = NULL;
  if (duckdb_connect(db, &conn) == DuckDBError) {
    fail_with_error("duckdb_connect", "failed to connect");
  }
  CAMLreturn(caml_copy_nativeint((intnat)conn));
}

/* ---- duckdb_exec_sql : nativeint -> string -> unit ---- */
CAMLprim value eta_duckdb_p3_exec_sql(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  duckdb_result result;
  if (duckdb_query(conn, sql, &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("exec_sql", err);
  }
  duckdb_destroy_result(&result);
  CAMLreturn(Val_unit);
}

/* ---- Strategy A: Full materialization ----
   Pulls the entire result into memory, then iterates.
   Returns (wall_us, rows, sum, 0, 0). */
CAMLprim value eta_duckdb_p3_materialize(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  duckdb_result result;
  caml_enter_blocking_section();
  int success = duckdb_query(conn, sql, &result);
  caml_leave_blocking_section();
  
  if (success == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("materialize", err);
  }
  
  /* Iterate through all rows using the deprecated row API for simplicity */
  idx_t row_count = duckdb_row_count(&result);
  int64_t sum = 0;
  idx_t rows_processed = 0;
  
  for (idx_t row = 0; row < row_count; row++) {
    /* Sum the first column (BIGINT) */
    int64_t val = duckdb_value_int64(&result, 0, row);
    sum += val;
    rows_processed++;
  }
  
  duckdb_destroy_result(&result);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(5, 0);
  Store_field(result_tuple, 0, caml_copy_double(wall_us));
  Store_field(result_tuple, 1, Val_long(rows_processed));
  Store_field(result_tuple, 2, Val_long(sum));
  Store_field(result_tuple, 3, Val_long(0));  /* minor_words placeholder */
  Store_field(result_tuple, 4, Val_long(0));  /* major_words placeholder */
  
  CAMLreturn(result_tuple);
}

/* ---- Strategy B: Chunk iteration ----
   Uses duckdb_fetch_chunk to iterate in chunks.
   Returns (wall_us, rows, sum, 0, 0). */
CAMLprim value eta_duckdb_p3_chunk_iter(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  /* Prepare and execute */
  duckdb_prepared_statement stmt = NULL;
  duckdb_result result;
  
  if (duckdb_prepare(conn, sql, &stmt) == DuckDBError) {
    fail_with_error("prepare", "failed to prepare statement");
  }
  
  caml_enter_blocking_section();
  int success = duckdb_execute_prepared(stmt, &result);
  caml_leave_blocking_section();
  
  if (success == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    duckdb_destroy_prepare(&stmt);
    fail_with_error("execute", err);
  }
  
  /* Iterate through chunks */
  int64_t sum = 0;
  idx_t rows_processed = 0;
  duckdb_data_chunk chunk;
  
  while ((chunk = duckdb_fetch_chunk(result)) != NULL) {
    idx_t chunk_size = duckdb_data_chunk_get_size(chunk);
    
    /* Get the first column vector */
    duckdb_vector col = duckdb_data_chunk_get_vector(chunk, 0);
    int64_t *data = (int64_t *)duckdb_vector_get_data(col);
    
    /* Sum values directly from the vector */
    for (idx_t i = 0; i < chunk_size; i++) {
      sum += data[i];
      rows_processed++;
    }
    
    duckdb_destroy_data_chunk(&chunk);
  }
  
  duckdb_destroy_result(&result);
  duckdb_destroy_prepare(&stmt);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(5, 0);
  Store_field(result_tuple, 0, caml_copy_double(wall_us));
  Store_field(result_tuple, 1, Val_long(rows_processed));
  Store_field(result_tuple, 2, Val_long(sum));
  Store_field(result_tuple, 3, Val_long(0));  /* minor_words placeholder */
  Store_field(result_tuple, 4, Val_long(0));  /* major_words placeholder */
  
  CAMLreturn(result_tuple);
}

/* ---- duckdb_close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p3_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) {
    duckdb_close(&db);
  }
  CAMLreturn(Val_unit);
}

/* ---- duckdb_disconnect_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p3_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_unit);
}

/* ---- get_monotonic_us : unit -> float ---- */
CAMLprim value eta_duckdb_p3_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
