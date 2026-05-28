/* P-D chunk cancellation — C stubs with per-chunk fetch for OCaml-side control.
   Allows Effect.timeout to fire between chunk fetches. */

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
CAMLprim value eta_duckdb_pd_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  duckdb_database db = NULL;
  if (duckdb_open(NULL, &db) == DuckDBError) {
    fail_with_error("duckdb_open", "failed");
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

/* ---- connect : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_pd_connect(value db_handle)
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
CAMLprim value eta_duckdb_pd_disconnect(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  if (conn != NULL) duckdb_disconnect(&conn);
  CAMLreturn(Val_unit);
}

/* ---- close_db : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pd_close_db(value db_handle)
{
  CAMLparam1(db_handle);
  duckdb_database db = (duckdb_database)Nativeint_val(db_handle);
  if (db != NULL) duckdb_close(&db);
  CAMLreturn(Val_unit);
}

/* ---- exec_sql : nativeint -> string -> bool ---- */
CAMLprim value eta_duckdb_pd_exec_sql(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  duckdb_result result;
  int ok = (duckdb_query(conn, sql, &result) == DuckDBSuccess);
  if (ok) duckdb_destroy_result(&result);
  CAMLreturn(Val_bool(ok));
}

/* ---- query_start : nativeint -> string -> nativeint ---- */
CAMLprim value eta_duckdb_pd_query_start(value conn_handle, value sql_val)
{
  CAMLparam2(conn_handle, sql_val);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  const char *sql = String_val(sql_val);
  duckdb_result *result = malloc(sizeof(duckdb_result));
  if (result == NULL) fail_with_error("malloc", "out of memory");
  if (duckdb_query(conn, sql, result) == DuckDBError) {
    const char *err = duckdb_result_error(result);
    duckdb_destroy_result(result);
    free(result);
    fail_with_error("query", err);
  }
  CAMLreturn(caml_copy_nativeint((intnat)result));
}

/* ---- fetch_chunk : nativeint -> nativeint ---- */
CAMLprim value eta_duckdb_pd_fetch_chunk(value result_handle)
{
  CAMLparam1(result_handle);
  duckdb_result *result = (duckdb_result*)Nativeint_val(result_handle);
  duckdb_data_chunk chunk = duckdb_fetch_chunk(*result);
  if (chunk == NULL) {
    CAMLreturn(caml_copy_nativeint(0));
  }
  CAMLreturn(caml_copy_nativeint((intnat)chunk));
}

/* ---- chunk_size : nativeint -> int ---- */
CAMLprim value eta_duckdb_pd_chunk_size(value chunk_handle)
{
  CAMLparam1(chunk_handle);
  duckdb_data_chunk chunk = (duckdb_data_chunk)Nativeint_val(chunk_handle);
  if (chunk == NULL) CAMLreturn(Val_int(0));
  CAMLreturn(Val_long(duckdb_data_chunk_get_size(chunk)));
}

/* ---- destroy_chunk : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pd_destroy_chunk(value chunk_handle)
{
  CAMLparam1(chunk_handle);
  duckdb_data_chunk chunk = (duckdb_data_chunk)Nativeint_val(chunk_handle);
  if (chunk != NULL) duckdb_destroy_data_chunk(&chunk);
  CAMLreturn(Val_unit);
}

/* ---- destroy_result : nativeint -> unit ---- */
CAMLprim value eta_duckdb_pd_destroy_result(value result_handle)
{
  CAMLparam1(result_handle);
  duckdb_result *result = (duckdb_result*)Nativeint_val(result_handle);
  if (result != NULL) {
    duckdb_destroy_result(result);
    free(result);
  }
  CAMLreturn(Val_unit);
}

/* ---- check_connection : nativeint -> bool ---- */
CAMLprim value eta_duckdb_pd_check_connection(value conn_handle)
{
  CAMLparam1(conn_handle);
  duckdb_connection conn = (duckdb_connection)Nativeint_val(conn_handle);
  duckdb_result result;
  int ok = (duckdb_query(conn, "SELECT 1", &result) == DuckDBSuccess);
  if (ok) duckdb_destroy_result(&result);
  CAMLreturn(Val_bool(ok));
}
