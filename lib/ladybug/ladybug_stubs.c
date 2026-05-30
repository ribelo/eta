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

struct ArrowSchema {
  const char *format;
  const char *name;
  const char *metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema **children;
  struct ArrowSchema *dictionary;
  void (*release)(struct ArrowSchema *);
  void *private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void **buffers;
  struct ArrowArray **children;
  struct ArrowArray *dictionary;
  void (*release)(struct ArrowArray *);
  void *private_data;
};

typedef enum { LbugSuccess = 0, LbugError = 1 } lbug_state;
typedef struct { void *ptr; } lbug_database;
typedef struct { void *ptr; } lbug_connection;
typedef struct { void *ptr; bool owned; } lbug_query_result;
typedef struct { void *ptr; void *bound_values; } lbug_prepared_statement;
typedef struct { void *ptr; bool owned; } lbug_value;
typedef struct {
  uint64_t buffer_pool_size;
  uint64_t max_num_threads;
  bool enable_compression;
  bool read_only;
  uint64_t max_db_size;
  bool auto_checkpoint;
  uint64_t checkpoint_threshold;
  bool throw_on_wal_replay_failure;
  bool enable_checksums;
#if defined(__APPLE__)
  uint32_t thread_qos;
#endif
} lbug_system_config;

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
  lbug_state (*query_result_get_arrow_schema)(lbug_query_result *, struct ArrowSchema *);
  lbug_state (*query_result_get_next_arrow_chunk)(lbug_query_result *, int64_t, struct ArrowArray *);
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
  lbug_value *(*value_create_bool)(bool);
  lbug_value *(*value_create_int64)(int64_t);
  lbug_value *(*value_create_double)(double);
  lbug_value *(*value_create_string)(const char *);
  lbug_state (*value_create_list)(uint64_t, lbug_value **, lbug_value **);
  lbug_state (*value_create_map)(uint64_t, lbug_value **, lbug_value **, lbug_value **);
  lbug_state (*value_create_struct)(uint64_t, const char **, lbug_value **, lbug_value **);
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
    api.handle = dlopen(candidates[i], RTLD_NOW | RTLD_GLOBAL);
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
      !LOAD(query_result_get_arrow_schema) ||
      !LOAD(query_result_get_next_arrow_chunk) ||
      !LOAD(query_result_destroy) || !LOAD(connection_prepare) ||
      !LOAD(prepared_statement_is_success) ||
      !LOAD(prepared_statement_get_error_message) ||
      !LOAD(prepared_statement_destroy) ||
      !LOAD(prepared_statement_bind_string) ||
      !LOAD(prepared_statement_bind_int64) ||
      !LOAD(prepared_statement_bind_double) ||
      !LOAD(prepared_statement_bind_bool) ||
      !LOAD(value_create_null) || !LOAD(value_create_bool) ||
      !LOAD(value_create_int64) || !LOAD(value_create_double) ||
      !LOAD(value_create_string) || !LOAD(value_create_list) ||
      !LOAD(value_create_map) || !LOAD(value_create_struct) ||
      !LOAD(value_destroy) ||
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

static lbug_value *create_lbug_value(value v);

static void destroy_lbug_values(lbug_value **values, uint64_t count)
{
  if (values == NULL) return;
  for (uint64_t i = 0; i < count; i++) {
    if (values[i] != NULL) api.value_destroy(values[i]);
  }
  free(values);
}

static lbug_value *create_lbug_list(value values)
{
  uint64_t count = 0;
  for (value cur = values; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  lbug_value **items = calloc((size_t)count, sizeof(lbug_value *));
  if (items == NULL) caml_failwith("allocating LadybugDB list parameter failed");
  uint64_t i = 0;
  for (value cur = values; cur != Val_emptylist; cur = Field(cur, 1)) {
    items[i++] = create_lbug_value(Field(cur, 0));
  }
  lbug_value *list = NULL;
  if (api.value_create_list(count, items, &list) != LbugSuccess) {
    destroy_lbug_values(items, count);
    fail_last("create list");
  }
  destroy_lbug_values(items, count);
  return list;
}

static lbug_value *create_lbug_map(value fields)
{
  uint64_t count = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  lbug_value **keys = calloc((size_t)count, sizeof(lbug_value *));
  lbug_value **vals = calloc((size_t)count, sizeof(lbug_value *));
  if (keys == NULL || vals == NULL) {
    free(keys);
    free(vals);
    caml_failwith("allocating LadybugDB map parameter failed");
  }
  uint64_t i = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) {
    value pair = Field(cur, 0);
    keys[i] = api.value_create_string(String_val(Field(pair, 0)));
    vals[i] = create_lbug_value(Field(pair, 1));
    i++;
  }
  lbug_value *map = NULL;
  if (api.value_create_map(count, keys, vals, &map) != LbugSuccess) {
    destroy_lbug_values(keys, count);
    destroy_lbug_values(vals, count);
    fail_last("create map");
  }
  destroy_lbug_values(keys, count);
  destroy_lbug_values(vals, count);
  return map;
}

static lbug_value *create_lbug_struct(value fields)
{
  uint64_t count = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  const char **names = calloc((size_t)count, sizeof(char *));
  lbug_value **vals = calloc((size_t)count, sizeof(lbug_value *));
  if (names == NULL || vals == NULL) {
    free(names);
    free(vals);
    caml_failwith("allocating LadybugDB struct parameter failed");
  }
  uint64_t i = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) {
    value pair = Field(cur, 0);
    names[i] = String_val(Field(pair, 0));
    vals[i] = create_lbug_value(Field(pair, 1));
    i++;
  }
  lbug_value *struct_ = NULL;
  if (api.value_create_struct(count, names, vals, &struct_) != LbugSuccess) {
    free(names);
    destroy_lbug_values(vals, count);
    caml_failwith("create struct");
  }
  free(names);
  destroy_lbug_values(vals, count);
  return struct_;
}

static lbug_value *create_lbug_value(value v)
{
  if (Is_long(v)) return api.value_create_null();
  switch (Tag_val(v)) {
  case 0:
    return api.value_create_bool(Bool_val(Field(v, 0)));
  case 1:
    return api.value_create_int64(Int64_val(Field(v, 0)));
  case 2:
    return api.value_create_double(Double_val(Field(v, 0)));
  case 3:
    return api.value_create_string(String_val(Field(v, 0)));
  case 4:
    return create_lbug_list(Field(v, 0));
  case 5:
    return create_lbug_map(Field(v, 0));
  case 6:
    return create_lbug_struct(Field(v, 0));
  default:
    caml_failwith("LadybugDB nested parameter value supports null, bool, int, float, string, list, map, and struct");
  }
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
    case 4:
    case 5:
    case 6: {
      lbug_value *nested = create_lbug_value(v);
      state = api.prepared_statement_bind_value(stmt, name, nested);
      if (nested != NULL) api.value_destroy(nested);
      break;
    }
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

static value cons(value head, value tail)
{
  CAMLparam2(head, tail);
  CAMLlocal1(cell);
  cell = caml_alloc(2, 0);
  Store_field(cell, 0, head);
  Store_field(cell, 1, tail);
  CAMLreturn(cell);
}

static value list_rev(value list)
{
  CAMLparam1(list);
  CAMLlocal2(out, head);
  out = Val_emptylist;
  while (list != Val_emptylist) {
    head = Field(list, 0);
    out = cons(head, out);
    list = Field(list, 1);
  }
  CAMLreturn(out);
}

static value make_block(int tag, value field)
{
  CAMLparam1(field);
  CAMLlocal1(out);
  out = caml_alloc(1, tag);
  Store_field(out, 0, field);
  CAMLreturn(out);
}

static value some_int64(int64_t int_value)
{
  CAMLparam0();
  CAMLlocal2(some, boxed);
  boxed = caml_copy_int64(int_value);
  some = caml_alloc(1, 0);
  Store_field(some, 0, boxed);
  CAMLreturn(some);
}

static int arrow_valid(struct ArrowArray *array, int64_t row)
{
  if (array->null_count == 0 || array->buffers == NULL || array->buffers[0] == NULL) return 1;
  const uint8_t *bits = (const uint8_t *)array->buffers[0];
  int64_t bit = array->offset + row;
  return (bits[bit / 8] >> (bit % 8)) & 1;
}

static int64_t arrow_i64(struct ArrowArray *array, int64_t row)
{
  const int64_t *values = (const int64_t *)array->buffers[1];
  return values[array->offset + row];
}

static double arrow_f64(struct ArrowArray *array, int64_t row)
{
  const double *values = (const double *)array->buffers[1];
  return values[array->offset + row];
}

static int arrow_bool(struct ArrowArray *array, int64_t row)
{
  const uint8_t *bits = (const uint8_t *)array->buffers[1];
  int64_t bit = array->offset + row;
  return (bits[bit / 8] >> (bit % 8)) & 1;
}

static value arrow_string(struct ArrowArray *array, int64_t row)
{
  CAMLparam0();
  CAMLlocal1(out);
  int64_t logical = array->offset + row;
  const int32_t *offsets = (const int32_t *)array->buffers[1];
  const char *bytes = (const char *)array->buffers[2];
  int32_t start = offsets[logical];
  int32_t end = offsets[logical + 1];
  int32_t len = end - start;
  out = caml_alloc_string(len);
  if (len > 0) memcpy(Bytes_val(out), bytes + start, (size_t)len);
  CAMLreturn(out);
}

static value arrow_value(struct ArrowSchema *schema, struct ArrowArray *array, int64_t row);

static value make_pair(const char *name, value v)
{
  CAMLparam1(v);
  CAMLlocal2(pair, field);
  field = caml_copy_string(name == NULL ? "" : name);
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, field);
  Store_field(pair, 1, v);
  CAMLreturn(pair);
}

static value struct_properties(struct ArrowSchema *schema, struct ArrowArray *array,
    int64_t row, int skip_graph_fields)
{
  CAMLparam0();
  CAMLlocal3(props, v, pair);
  props = Val_emptylist;
  for (int64_t i = schema->n_children; i > 0; i--) {
    int64_t idx = i - 1;
    const char *name = schema->children[idx]->name;
    if (skip_graph_fields &&
        (strcmp(name, "_ID") == 0 || strcmp(name, "_LABEL") == 0)) {
      continue;
    }
    v = arrow_value(schema->children[idx], array->children[idx], row);
    pair = make_pair(name, v);
    props = cons(pair, props);
  }
  CAMLreturn(props);
}

static int find_child(struct ArrowSchema *schema, const char *name)
{
  for (int64_t i = 0; i < schema->n_children; i++) {
    if (schema->children[i]->name != NULL && strcmp(schema->children[i]->name, name) == 0) {
      return (int)i;
    }
  }
  return -1;
}

static value arrow_node(struct ArrowSchema *schema, struct ArrowArray *array, int64_t row)
{
  CAMLparam0();
  CAMLlocal5(label_v, labels, props, record, node_v);
  CAMLlocal1(id_opt);
  int label_idx = find_child(schema, "_LABEL");
  int id_idx = find_child(schema, "_ID");
  id_opt = Val_none;
  if (label_idx >= 0 && array->children != NULL && array->children[label_idx] != NULL) {
    label_v = arrow_string(array->children[label_idx], row);
    labels = cons(label_v, Val_emptylist);
  } else {
    labels = Val_emptylist;
  }
  if (id_idx >= 0 && array->children != NULL && array->children[id_idx] != NULL &&
      array->children[id_idx]->children != NULL && array->children[id_idx]->n_children > 0 &&
      array->children[id_idx]->children[0] != NULL) {
    id_opt = some_int64(arrow_i64(array->children[id_idx]->children[0], row));
  }
  props = struct_properties(schema, array, row, 1);
  record = caml_alloc(3, 0);
  Store_field(record, 0, id_opt);
  Store_field(record, 1, labels);
  Store_field(record, 2, props);
  node_v = caml_alloc(1, 7);
  Store_field(node_v, 0, record);
  CAMLreturn(node_v);
}

static value arrow_struct_map(struct ArrowSchema *schema, struct ArrowArray *array, int64_t row)
{
  CAMLparam0();
  CAMLlocal2(props, out);
  props = struct_properties(schema, array, row, 0);
  out = caml_alloc(1, 5);
  Store_field(out, 0, props);
  CAMLreturn(out);
}

static value arrow_value(struct ArrowSchema *schema, struct ArrowArray *array, int64_t row)
{
  CAMLparam0();
  CAMLlocal2(v, out);
  if (!arrow_valid(array, row)) CAMLreturn(Val_int(0));
  const char *format = schema->format == NULL ? "" : schema->format;
  if (strcmp(format, "b") == 0) {
    out = caml_alloc(1, 0);
    Store_field(out, 0, Val_bool(arrow_bool(array, row)));
    CAMLreturn(out);
  }
  if (strcmp(format, "l") == 0) {
    out = caml_alloc(1, 1);
    Store_field(out, 0, caml_copy_int64(arrow_i64(array, row)));
    CAMLreturn(out);
  }
  if (strcmp(format, "g") == 0) {
    out = caml_alloc(1, 2);
    Store_field(out, 0, caml_copy_double(arrow_f64(array, row)));
    CAMLreturn(out);
  }
  if (strcmp(format, "u") == 0) {
    v = arrow_string(array, row);
    CAMLreturn(make_block(3, v));
  }
  if (strcmp(format, "+s") == 0) {
    if (find_child(schema, "_LABEL") >= 0) CAMLreturn(arrow_node(schema, array, row));
    CAMLreturn(arrow_struct_map(schema, array, row));
  }
  v = caml_copy_string("");
  CAMLreturn(make_block(3, v));
}

static value materialize_arrow_rows(lbug_query_result *result)
{
  CAMLparam0();
  CAMLlocal5(rows, row_list, pair, value_v, field_name);
  struct ArrowSchema schema;
  memset(&schema, 0, sizeof(schema));
  if (api.query_result_get_arrow_schema(result, &schema) != LbugSuccess) fail_last("get_arrow_schema");
  rows = Val_emptylist;
  for (;;) {
    struct ArrowArray array;
    memset(&array, 0, sizeof(array));
    if (api.query_result_get_next_arrow_chunk(result, 1024, &array) != LbugSuccess) {
      if (schema.release) schema.release(&schema);
      fail_last("get_next_arrow_chunk");
    }
    if (array.release == NULL || array.length == 0) {
      if (array.release) array.release(&array);
      break;
    }
    for (int64_t row_idx = 0; row_idx < array.length; row_idx++) {
      row_list = Val_emptylist;
      for (int64_t c = schema.n_children; c > 0; c--) {
        int64_t col_idx = c - 1;
        field_name = caml_copy_string(schema.children[col_idx]->name == NULL ? "" : schema.children[col_idx]->name);
        value_v = arrow_value(schema.children[col_idx], array.children[col_idx], row_idx);
        pair = caml_alloc_tuple(2);
        Store_field(pair, 0, field_name);
        Store_field(pair, 1, value_v);
        row_list = cons(pair, row_list);
      }
      rows = cons(row_list, rows);
    }
    if (array.release) array.release(&array);
  }
  if (schema.release) schema.release(&schema);
  CAMLreturn(list_rev(rows));
}

static value execute_direct(lbug_connection *conn, const char *cypher)
{
  CAMLparam0();
  CAMLlocal1(out);
  lbug_query_result result;
  result.ptr = NULL;
  result.owned = false;
  char *cypher_copy = caml_stat_strdup(cypher);
  lbug_state state;
  caml_enter_blocking_section();
  state = api.connection_query(conn, cypher_copy, &result);
  caml_leave_blocking_section();
  caml_stat_free(cypher_copy);
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
  stmt.bound_values = NULL;
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

static value execute_direct_values(lbug_connection *conn, const char *cypher)
{
  CAMLparam0();
  CAMLlocal1(out);
  lbug_query_result result;
  result.ptr = NULL;
  result.owned = false;
  char *cypher_copy = caml_stat_strdup(cypher);
  lbug_state state;
  caml_enter_blocking_section();
  state = api.connection_query(conn, cypher_copy, &result);
  caml_leave_blocking_section();
  caml_stat_free(cypher_copy);
  if (state != LbugSuccess) fail_last("connection_query");
  if (!api.query_result_is_success(&result)) {
    char *err = api.query_result_get_error_message(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.query_result_destroy(&result);
    caml_failwith(buffer);
  }
  out = materialize_arrow_rows(&result);
  api.query_result_destroy(&result);
  CAMLreturn(out);
}

static value execute_prepared_values(lbug_connection *conn, const char *cypher, value params)
{
  CAMLparam1(params);
  CAMLlocal1(out);
  lbug_prepared_statement stmt;
  lbug_query_result result;
  stmt.ptr = NULL;
  stmt.bound_values = NULL;
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
  out = materialize_arrow_rows(&result);
  api.query_result_destroy(&result);
  api.prepared_statement_destroy(&stmt);
  CAMLreturn(out);
}

CAMLprim value eta_ladybug_query_values(value v_conn, value v_cypher, value v_params)
{
  CAMLparam3(v_conn, v_cypher, v_params);
  ensure_loaded();
  lbug_connection *conn = conn_val(v_conn);
  if (v_params == Val_emptylist) CAMLreturn(execute_direct_values(conn, String_val(v_cypher)));
  CAMLreturn(execute_prepared_values(conn, String_val(v_cypher), v_params));
}
