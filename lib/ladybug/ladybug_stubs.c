#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { LbugSuccess = 0, LbugError = 1 } lbug_state;
typedef struct { void *ptr; } lbug_database;
typedef struct { void *ptr; } lbug_connection;
typedef struct { void *ptr; bool owned; } lbug_query_result;
typedef struct { void *ptr; bool owned; } lbug_prepared_statement;
typedef struct { void *ptr; bool owned; } lbug_value;
typedef struct { void *ptr; } lbug_system_config;

typedef struct { lbug_database db; } eta_ladybug_db;
typedef struct { lbug_connection conn; } eta_ladybug_conn;

typedef struct {
  void *handle;
  char error[512];
  int attempted;
  int loaded;
  const char *(*get_version)(void);
  char *(*get_last_error)(void);
  void (*destroy_string)(char *);
  lbug_system_config (*default_system_config)(void);
  lbug_state (*database_init)(const char *, lbug_system_config, lbug_database *);
  void (*database_destroy)(lbug_database *);
  lbug_state (*connection_init)(lbug_database *, lbug_connection *);
  void (*connection_destroy)(lbug_connection *);
  lbug_state (*connection_query)(lbug_connection *, const char *, lbug_query_result *);
  void (*connection_interrupt)(lbug_connection *);
  bool (*query_result_is_success)(lbug_query_result *);
  char *(*query_result_get_error_message)(lbug_query_result *);
  char *(*query_result_to_string)(lbug_query_result *);
  void (*query_result_destroy)(lbug_query_result *);
  lbug_state (*connection_prepare)(lbug_connection *, const char *, lbug_prepared_statement *);
  bool (*prepared_statement_is_success)(lbug_prepared_statement *);
  char *(*prepared_statement_get_error_message)(lbug_prepared_statement *);
  void (*prepared_statement_destroy)(lbug_prepared_statement *);
  lbug_state (*prepared_statement_bind_string)(lbug_prepared_statement *, const char *, const char *);
  lbug_state (*prepared_statement_bind_int64)(lbug_prepared_statement *, const char *, int64_t);
  lbug_state (*prepared_statement_bind_double)(lbug_prepared_statement *, const char *, double);
  lbug_state (*prepared_statement_bind_bool)(lbug_prepared_statement *, const char *, bool);
  lbug_value *(*value_create_null)(void);
  void (*value_destroy)(lbug_value *);
  lbug_state (*prepared_statement_bind_value)(lbug_prepared_statement *, const char *, lbug_value *);
  lbug_state (*connection_execute)(lbug_connection *, lbug_prepared_statement *, lbug_query_result *);
} eta_ladybug_api;

static eta_ladybug_api api;

static void db_finalize(value v_db)
{
  eta_ladybug_db *db = (eta_ladybug_db *)Data_custom_val(v_db);
  if (db->db.ptr != NULL && api.loaded) {
    api.database_destroy(&db->db);
    db->db.ptr = NULL;
  }
}

static void conn_finalize(value v_conn)
{
  eta_ladybug_conn *conn = (eta_ladybug_conn *)Data_custom_val(v_conn);
  if (conn->conn.ptr != NULL && api.loaded) {
    api.connection_destroy(&conn->conn);
    conn->conn.ptr = NULL;
  }
}

static struct custom_operations db_ops = {
  "eta.ladybug.database", db_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations conn_ops = {
  "eta.ladybug.connection", conn_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static lbug_database *db_val(value v) { return &((eta_ladybug_db *)Data_custom_val(v))->db; }
static lbug_connection *conn_val(value v) { return &((eta_ladybug_conn *)Data_custom_val(v))->conn; }

static int load_symbol(void **slot, const char *name)
{
  *slot = dlsym(api.handle, name);
  if (*slot == NULL) {
    snprintf(api.error, sizeof(api.error), "missing symbol %s", name);
    return 0;
  }
  return 1;
}

#define LOAD(name) load_symbol((void **)&api.name, "lbug_" #name)

static int load_api(void)
{
  if (api.loaded) return 1;
  if (api.attempted) return 0;
  api.attempted = 1;

  const char *env = getenv("ETA_LADYBUG_LIBRARY");
  const char *candidates[] = { env, "liblbug.so", "libladybug.so", "liblbug.dylib", NULL };
  for (int i = 0; candidates[i] != NULL; i++) {
    if (candidates[i][0] == '\0') continue;
    api.handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
    if (api.handle != NULL) break;
  }
  if (api.handle == NULL) {
    const char *err = dlerror();
    snprintf(api.error, sizeof(api.error), "%s", err == NULL ? "could not load liblbug" : err);
    return 0;
  }

  if (!LOAD(get_version) || !LOAD(get_last_error) || !LOAD(destroy_string) ||
      !LOAD(default_system_config) || !LOAD(database_init) ||
      !LOAD(database_destroy) || !LOAD(connection_init) ||
      !LOAD(connection_destroy) || !LOAD(connection_query) ||
      !LOAD(connection_interrupt) || !LOAD(query_result_is_success) ||
      !LOAD(query_result_get_error_message) || !LOAD(query_result_to_string) ||
      !LOAD(query_result_destroy) || !LOAD(connection_prepare) ||
      !LOAD(prepared_statement_is_success) ||
      !LOAD(prepared_statement_get_error_message) ||
      !LOAD(prepared_statement_destroy) ||
      !LOAD(prepared_statement_bind_string) ||
      !LOAD(prepared_statement_bind_int64) ||
      !LOAD(prepared_statement_bind_double) ||
      !LOAD(prepared_statement_bind_bool) ||
      !LOAD(value_create_null) || !LOAD(value_destroy) ||
      !LOAD(prepared_statement_bind_value) || !LOAD(connection_execute)) {
    return 0;
  }

  api.loaded = 1;
  return 1;
}

static void ensure_loaded(void)
{
  if (!load_api()) caml_failwith(api.error);
}

static value some_string(const char *s)
{
  CAMLparam0();
  CAMLlocal2(some, message);
  message = caml_copy_string(s == NULL ? "" : s);
  some = caml_alloc(1, 0);
  Store_field(some, 0, message);
  CAMLreturn(some);
}

static void fail_last(const char *operation)
{
  char *err = api.get_last_error();
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", operation, err == NULL ? "unknown" : err);
  if (err != NULL) api.destroy_string(err);
  caml_failwith(buffer);
}

CAMLprim value eta_ladybug_available(value unit_value)
{
  CAMLparam1(unit_value);
  if (load_api()) CAMLreturn(Val_none);
  CAMLreturn(some_string(api.error));
}

CAMLprim value eta_ladybug_version(value unit_value)
{
  CAMLparam1(unit_value);
  ensure_loaded();
  CAMLreturn(caml_copy_string(api.get_version()));
}

CAMLprim value eta_ladybug_open(value v_path)
{
  CAMLparam1(v_path);
  CAMLlocal1(v_block);
  ensure_loaded();
  lbug_database db;
  db.ptr = NULL;
  lbug_system_config config = api.default_system_config();
  if (api.database_init(String_val(v_path), config, &db) != LbugSuccess) fail_last("database_init");
  v_block = caml_alloc_custom(&db_ops, sizeof(eta_ladybug_db), 0, 1);
  ((eta_ladybug_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim value eta_ladybug_close_database(value v_db)
{
  CAMLparam1(v_db);
  ensure_loaded();
  eta_ladybug_db *db = (eta_ladybug_db *)Data_custom_val(v_db);
  if (db->db.ptr != NULL) {
    api.database_destroy(&db->db);
    db->db.ptr = NULL;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_ladybug_connect(value v_db)
{
  CAMLparam1(v_db);
  CAMLlocal1(v_block);
  ensure_loaded();
  lbug_connection conn;
  conn.ptr = NULL;
  if (api.connection_init(db_val(v_db), &conn) != LbugSuccess) fail_last("connection_init");
  v_block = caml_alloc_custom(&conn_ops, sizeof(eta_ladybug_conn), 0, 1);
  ((eta_ladybug_conn *)Data_custom_val(v_block))->conn = conn;
  CAMLreturn(v_block);
}

CAMLprim value eta_ladybug_close_connection(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  eta_ladybug_conn *conn = (eta_ladybug_conn *)Data_custom_val(v_conn);
  if (conn->conn.ptr != NULL) {
    api.connection_destroy(&conn->conn);
    conn->conn.ptr = NULL;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_ladybug_interrupt(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  lbug_connection *conn = conn_val(v_conn);
  if (conn->ptr != NULL) api.connection_interrupt(conn);
  CAMLreturn(Val_unit);
}

static void bind_param(lbug_prepared_statement *stmt, value pair)
{
  const char *name = String_val(Field(pair, 0));
  value v = Field(pair, 1);
  lbug_state state = LbugError;
  if (Is_long(v)) {
    lbug_value *null_value = api.value_create_null();
    state = api.prepared_statement_bind_value(stmt, name, null_value);
    if (null_value != NULL) api.value_destroy(null_value);
  } else {
    switch (Tag_val(v)) {
    case 0: state = api.prepared_statement_bind_bool(stmt, name, Bool_val(Field(v, 0))); break;
    case 1: state = api.prepared_statement_bind_int64(stmt, name, Int64_val(Field(v, 0))); break;
    case 2: state = api.prepared_statement_bind_double(stmt, name, Double_val(Field(v, 0))); break;
    case 3: state = api.prepared_statement_bind_string(stmt, name, String_val(Field(v, 0))); break;
    default: caml_failwith("LadybugDB parameter type is not supported by this binding");
    }
  }
  if (state != LbugSuccess) fail_last("bind");
}

static value result_to_string(lbug_query_result *result)
{
  CAMLparam0();
  char *s = api.query_result_to_string(result);
  value out = caml_copy_string(s == NULL ? "" : s);
  if (s != NULL) api.destroy_string(s);
  CAMLreturn(out);
}

static value execute_direct(lbug_connection *conn, const char *cypher)
{
  CAMLparam0();
  CAMLlocal1(out);
  lbug_query_result result;
  result.ptr = NULL;
  result.owned = false;
  lbug_state state;
  caml_enter_blocking_section();
  state = api.connection_query(conn, cypher, &result);
  caml_leave_blocking_section();
  if (state != LbugSuccess) fail_last("connection_query");
  if (!api.query_result_is_success(&result)) {
    char *err = api.query_result_get_error_message(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.query_result_destroy(&result);
    caml_failwith(buffer);
  }
  out = result_to_string(&result);
  api.query_result_destroy(&result);
  CAMLreturn(out);
}

static value execute_prepared(lbug_connection *conn, const char *cypher, value params)
{
  CAMLparam1(params);
  CAMLlocal1(out);
  lbug_prepared_statement stmt;
  lbug_query_result result;
  stmt.ptr = NULL;
  stmt.owned = false;
  result.ptr = NULL;
  result.owned = false;
  if (api.connection_prepare(conn, cypher, &stmt) != LbugSuccess) fail_last("prepare");
  if (!api.prepared_statement_is_success(&stmt)) {
    char *err = api.prepared_statement_get_error_message(&stmt);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "prepare failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.prepared_statement_destroy(&stmt);
    caml_failwith(buffer);
  }
  while (params != Val_emptylist) {
    bind_param(&stmt, Field(params, 0));
    params = Field(params, 1);
  }
  lbug_state state;
  caml_enter_blocking_section();
  state = api.connection_execute(conn, &stmt, &result);
  caml_leave_blocking_section();
  if (state != LbugSuccess) {
    api.prepared_statement_destroy(&stmt);
    fail_last("execute");
  }
  if (!api.query_result_is_success(&result)) {
    char *err = api.query_result_get_error_message(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.query_result_destroy(&result);
    api.prepared_statement_destroy(&stmt);
    caml_failwith(buffer);
  }
  out = result_to_string(&result);
  api.query_result_destroy(&result);
  api.prepared_statement_destroy(&stmt);
  CAMLreturn(out);
}

CAMLprim value eta_ladybug_query_string(value v_conn, value v_cypher, value v_params)
{
  CAMLparam3(v_conn, v_cypher, v_params);
  ensure_loaded();
  lbug_connection *conn = conn_val(v_conn);
  if (v_params == Val_emptylist) CAMLreturn(execute_direct(conn, String_val(v_cypher)));
  CAMLreturn(execute_prepared(conn, String_val(v_cypher), v_params));
}
