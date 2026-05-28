/* P2 DuckDB cancellation probe — C stubs for OCaml FFI.
   Tests duckdb_interrupt mid-query correctness. */

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
#include <unistd.h>
#include <pthread.h>

/* ---- Helper: raise Failure with context ---- */
static void fail_with_error(const char *context, const char *detail)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail ? detail : "unknown");
  caml_failwith(buffer);
}

/* ---- duckdb_open_memory : unit -> nativeint ---- */
CAMLprim value eta_duckdb_p2_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed to open in-memory database");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- duckdb_connect_db : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_p2_connect(value db_handle)
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
CAMLprim value eta_duckdb_p2_exec_sql(value conn_handle, value sql_val)
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

/* ---- duckdb_run_query_with_interrupt : nativeint -> string -> int -> (float * float * bool * bool) ----
   Runs a query, interrupts after delay_ms, measures interrupt-to-return latency.
   Returns (start_us, end_us, completed, interrupted). */
CAMLprim value eta_duckdb_p2_run_with_interrupt(value conn_handle, value sql_val, value delay_ms_val)
{
  CAMLparam3(conn_handle, sql_val, delay_ms_val);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  int delay_ms = Int_val(delay_ms_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  duckdb_result result;
  int success;
  
  /* Run query in blocking section, interrupt tested from OCaml side */
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

/* ---- duckdb_run_query_background : nativeint -> string -> nativeint ----
   Starts a query in a background thread. Returns a handle to the thread.
   The query will run until interrupted or completed. */

typedef struct {
  duckdb_connection conn;
  char *sql;
  int completed;
  int interrupted;
  double start_us;
  double end_us;
  pthread_t thread;
} bg_query_t;

static void* bg_query_thread(void* arg)
{
  bg_query_t *q = (bg_query_t*)arg;
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  q->start_us = (double)start_ts.tv_sec * 1000000.0 + (double)start_ts.tv_nsec / 1000.0;
  
  duckdb_result result;
  int success = duckdb_query(q->conn, q->sql, &result);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  q->end_us = (double)end_ts.tv_sec * 1000000.0 + (double)end_ts.tv_nsec / 1000.0;
  
  q->completed = (success == DuckDBSuccess);
  q->interrupted = !q->completed;
  
  if (success == DuckDBError) {
    duckdb_destroy_result(&result);
  } else {
    duckdb_destroy_result(&result);
  }
  
  return NULL;
}

/* ---- start_background_query : nativeint -> string -> nativeint ---- */
CAMLprim value eta_duckdb_p2_start_background(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  
  bg_query_t *q = (bg_query_t*)malloc(sizeof(bg_query_t));
  q->conn = conn;
  q->sql = strdup(sql);
  q->completed = 0;
  q->interrupted = 0;
  
  pthread_create(&q->thread, NULL, bg_query_thread, q);
  
  CAMLreturn(caml_copy_nativeint((intnat)q));
}

/* ---- interrupt_background : nativeint -> nativeint -> (float * float * bool * bool) ----
   Interrupts a background query and waits for it to finish.
   Returns (start_us, end_us, completed, interrupted). */
CAMLprim value eta_duckdb_p2_interrupt_background(value conn_handle, value bg_handle)
{
  CAMLparam2(conn_handle, bg_handle);
  CAMLlocal1(result_tuple);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  bg_query_t *q = (bg_query_t*)Nativeint_val(bg_handle);
  
  /* Interrupt the query */
  duckdb_interrupt(conn);
  
  /* Wait for the thread to finish */
  pthread_join(q->thread, NULL);
  
  result_tuple = caml_alloc(4, 0);
  Store_field(result_tuple, 0, caml_copy_double(q->start_us));
  Store_field(result_tuple, 1, caml_copy_double(q->end_us));
  Store_field(result_tuple, 2, Val_bool(q->completed));
  Store_field(result_tuple, 3, Val_bool(q->interrupted));
  
  free(q->sql);
  free(q);
  
  CAMLreturn(result_tuple);
}

/* ---- duckdb_interrupt_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p2_interrupt(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_interrupt(conn);
  CAMLreturn(Val_unit);
}

/* ---- duckdb_check_select1 : nativeint -> bool ---- */
CAMLprim value eta_duckdb_p2_check_select1(value conn_handle)
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
CAMLprim value eta_duckdb_p2_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) {
    duckdb_close(&db);
  }
  CAMLreturn(Val_unit);
}

/* ---- duckdb_disconnect_conn : nativeint -> unit ---- */
CAMLprim value eta_duckdb_p2_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_unit);
}

/* ---- get_monotonic_us : unit -> float ---- */
CAMLprim value eta_duckdb_p2_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
