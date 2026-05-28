/* P-C pool lifecycle test — C stubs for OCaml FFI.
   Tests whether pool lifecycle with Database parent handle works. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <duckdb.h>
#include <stdio.h>
#include <string.h>

/* ---- Helper ---- */
static void fail_with_error(const char *context, const char *detail)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail ? detail : "unknown");
  caml_failwith(buffer);
}

/* ---- open_memory : unit -> nativeint ---- */
CAMLprim value eta_duckdb_pc_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed to open in-memory database");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- connect : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_pc_connect(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  duckdb_connection conn = NULL;
  if (duckdb_connect(db, &conn) == DuckDBError) {
    fail_with_error("duckdb_connect", "failed to connect");
  }
  CAMLreturn(caml_copy_nativeint((intnat)conn));
}

/* ---- disconnect : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pc_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_unit);
}

/* ---- close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pc_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) {
    duckdb_close(&db);
  }
  CAMLreturn(Val_unit);
}

/* ---- exec_sql : nativeint -> string -> bool ---- */
CAMLprim value eta_duckdb_pc_exec_sql(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  duckdb_result result;
  int ok = (duckdb_query(conn, sql, &result) == DuckDBSuccess);
  if (ok) {
    duckdb_destroy_result(&result);
  }
  CAMLreturn(Val_bool(ok));
}

/* ---- is_db_closed : nativeint -> bool ---- */
CAMLprim value eta_duckdb_pc_is_db_closed(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  /* A closed database handle is NULL */
  CAMLreturn(Val_bool(db == NULL));
}

/* ---- try_connect_to_closed : nativeint -> bool ---- */
CAMLprim value eta_duckdb_pc_try_connect_to_closed(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  duckdb_connection conn = NULL;
  int ok = (duckdb_connect(db, &conn) == DuckDBSuccess);
  if (ok && conn != NULL) {
    duckdb_disconnect(&conn);
  }
  CAMLreturn(Val_bool(ok));
}
