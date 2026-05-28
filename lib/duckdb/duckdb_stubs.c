#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t idx_t;
typedef void *duckdb_database;
typedef void *duckdb_connection;
typedef void *duckdb_prepared_statement;
typedef void *duckdb_appender;

typedef struct {
  void *data;
  idx_t size;
} duckdb_blob;

typedef struct {
  idx_t deprecated_column_count;
  idx_t deprecated_row_count;
  idx_t deprecated_rows_changed;
  void *deprecated_columns;
  char *deprecated_error_message;
  void *internal_data;
} duckdb_result;

typedef struct { duckdb_database db; } eta_duckdb_db;
typedef struct { duckdb_connection conn; } eta_duckdb_conn;
typedef struct { duckdb_appender appender; } eta_duckdb_appender;

typedef struct {
  void *handle;
  char error[512];
  int attempted;
  int loaded;
  const char *(*library_version)(void);
  int (*open)(const char *, duckdb_database *);
  void (*close)(duckdb_database *);
  int (*connect)(duckdb_database, duckdb_connection *);
  void (*disconnect)(duckdb_connection *);
  int (*query)(duckdb_connection, const char *, duckdb_result *);
  void (*destroy_result)(duckdb_result *);
  const char *(*result_error)(duckdb_result *);
  idx_t (*column_count)(duckdb_result *);
  idx_t (*row_count)(duckdb_result *);
  const char *(*column_name)(duckdb_result *, idx_t);
  int (*column_type)(duckdb_result *, idx_t);
  int (*value_is_null)(duckdb_result *, idx_t, idx_t);
  int (*value_boolean)(duckdb_result *, idx_t, idx_t);
  int64_t (*value_int64)(duckdb_result *, idx_t, idx_t);
  double (*value_double)(duckdb_result *, idx_t, idx_t);
  char *(*value_varchar)(duckdb_result *, idx_t, idx_t);
  duckdb_blob (*value_blob)(duckdb_result *, idx_t, idx_t);
  void (*free_ptr)(void *);
  int (*prepare)(duckdb_connection, const char *, duckdb_prepared_statement *);
  const char *(*prepare_error)(duckdb_prepared_statement);
  void (*destroy_prepare)(duckdb_prepared_statement *);
  int (*bind_null)(duckdb_prepared_statement, idx_t);
  int (*bind_boolean)(duckdb_prepared_statement, idx_t, int);
  int (*bind_int64)(duckdb_prepared_statement, idx_t, int64_t);
  int (*bind_double)(duckdb_prepared_statement, idx_t, double);
  int (*bind_varchar)(duckdb_prepared_statement, idx_t, const char *);
  int (*bind_blob)(duckdb_prepared_statement, idx_t, const void *, idx_t);
  int (*execute_prepared)(duckdb_prepared_statement, duckdb_result *);
  int (*appender_create)(duckdb_connection, const char *, const char *, duckdb_appender *);
  int (*appender_flush)(duckdb_appender);
  int (*appender_close)(duckdb_appender);
  int (*appender_destroy)(duckdb_appender *);
  int (*append_bool)(duckdb_appender, int);
  int (*append_int64)(duckdb_appender, int64_t);
  int (*append_double)(duckdb_appender, double);
  int (*append_varchar)(duckdb_appender, const char *);
  int (*append_blob)(duckdb_appender, const void *, idx_t);
  int (*append_null)(duckdb_appender);
  int (*appender_end_row)(duckdb_appender);
  void (*interrupt)(duckdb_connection);
} eta_duckdb_api;

static eta_duckdb_api api;

static void db_finalize(value v_db)
{
  eta_duckdb_db *db = (eta_duckdb_db *)Data_custom_val(v_db);
  if (db->db != NULL && api.loaded) {
    api.close(&db->db);
    db->db = NULL;
  }
}

static void conn_finalize(value v_conn)
{
  eta_duckdb_conn *conn = (eta_duckdb_conn *)Data_custom_val(v_conn);
  if (conn->conn != NULL && api.loaded) {
    api.disconnect(&conn->conn);
    conn->conn = NULL;
  }
}

static void appender_finalize(value v_appender)
{
  eta_duckdb_appender *appender = (eta_duckdb_appender *)Data_custom_val(v_appender);
  if (appender->appender != NULL && api.loaded) {
    (void)api.appender_destroy(&appender->appender);
    appender->appender = NULL;
  }
}

static struct custom_operations db_ops = {
  "eta.duckdb.database", db_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations conn_ops = {
  "eta.duckdb.connection", conn_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations appender_ops = {
  "eta.duckdb.appender", appender_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static duckdb_database db_val(value v) { return ((eta_duckdb_db *)Data_custom_val(v))->db; }
static duckdb_connection conn_val(value v) { return ((eta_duckdb_conn *)Data_custom_val(v))->conn; }
static duckdb_appender appender_val(value v) { return ((eta_duckdb_appender *)Data_custom_val(v))->appender; }

static int load_symbol(void **slot, const char *name)
{
  *slot = dlsym(api.handle, name);
  if (*slot == NULL) {
    snprintf(api.error, sizeof(api.error), "missing symbol %s", name);
    return 0;
  }
  return 1;
}

#define LOAD(name) load_symbol((void **)&api.name, "duckdb_" #name)
#define LOAD_AS(field, symbol) load_symbol((void **)&api.field, symbol)

static int load_api(void)
{
  if (api.loaded) return 1;
  if (api.attempted) return 0;
  api.attempted = 1;

  const char *env = getenv("ETA_DUCKDB_LIBRARY");
  const char *candidates[] = { env, "libduckdb.so", "libduckdb.so.1", "libduckdb.dylib", NULL };
  for (int i = 0; candidates[i] != NULL; i++) {
    if (candidates[i][0] == '\0') continue;
    api.handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
    if (api.handle != NULL) break;
  }
  if (api.handle == NULL) {
    const char *err = dlerror();
    snprintf(api.error, sizeof(api.error), "%s", err == NULL ? "could not load libduckdb" : err);
    return 0;
  }

  if (!LOAD(library_version) || !LOAD(open) || !LOAD(close) || !LOAD(connect) ||
      !LOAD(disconnect) || !LOAD(query) || !LOAD(destroy_result) ||
      !LOAD(result_error) || !LOAD(column_count) || !LOAD(row_count) ||
      !LOAD(column_name) || !LOAD(column_type) || !LOAD(value_is_null) ||
      !LOAD(value_boolean) || !LOAD(value_int64) || !LOAD(value_double) ||
      !LOAD(value_varchar) || !LOAD(value_blob) || !LOAD_AS(free_ptr, "duckdb_free") ||
      !LOAD(prepare) || !LOAD(prepare_error) || !LOAD(destroy_prepare) ||
      !LOAD(bind_null) || !LOAD(bind_boolean) || !LOAD(bind_int64) ||
      !LOAD(bind_double) || !LOAD(bind_varchar) || !LOAD(bind_blob) ||
      !LOAD(execute_prepared) || !LOAD(appender_create) || !LOAD(appender_flush) ||
      !LOAD(appender_close) || !LOAD(appender_destroy) || !LOAD(append_bool) ||
      !LOAD(append_int64) || !LOAD(append_double) || !LOAD(append_varchar) ||
      !LOAD(append_blob) || !LOAD(append_null) || !LOAD(appender_end_row) ||
      !LOAD(interrupt)) {
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

CAMLprim value eta_duckdb_available(value unit_value)
{
  CAMLparam1(unit_value);
  if (load_api()) CAMLreturn(Val_none);
  CAMLreturn(some_string(api.error));
}

CAMLprim value eta_duckdb_version(value unit_value)
{
  CAMLparam1(unit_value);
  ensure_loaded();
  CAMLreturn(caml_copy_string(api.library_version()));
}

CAMLprim value eta_duckdb_open(value v_path)
{
  CAMLparam1(v_path);
  CAMLlocal1(v_block);
  ensure_loaded();
  const char *path = String_val(v_path);
  duckdb_database db = NULL;
  int rc;
  caml_enter_blocking_section();
  rc = api.open(path[0] == '\0' ? NULL : path, &db);
  caml_leave_blocking_section();
  if (rc != 0) caml_failwith("duckdb_open failed");
  v_block = caml_alloc_custom(&db_ops, sizeof(eta_duckdb_db), 0, 1);
  ((eta_duckdb_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim value eta_duckdb_close_database(value v_db)
{
  CAMLparam1(v_db);
  ensure_loaded();
  eta_duckdb_db *db = (eta_duckdb_db *)Data_custom_val(v_db);
  if (db->db != NULL) {
    api.close(&db->db);
    db->db = NULL;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_connect(value v_db)
{
  CAMLparam1(v_db);
  CAMLlocal1(v_block);
  ensure_loaded();
  duckdb_connection conn = NULL;
  if (api.connect(db_val(v_db), &conn) != 0) caml_failwith("duckdb_connect failed");
  v_block = caml_alloc_custom(&conn_ops, sizeof(eta_duckdb_conn), 0, 1);
  ((eta_duckdb_conn *)Data_custom_val(v_block))->conn = conn;
  CAMLreturn(v_block);
}

CAMLprim value eta_duckdb_disconnect(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  eta_duckdb_conn *conn = (eta_duckdb_conn *)Data_custom_val(v_conn);
  if (conn->conn != NULL) {
    api.disconnect(&conn->conn);
    conn->conn = NULL;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_interrupt(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  duckdb_connection conn = conn_val(v_conn);
  if (conn != NULL) api.interrupt(conn);
  CAMLreturn(Val_unit);
}

static value make_block(int tag, value field)
{
  CAMLparam1(field);
  CAMLlocal1(out);
  out = caml_alloc(1, tag);
  Store_field(out, 0, field);
  CAMLreturn(out);
}

static value make_string_block(int tag, const char *s)
{
  CAMLparam0();
  CAMLlocal1(str);
  str = caml_copy_string(s == NULL ? "" : s);
  CAMLreturn(make_block(tag, str));
}

static value cons(value head, value tail)
{
  CAMLparam2(head, tail);
  CAMLlocal1(cell);
  cell = caml_alloc(2, 0);
  Store_field(cell, 0, head);
  Store_field(cell, 1, tail);
  CAMLreturn(cell);
}

static value value_from_result(duckdb_result *result, idx_t col, idx_t row)
{
  CAMLparam0();
  CAMLlocal1(out);
  if (api.value_is_null(result, col, row)) CAMLreturn(Val_int(0));
  int typ = api.column_type(result, col);
  switch (typ) {
  case 1:
    out = make_block(0, Val_bool(api.value_boolean(result, col, row)));
    CAMLreturn(out);
  case 2:
  case 3:
  case 4:
  case 5: {
    int64_t v = api.value_int64(result, col, row);
    if (v >= (int64_t)Long_val(Val_long(INT32_MIN)) && v <= (int64_t)Long_val(Val_long(INT32_MAX))) {
      out = make_block(1, Val_long((intnat)v));
    } else {
      out = make_block(2, caml_copy_int64(v));
    }
    CAMLreturn(out);
  }
  case 10:
  case 11:
    out = make_block(3, caml_copy_double(api.value_double(result, col, row)));
    CAMLreturn(out);
  case 18: {
    duckdb_blob blob = api.value_blob(result, col, row);
    value bytes = caml_alloc_string((mlsize_t)blob.size);
    if (blob.size > 0 && blob.data != NULL) memcpy(Bytes_val(bytes), blob.data, (size_t)blob.size);
    if (blob.data != NULL) api.free_ptr(blob.data);
    out = make_block(5, bytes);
    CAMLreturn(out);
  }
  default: {
    char *s = api.value_varchar(result, col, row);
    int tag = 4;
    if (typ == 19) tag = 6;
    else if (typ == 13) tag = 7;
    else if (typ == 14 || typ == 30) tag = 8;
    else if (typ == 12 || typ == 20 || typ == 21 || typ == 22 || typ == 31) tag = 9;
    else if (typ == 27) tag = 10;
    else if (typ == 23) tag = 12;
    out = make_string_block(tag, s);
    if (s != NULL) api.free_ptr(s);
    CAMLreturn(out);
  }
  }
}

static value materialize_rows(duckdb_result *result)
{
  CAMLparam0();
  CAMLlocal5(rows, row_list, pair, field_name, value_v);
  idx_t cols = api.column_count(result);
  idx_t count = api.row_count(result);
  rows = Val_emptylist;
  for (idx_t r = count; r > 0; r--) {
    idx_t row_idx = r - 1;
    row_list = Val_emptylist;
    for (idx_t c = cols; c > 0; c--) {
      idx_t col_idx = c - 1;
      field_name = caml_copy_string(api.column_name(result, col_idx));
      value_v = value_from_result(result, col_idx, row_idx);
      pair = caml_alloc_tuple(2);
      Store_field(pair, 0, field_name);
      Store_field(pair, 1, value_v);
      row_list = cons(pair, row_list);
    }
    rows = cons(row_list, rows);
  }
  CAMLreturn(rows);
}

static int bind_value(duckdb_prepared_statement stmt, idx_t index, value v)
{
  if (Is_long(v)) return api.bind_null(stmt, index);
  int tag = Tag_val(v);
  switch (tag) {
  case 0: return api.bind_boolean(stmt, index, Bool_val(Field(v, 0)));
  case 1: return api.bind_int64(stmt, index, Long_val(Field(v, 0)));
  case 2: return api.bind_int64(stmt, index, Int64_val(Field(v, 0)));
  case 3: return api.bind_double(stmt, index, Double_val(Field(v, 0)));
  case 4: return api.bind_varchar(stmt, index, String_val(Field(v, 0)));
  case 5: return api.bind_blob(stmt, index, Bytes_val(Field(v, 0)), caml_string_length(Field(v, 0)));
  case 6:
  case 7:
  case 8:
  case 9:
  case 10:
  case 11:
  case 12:
    return api.bind_varchar(stmt, index, String_val(Field(v, 0)));
  default:
    caml_failwith("cannot bind DuckDB list or struct values");
  }
}

static void bind_params(duckdb_prepared_statement stmt, value params)
{
  idx_t index = 1;
  while (params != Val_emptylist) {
    int rc = bind_value(stmt, index, Field(params, 0));
    if (rc != 0) caml_failwith("duckdb bind failed");
    params = Field(params, 1);
    index++;
  }
}

CAMLprim value eta_duckdb_query(value v_conn, value v_sql, value v_params)
{
  CAMLparam3(v_conn, v_sql, v_params);
  CAMLlocal1(rows);
  ensure_loaded();
  duckdb_prepared_statement stmt = NULL;
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  if (api.prepare(conn_val(v_conn), String_val(v_sql), &stmt) != 0) {
    const char *err = stmt == NULL ? "prepare failed" : api.prepare_error(stmt);
    if (stmt != NULL) api.destroy_prepare(&stmt);
    caml_failwith(err == NULL ? "prepare failed" : err);
  }
  bind_params(stmt, v_params);
  int rc;
  caml_enter_blocking_section();
  rc = api.execute_prepared(stmt, &result);
  caml_leave_blocking_section();
  api.destroy_prepare(&stmt);
  if (rc != 0) {
    const char *err = api.result_error(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    api.destroy_result(&result);
    caml_failwith(buffer);
  }
  rows = materialize_rows(&result);
  api.destroy_result(&result);
  CAMLreturn(rows);
}

CAMLprim value eta_duckdb_execute(value v_conn, value v_sql, value v_params)
{
  CAMLparam3(v_conn, v_sql, v_params);
  ensure_loaded();
  duckdb_prepared_statement stmt = NULL;
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  if (api.prepare(conn_val(v_conn), String_val(v_sql), &stmt) != 0) {
    const char *err = stmt == NULL ? "prepare failed" : api.prepare_error(stmt);
    if (stmt != NULL) api.destroy_prepare(&stmt);
    caml_failwith(err == NULL ? "prepare failed" : err);
  }
  bind_params(stmt, v_params);
  int rc;
  caml_enter_blocking_section();
  rc = api.execute_prepared(stmt, &result);
  caml_leave_blocking_section();
  api.destroy_prepare(&stmt);
  if (rc != 0) {
    const char *err = api.result_error(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "execute failed" : err);
    api.destroy_result(&result);
    caml_failwith(buffer);
  }
  int changed = (int)result.deprecated_rows_changed;
  api.destroy_result(&result);
  CAMLreturn(Val_int(changed));
}

CAMLprim value eta_duckdb_exec_script(value v_conn, value v_sql)
{
  CAMLparam2(v_conn, v_sql);
  ensure_loaded();
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  int rc;
  caml_enter_blocking_section();
  rc = api.query(conn_val(v_conn), String_val(v_sql), &result);
  caml_leave_blocking_section();
  if (rc != 0) {
    const char *err = api.result_error(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "exec failed" : err);
    api.destroy_result(&result);
    caml_failwith(buffer);
  }
  api.destroy_result(&result);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_appender_create(value v_conn, value v_schema, value v_table)
{
  CAMLparam3(v_conn, v_schema, v_table);
  CAMLlocal1(v_block);
  ensure_loaded();
  duckdb_appender appender = NULL;
  const char *schema = Is_block(v_schema) ? String_val(Field(v_schema, 0)) : NULL;
  if (api.appender_create(conn_val(v_conn), schema, String_val(v_table), &appender) != 0) {
    caml_failwith("duckdb_appender_create failed");
  }
  v_block = caml_alloc_custom(&appender_ops, sizeof(eta_duckdb_appender), 0, 1);
  ((eta_duckdb_appender *)Data_custom_val(v_block))->appender = appender;
  CAMLreturn(v_block);
}

static void append_value(duckdb_appender appender, value v)
{
  int rc = 0;
  if (Is_long(v)) rc = api.append_null(appender);
  else {
    switch (Tag_val(v)) {
    case 0: rc = api.append_bool(appender, Bool_val(Field(v, 0))); break;
    case 1: rc = api.append_int64(appender, Long_val(Field(v, 0))); break;
    case 2: rc = api.append_int64(appender, Int64_val(Field(v, 0))); break;
    case 3: rc = api.append_double(appender, Double_val(Field(v, 0))); break;
    case 4: rc = api.append_varchar(appender, String_val(Field(v, 0))); break;
    case 5: rc = api.append_blob(appender, Bytes_val(Field(v, 0)), caml_string_length(Field(v, 0))); break;
    case 6:
    case 7:
    case 8:
    case 9:
    case 10:
    case 11:
    case 12:
      rc = api.append_varchar(appender, String_val(Field(v, 0)));
      break;
    default:
      caml_failwith("cannot append DuckDB list or struct values");
    }
  }
  if (rc != 0) caml_failwith("duckdb append value failed");
}

CAMLprim value eta_duckdb_appender_append_row(value v_appender, value values)
{
  CAMLparam2(v_appender, values);
  ensure_loaded();
  duckdb_appender appender = appender_val(v_appender);
  while (values != Val_emptylist) {
    append_value(appender, Field(values, 0));
    values = Field(values, 1);
  }
  if (api.appender_end_row(appender) != 0) caml_failwith("duckdb_appender_end_row failed");
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_appender_flush(value v_appender)
{
  CAMLparam1(v_appender);
  ensure_loaded();
  if (api.appender_flush(appender_val(v_appender)) != 0) caml_failwith("duckdb_appender_flush failed");
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_appender_close(value v_appender)
{
  CAMLparam1(v_appender);
  ensure_loaded();
  eta_duckdb_appender *appender = (eta_duckdb_appender *)Data_custom_val(v_appender);
  if (appender->appender != NULL) {
    if (api.appender_close(appender->appender) != 0) caml_failwith("duckdb_appender_close failed");
    (void)api.appender_destroy(&appender->appender);
    appender->appender = NULL;
  }
  CAMLreturn(Val_unit);
}
