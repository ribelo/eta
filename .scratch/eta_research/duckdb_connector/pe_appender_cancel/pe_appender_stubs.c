/* P-E Appender cancellation — C stubs with per-row append for OCaml-side control. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <duckdb.h>
#include <stdio.h>
#include <string.h>

static void fail_with_error(const char *context, const char *detail)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail ? detail : "unknown");
  caml_failwith(buffer);
}

/* ---- open_memory : unit -> nativeint ---- */
CAMLprim value eta_duckdb_pe_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- connect : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_pe_connect(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  duckdb_connection conn = NULL;
  if (duckdb_connect(db, &conn) == DuckDBError) {
    fail_with_error("duckdb_connect", "failed");
  }
  CAMLreturn(caml_copy_nativeint((intnat)conn));
}

/* ---- disconnect : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pe_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) duckdb_disconnect(&conn);
  CAMLreturn(Val_unit);
}

/* ---- close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pe_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) duckdb_close(&db);
  CAMLreturn(Val_unit);
}

/* ---- exec_sql : nativeint -> string -> bool ---- */
CAMLprim value eta_duckdb_pe_exec_sql(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  duckdb_result result;
  int ok = (duckdb_query(conn, sql, &result) == DuckDBSuccess);
  if (ok) duckdb_destroy_result(&result);
  CAMLreturn(Val_bool(ok));
}

/* ---- appender_create : nativeint -> string -> nativeint ---- */
CAMLprim value eta_duckdb_pe_appender_create(value conn_handle, value table_val)
{
  CAMLparam2(conn_handle, table_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *table = String_val(table_val);
  duckdb_appender appender = NULL;
  if (duckdb_appender_create(conn, NULL, table, &appender) == DuckDBError) {
    fail_with_error("appender_create", "failed");
  }
  CAMLreturn(caml_copy_nativeint((intnat)appender));
}

/* ---- appender_append_int : nativeint -> int -> unit ---- */
CAMLprim value eta_duckdb_pe_appender_append_int(value appender_handle, value int_val)
{
  CAMLparam2(appender_handle, int_val);
  duckdb_appender appender = (duckdb_appender)Nativeint_val(appender_handle);
  if (duckdb_append_int32(appender, Int_val(int_val)) == DuckDBError) {
    fail_with_error("append_int", "failed");
  }
  CAMLreturn(Val_unit);
}

/* ---- appender_end_row : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pe_appender_end_row(value appender_handle)
{
  CAMLparam1(appender_handle);
  duckdb_appender appender = (duckdb_appender)Nativeint_val(appender_handle);
  if (duckdb_appender_end_row(appender) == DuckDBError) {
    fail_with_error("end_row", "failed");
  }
  CAMLreturn(Val_unit);
}

/* ---- appender_flush : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pe_appender_flush(value appender_handle)
{
  CAMLparam1(appender_handle);
  duckdb_appender appender = (duckdb_appender)Nativeint_val(appender_handle);
  if (duckdb_appender_flush(appender) == DuckDBError) {
    fail_with_error("flush", "failed");
  }
  CAMLreturn(Val_unit);
}

/* ---- appender_destroy : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pe_appender_destroy(value appender_handle)
{
  CAMLparam1(appender_handle);
  duckdb_appender appender = (duckdb_appender)Nativeint_val(appender_handle);
  if (appender != NULL) duckdb_appender_destroy(&appender);
  CAMLreturn(Val_unit);
}

/* ---- check_connection : nativeint -> bool ---- */
CAMLprim value eta_duckdb_pe_check_connection(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_result result;
  int ok = (duckdb_query(conn, "SELECT 1", &result) == DuckDBSuccess);
  if (ok) duckdb_destroy_result(&result);
  CAMLreturn(Val_bool(ok));
}
