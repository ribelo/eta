/* P2 Turso concurrent write probe — C stubs for OCaml FFI.
   Tests BEGIN CONCURRENT for concurrent writes. */

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
CAMLprim value eta_turso_p2_open_memory(value unit_value)
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
CAMLprim value eta_turso_p2_exec_sql(value db_handle, value sql_val)
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

/* ---- concurrent_insert : nativeint -> int -> int -> (int * int * float) ----
   Inserts rows using BEGIN CONCURRENT.
   Returns (rows_inserted, busy_count, wall_us). */
CAMLprim value eta_turso_p2_concurrent_insert(value db_handle, value fiber_id_val, value count_val)
{
  CAMLparam3(db_handle, fiber_id_val, count_val);
  CAMLlocal1(result_tuple);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  int fiber_id = Int_val(fiber_id_val);
  int count = Int_val(count_val);
  
  struct timespec start_ts, end_ts;
  clock_gettime(CLOCK_MONOTONIC, &start_ts);
  
  int rows_inserted = 0;
  int busy_count = 0;
  
  for (int i = 0; i < count; i++) {
    char *err = NULL;
    int rc;
    
    /* Begin concurrent transaction */
    rc = sqlite3_exec(db, "BEGIN CONCURRENT", NULL, NULL, &err);
    if (rc == SQLITE_BUSY) {
      busy_count++;
      if (err) sqlite3_free(err);
      continue;
    } else if (rc != SQLITE_OK) {
      if (err) {
        fprintf(stderr, "BEGIN CONCURRENT failed: %s\n", err);
        sqlite3_free(err);
      }
      break;
    }
    
    /* Insert row */
    char sql[256];
    snprintf(sql, sizeof(sql), 
      "INSERT INTO concurrent_test (fiber_id, row_id, value) VALUES (%d, %d, %f)",
      fiber_id, i, (double)i * 1.5);
    
    rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
      if (err) {
        fprintf(stderr, "INSERT failed: %s\n", err);
        sqlite3_free(err);
      }
      sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
      break;
    }
    
    /* Commit */
    rc = sqlite3_exec(db, "COMMIT", NULL, NULL, &err);
    if (rc == SQLITE_BUSY) {
      busy_count++;
      if (err) sqlite3_free(err);
      sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    } else if (rc != SQLITE_OK) {
      if (err) sqlite3_free(err);
      sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    } else {
      rows_inserted++;
    }
  }
  
  clock_gettime(CLOCK_MONOTONIC, &end_ts);
  double wall_us = (double)(end_ts.tv_sec - start_ts.tv_sec) * 1000000.0 + 
                   (double)(end_ts.tv_nsec - start_ts.tv_nsec) / 1000.0;
  
  result_tuple = caml_alloc(3, 0);
  Store_field(result_tuple, 0, Val_long(rows_inserted));
  Store_field(result_tuple, 1, Val_long(busy_count));
  Store_field(result_tuple, 2, caml_copy_double(wall_us));
  
  CAMLreturn(result_tuple);
}

/* ---- count_rows : nativeint -> int ---- */
CAMLprim value eta_turso_p2_count_rows(value db_handle)
{
  CAMLparam1(db_handle);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM concurrent_test", -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    fail_with_error("prepare", sqlite3_errmsg(db));
  }
  rc = sqlite3_step(stmt);
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    fail_with_error("step", "no row returned");
  }
  int count = (int)sqlite3_column_int64(stmt, 0);
  sqlite3_finalize(stmt);
  CAMLreturn(Val_long(count));
}

/* ---- close_db : nativeint -> unit ---- */
CAMLprim value eta_turso_p2_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  sqlite3 *db = (sqlite3 *)Nativeint_val(db_handle);
  if (db != NULL) {
    sqlite3_close(db);
  }
  CAMLreturn(Val_unit);
}
