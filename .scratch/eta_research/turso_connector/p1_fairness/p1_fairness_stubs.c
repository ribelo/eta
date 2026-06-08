/* P1 Turso fairness probe — C stubs for OCaml FFI.
   Tests co-fiber wake-jitter during long Turso queries. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <sqlite3.h>
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

/* ---- open_memory : unit -> nativeint ---- */
CAMLprim value eta_turso_p1_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(":memory:", &db);
  if (rc != SQLITE_OK) {
    fail_with_error("sqlite3_open", sqlite3_errmsg(db));
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- exec_sql : nativeint -> string -> unit ---- */
CAMLprim value eta_turso_p1_exec_sql(value db_handle, value sql_val)
{
  CAMLparam2(db_handle, sql_val);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  const char *sql = String_val(sql_val);
  char *err = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "exec_sql: %s", err ? err : "unknown");
    sqlite3_free(err);
    caml_failwith(buffer);
  }
  CAMLreturn(Val_unit);
}

/* ---- run_long_query : nativeint -> string -> (float * float * bool * bool) ----
   Runs a long query in a blocking section.
   Returns (start_us, end_us, completed, interrupted). */
CAMLprim value eta_turso_p1_run_long_query(value db_handle, value sql_val)
{
  CAMLparam2(db_handle, sql_val);
  CAMLlocal1(result_tuple);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  const char *sql = String_val(sql_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  sqlite3_stmt *stmt = NULL;
  int rc;
  int completed = 0;
  int interrupted = 0;
  
  /* Prepare */
  rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    fail_with_error("prepare", sqlite3_errmsg(db));
  }
  
  /* Execute in blocking section */
  caml_enter_blocking_section();
  rc = sqlite3_step(stmt);
  caml_leave_blocking_section();
  
  if (rc == SQLITE_DONE || rc == SQLITE_ROW) {
    completed = 1;
  } else if (rc == SQLITE_INTERRUPT) {
    interrupted = 1;
  }
  
  sqlite3_finalize(stmt);
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double start_us = (double)start_ts.tv_sec * 1000000.0 + (double)start_ts.tv_nsec / 1000.0;
  double end_us = (double)end_ts.tv_sec * 1000000.0 + (double)end_ts.tv_nsec / 1000.0;
  
  result_tuple = caml_alloc(4, 0);
  Store_field(result_tuple, 0, caml_copy_double(start_us));
  Store_field(result_tuple, 1, caml_copy_double(end_us));
  Store_field(result_tuple, 2, Val_bool(completed));
  Store_field(result_tuple, 3, Val_bool(interrupted));
  
  CAMLreturn(result_tuple);
}

/* ---- interrupt : nativeint -> unit ---- */
CAMLprim value eta_turso_p1_interrupt(value db_handle)
{
  CAMLparam1(db_handle);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  sqlite3_interrupt(db);
  CAMLreturn(Val_unit);
}

/* ---- check_select1 : nativeint -> bool ---- */
CAMLprim value eta_turso_p1_check_select1(value db_handle)
{
  CAMLparam1(db_handle);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    CAMLreturn(Val_false);
  }
  rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  CAMLreturn(Val_bool(rc == SQLITE_ROW));
}

/* ---- close_db : nativeint -> unit ---- */
CAMLprim value eta_turso_p1_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  if (db != NULL) {
    sqlite3_close(db);
  }
  CAMLreturn(Val_unit);
}

/* ---- get_monotonic_us : unit -> float ---- */
CAMLprim value eta_turso_p1_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
