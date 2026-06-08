/* P1 DuckDB fairness probe — C stubs for OCaml FFI.
   Tests co-fiber wake-jitter during long DuckDB OLAP queries. */

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
CAMLprim value eta_duckdb_p1_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed to open in-memory database");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- duckdb_connect_db : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_p1_connect(value db_handle)
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
CAMLprim value eta_duckdb_p1_exec_sql(value conn_handle, value sql_val)
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

/* ---- duckdb_run_long_query : nativeint -> string -> (float * float * bool * bool) ----
   Runs a long query in a blocking section (releases OCaml runtime).
   Returns (start_us, end_us, completed, interrupted). */
CAMLprim value eta_duckdb_p1_run_long_query(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  duckdb_result result;
  int success;
  
  /* Release OCaml runtime while running the blocking query */
  caml_enter_blocking_section();
  success = duckdb_query(conn, sql, &result);
  caml_leave_blocking_section();
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  
  double start_us = (double)start_ts.tv_sec * 1000000.0 + (double)start_ts.tv_nsec / 1000.0;
  double end_us = (double)end_ts.tv_sec * 1000000.0 + (double)end_ts.tv_nsec / 1000.0;
  int completed = (success == DuckDBSuccess);
  int interrupted = !completed;
  
  if (success == DuckDBError) {
    duckdb_destroy_result(&result);
  } else {
    duckdb_destroy_result(&result);
  }
  
  result_tuple = caml_alloc(4, 0);
  Store_field(result_tuple, 0, caml_copy_double(start_us));
  Store_field(result_tuple, 1, caml_copy_double(end_us));
  Store_field(result_tuple, 2, Val_bool(completed));
  Store_field(result_tuple, 3, Val_bool(interrupted));
  
  CAMLreturn(result_tuple);
}

/* ---- duckdb_interrupt_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p1_interrupt(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_interrupt(conn);
  CAMLreturn(Val_unit);
}

/* ---- duckdb_check_select1 : nativeint -> bool ---- */
CAMLprim value eta_duckdb_p1_check_select1(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_result result;
  if (duckdb_query(conn, "SELECT 1", &result) == DuckDBError) {
    duckdb_destroy_result(&result);
    CAMLreturn(Val_false);
  }
  duckdb_destroy_result(&result);
  CAMLreturn(Val_true);
}

/* ---- duckdb_close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p1_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) {
    duckdb_close(&db);
  }
  CAMLreturn(Val_unit);
}

/* ---- duckdb_disconnect_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p1_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_unit);
}

/* ---- get_monotonic_us : unit -> float ---- */
CAMLprim value eta_duckdb_p1_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
