/* P6 DuckDB bulk load probe — C stubs for OCaml FFI.
   Compares per-row INSERT vs batched VALUES vs Appender. */

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
CAMLprim value eta_duckdb_p6_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed to open in-memory database");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- duckdb_connect_db : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_p6_connect(value db_handle)
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
CAMLprim value eta_duckdb_p6_exec_sql(value conn_handle, value sql_val)
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

/* ---- Strategy A: Per-row INSERT ----
   Inserts N rows one at a time in a single transaction.
   Returns (wall_us, rows_inserted). */
CAMLprim value eta_duckdb_p6_per_row_insert(value conn_handle, value count_val)
{
  CAMLparam2(conn_handle, count_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  int count = Int_val(count_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  /* Begin transaction */
  duckdb_result result;
  if (duckdb_query(conn, "BEGIN TRANSACTION", &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("begin", err);
  }
  duckdb_destroy_result(&result);
  
  /* Prepare INSERT statement */
  duckdb_prepared_statement stmt = NULL;
  if (duckdb_prepare(conn, "INSERT INTO bulk_test VALUES (?, ?, ?)", &stmt) == DuckDBError) {
    fail_with_error("prepare", "failed to prepare INSERT");
  }
  
  int rows_inserted = 0;
  for (int i = 0; i < count; i++) {
    /* Bind values */
    duckdb_bind_int64(stmt, 1, i);
    duckdb_bind_double(stmt, 2, (double)i * 1.5);
    char label[32];
    snprintf(label, sizeof(label), "item_%d", i);
    duckdb_bind_varchar(stmt, 3, label);
    
    /* Execute */
    duckdb_result insert_result;
    if (duckdb_execute_prepared(stmt, &insert_result) == DuckDBError) {
      const char *err = duckdb_result_error(&insert_result);
      duckdb_destroy_result(&insert_result);
      duckdb_destroy_prepare(&stmt);
      fail_with_error("insert", err);
    }
    duckdb_destroy_result(&insert_result);
    
    /* Clear bindings for next iteration */
    duckdb_clear_bindings(stmt);
    rows_inserted++;
  }
  
  duckdb_destroy_prepare(&stmt);
  
  /* Commit */
  if (duckdb_query(conn, "COMMIT", &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("commit", err);
  }
  duckdb_destroy_result(&result);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(2, 0);
  Store_field(result_tuple, 0, caml_copy_double(wall_us));
  Store_field(result_tuple, 1, Val_long(rows_inserted));
  
  CAMLreturn(result_tuple);
}

/* ---- Strategy B: Batched VALUES INSERT ----
   Inserts N rows in batches of 1000 using VALUES (...), (...), ...
   Returns (wall_us, rows_inserted). */
CAMLprim value eta_duckdb_p6_batched_insert(value conn_handle, value count_val)
{
  CAMLparam2(conn_handle, count_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  int count = Int_val(count_val);
  int batch_size = 1000;
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  /* Begin transaction */
  duckdb_result result;
  if (duckdb_query(conn, "BEGIN TRANSACTION", &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("begin", err);
  }
  duckdb_destroy_result(&result);
  
  int rows_inserted = 0;
  while (rows_inserted < count) {
    int batch_count = (count - rows_inserted < batch_size) ? (count - rows_inserted) : batch_size;
    
    /* Build VALUES clause */
    char sql[65536];
    int offset = 0;
    offset += snprintf(sql + offset, sizeof(sql) - offset, "INSERT INTO bulk_test VALUES ");
    
    for (int i = 0; i < batch_count; i++) {
      int id = rows_inserted + i;
      if (i > 0) {
        offset += snprintf(sql + offset, sizeof(sql) - offset, ", ");
      }
      offset += snprintf(sql + offset, sizeof(sql) - offset, "(%d, %.1f, 'item_%d')", id, (double)id * 1.5, id);
    }
    
    /* Execute batch */
    if (duckdb_query(conn, sql, &result) == DuckDBError) {
      const char *err = duckdb_result_error(&result);
      duckdb_destroy_result(&result);
      fail_with_error("batch_insert", err);
    }
    duckdb_destroy_result(&result);
    
    rows_inserted += batch_count;
  }
  
  /* Commit */
  if (duckdb_query(conn, "COMMIT", &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("commit", err);
  }
  duckdb_destroy_result(&result);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(2, 0);
  Store_field(result_tuple, 0, caml_copy_double(wall_us));
  Store_field(result_tuple, 1, Val_long(rows_inserted));
  
  CAMLreturn(result_tuple);
}

/* ---- Strategy C: Appender ----
   Uses DuckDB's Appender API for bulk insert.
   Returns (wall_us, rows_inserted). */
CAMLprim value eta_duckdb_p6_appender_insert(value conn_handle, value count_val)
{
  CAMLparam2(conn_handle, count_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  int count = Int_val(count_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  /* Create appender */
  duckdb_appender appender = NULL;
  if (duckdb_appender_create(conn, NULL, "bulk_test", &appender) == DuckDBError) {
    fail_with_error("appender_create", "failed to create appender");
  }
  
  int rows_inserted = 0;
  for (int i = 0; i < count; i++) {
    /* Append values */
    duckdb_append_int64(appender, i);
    duckdb_append_double(appender, (double)i * 1.5);
    char label[32];
    snprintf(label, sizeof(label), "item_%d", i);
    duckdb_append_varchar(appender, label);
    
    /* End row */
    duckdb_appender_end_row(appender);
    rows_inserted++;
  }
  
  /* Flush and close appender */
  duckdb_appender_flush(appender);
  duckdb_appender_close(appender);
  duckdb_appender_destroy(&appender);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(2, 0);
  Store_field(result_tuple, 0, caml_copy_double(wall_us));
  Store_field(result_tuple, 1, Val_long(rows_inserted));
  
  CAMLreturn(result_tuple);
}

/* ---- duckdb_count_rows : nativeint -> int ---- */
CAMLprim value eta_duckdb_p6_count_rows(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_result result;
  if (duckdb_query(conn, "SELECT COUNT(*) FROM bulk_test", &result) == DuckDBError) {
    const char *err = duckdb_result_error(&result);
    duckdb_destroy_result(&result);
    fail_with_error("count", err);
  }
  int64_t count = duckdb_value_int64(&result, 0, 0);
  duckdb_destroy_result(&result);
  CAMLreturn(Val_long(count));
}

/* ---- duckdb_close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p6_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) {
    duckdb_close(&db);
  }
  CAMLreturn(Val_unit);
}

/* ---- duckdb_disconnect_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p6_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_unit);
}

/* ---- get_monotonic_us : unit -> float ---- */
CAMLprim value eta_duckdb_p6_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
