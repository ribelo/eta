#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <lbug.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void fail_with_error(const char *context)
{
  char *err = lbug_get_last_error();
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, err ? err : "unknown");
  if (err) {
    lbug_destroy_string(err);
  }
  caml_failwith(buffer);
}

static void check(lbug_state state, const char *context)
{
  if (state != LbugSuccess) {
    fail_with_error(context);
  }
}

static char *copy_string(const char *src)
{
  size_t len = strlen(src);
  char *dst = malloc(len + 1);
  if (dst == NULL) {
    caml_failwith("malloc failed");
  }
  memcpy(dst, src, len + 1);
  return dst;
}

CAMLprim value eta_lbug_p2_open_memory(value unit_value)
{
  CAMLparam1(unit_value);
  lbug_database *db = malloc(sizeof(lbug_database));
  *db = (lbug_database){NULL};
  check(lbug_database_init(":memory:", lbug_default_system_config(), db), "database_init");
  CAMLreturn(caml_copy_nativeint((intnat)db));
}

CAMLprim value eta_lbug_p2_connect(value db_value)
{
  CAMLparam1(db_value);
  lbug_database *db = (lbug_database*)Nativeint_val(db_value);
  lbug_connection *conn = malloc(sizeof(lbug_connection));
  *conn = (lbug_connection){NULL};
  check(lbug_connection_init(db, conn), "connection_init");
  CAMLreturn(caml_copy_nativeint((intnat)conn));
}

CAMLprim value eta_lbug_p2_exec(value conn_value, value sql_value)
{
  CAMLparam2(conn_value, sql_value);
  lbug_connection *conn = (lbug_connection*)Nativeint_val(conn_value);
  lbug_query_result result = {NULL, false};
  check(lbug_connection_query(conn, String_val(sql_value), &result), "exec");
  if (!lbug_query_result_is_success(&result)) {
    char *err = lbug_query_result_get_error_message(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "exec result error: %s", err ? err : "unknown");
    if (err) {
      lbug_destroy_string(err);
    }
    lbug_query_result_destroy(&result);
    caml_failwith(buffer);
  }
  lbug_query_result_destroy(&result);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_lbug_p2_query_blocking(value conn_value, value sql_value)
{
  CAMLparam2(conn_value, sql_value);
  lbug_connection *conn = (lbug_connection*)Nativeint_val(conn_value);
  char *sql = copy_string(String_val(sql_value));
  lbug_query_result result = {NULL, false};
  lbug_state state;

  caml_enter_blocking_section();
  state = lbug_connection_query(conn, sql, &result);
  caml_leave_blocking_section();

  free(sql);

  char buffer[2048];
  if (state != LbugSuccess) {
    char *err = lbug_get_last_error();
    snprintf(buffer, sizeof(buffer), "state_error:%s", err ? err : "unknown");
    if (err) {
      lbug_destroy_string(err);
    }
  } else if (lbug_query_result_is_success(&result)) {
    snprintf(buffer, sizeof(buffer), "success");
  } else {
    char *err = lbug_query_result_get_error_message(&result);
    snprintf(buffer, sizeof(buffer), "error:%s", err ? err : "unknown");
    if (err) {
      lbug_destroy_string(err);
    }
  }
  if (state == LbugSuccess) {
    lbug_query_result_destroy(&result);
  }
  CAMLreturn(caml_copy_string(buffer));
}

CAMLprim value eta_lbug_p2_interrupt(value conn_value)
{
  CAMLparam1(conn_value);
  lbug_connection *conn = (lbug_connection*)Nativeint_val(conn_value);
  lbug_connection_interrupt(conn);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_lbug_p2_check_return1(value conn_value)
{
  CAMLparam1(conn_value);
  lbug_connection *conn = (lbug_connection*)Nativeint_val(conn_value);
  lbug_query_result result = {NULL, false};
  lbug_state state = lbug_connection_query(conn, "RETURN 1", &result);
  int ok = state == LbugSuccess && lbug_query_result_is_success(&result);
  if (state == LbugSuccess) {
    lbug_query_result_destroy(&result);
  }
  CAMLreturn(Val_bool(ok));
}

CAMLprim value eta_lbug_p2_close_conn(value conn_value)
{
  CAMLparam1(conn_value);
  lbug_connection *conn = (lbug_connection*)Nativeint_val(conn_value);
  lbug_connection_destroy(conn);
  free(conn);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_lbug_p2_close_db(value db_value)
{
  CAMLparam1(db_value);
  lbug_database *db = (lbug_database*)Nativeint_val(db_value);
  lbug_database_destroy(db);
  free(db);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_lbug_p2_monotonic_us(value unit_value)
{
  CAMLparam1(unit_value);
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double us = (double)ts.tv_sec * 1000000.0 + (double)ts.tv_nsec / 1000.0;
  CAMLreturn(caml_copy_double(us));
}
