#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t idx_t;
typedef void *duckdb_database;
typedef void *duckdb_connection;
typedef void *duckdb_prepared_statement;
typedef void *duckdb_appender;
typedef void *duckdb_logical_type;
typedef void *duckdb_data_chunk;
typedef void *duckdb_vector;
typedef void *duckdb_value;

typedef struct {
  void *data;
  idx_t size;
} duckdb_blob;

typedef struct {
  char *data;
  idx_t size;
} duckdb_string;

typedef struct {
  uint64_t lower;
  int64_t upper;
} duckdb_hugeint;

typedef struct {
  uint64_t lower;
  uint64_t upper;
} duckdb_uhugeint;

typedef struct {
  idx_t deprecated_column_count;
  idx_t deprecated_row_count;
  idx_t deprecated_rows_changed;
  void *deprecated_columns;
  char *deprecated_error_message;
  void *internal_data;
} duckdb_result;

typedef struct {
  union {
    struct {
      uint32_t length;
      char prefix[4];
      char *ptr;
    } pointer;
    struct {
      uint32_t length;
      char inlined[12];
    } inlined;
  } value;
} duckdb_string_t;

typedef struct {
  uint64_t offset;
  uint64_t length;
} duckdb_list_entry;

#define ETA_DUCKDB_TYPE_BOOLEAN 1
#define ETA_DUCKDB_TYPE_TINYINT 2
#define ETA_DUCKDB_TYPE_SMALLINT 3
#define ETA_DUCKDB_TYPE_INTEGER 4
#define ETA_DUCKDB_TYPE_BIGINT 5
#define ETA_DUCKDB_TYPE_FLOAT 10
#define ETA_DUCKDB_TYPE_DOUBLE 11
#define ETA_DUCKDB_TYPE_TIMESTAMP 12
#define ETA_DUCKDB_TYPE_DATE 13
#define ETA_DUCKDB_TYPE_TIME 14
#define ETA_DUCKDB_TYPE_VARCHAR 17
#define ETA_DUCKDB_TYPE_BLOB 18
#define ETA_DUCKDB_TYPE_DECIMAL 19
#define ETA_DUCKDB_TYPE_TIMESTAMP_S 20
#define ETA_DUCKDB_TYPE_TIMESTAMP_MS 21
#define ETA_DUCKDB_TYPE_TIMESTAMP_NS 22
#define ETA_DUCKDB_TYPE_ENUM 23
#define ETA_DUCKDB_TYPE_LIST 24
#define ETA_DUCKDB_TYPE_UUID 27
#define ETA_DUCKDB_TYPE_TIME_TZ 30
#define ETA_DUCKDB_TYPE_TIMESTAMP_TZ 31

typedef struct { duckdb_database db; } eta_duckdb_db;
typedef struct { duckdb_connection conn; } eta_duckdb_conn;
typedef struct { duckdb_appender appender; } eta_duckdb_appender;
typedef struct {
  duckdb_result result;
  int active;
} eta_duckdb_result_owner;
typedef struct {
  void *ptr;
} eta_duckdb_ptr_owner;
typedef struct {
  duckdb_data_chunk chunk;
} eta_duckdb_data_chunk_owner;

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
  idx_t (*rows_changed)(duckdb_result *);
  const char *(*column_name)(duckdb_result *, idx_t);
  int (*column_type)(duckdb_result *, idx_t);
  int (*value_is_null)(duckdb_result *, idx_t, idx_t);
  int (*value_boolean)(duckdb_result *, idx_t, idx_t);
  int64_t (*value_int64)(duckdb_result *, idx_t, idx_t);
  double (*value_double)(duckdb_result *, idx_t, idx_t);
  duckdb_string (*value_string)(duckdb_result *, idx_t, idx_t);
  duckdb_blob (*value_blob)(duckdb_result *, idx_t, idx_t);
  duckdb_value (*create_uuid)(duckdb_uhugeint);
  char *(*get_varchar)(duckdb_value);
  void (*destroy_value)(duckdb_value *);
  int (*get_type_id)(duckdb_logical_type);
  void (*destroy_logical_type)(duckdb_logical_type *);
  idx_t (*result_chunk_count)(duckdb_result);
  duckdb_data_chunk (*result_get_chunk)(duckdb_result, idx_t);
  void (*destroy_data_chunk)(duckdb_data_chunk *);
  idx_t (*data_chunk_get_size)(duckdb_data_chunk);
  duckdb_vector (*data_chunk_get_vector)(duckdb_data_chunk, idx_t);
  duckdb_logical_type (*vector_get_column_type)(duckdb_vector);
  void *(*vector_get_data)(duckdb_vector);
  uint64_t *(*vector_get_validity)(duckdb_vector);
  duckdb_vector (*list_vector_get_child)(duckdb_vector);
  uint32_t (*string_t_length)(duckdb_string_t);
  const char *(*string_t_data)(duckdb_string_t *);
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
static pthread_mutex_t api_mutex = PTHREAD_MUTEX_INITIALIZER;

static void db_finalize(value v_db)
{
  eta_duckdb_db *db = (eta_duckdb_db *)Data_custom_val(v_db);
  if (db->db != NULL && api.loaded) {
    /* OCaml custom finalizers cannot safely enter blocking sections; leaked
       handles reach this path only as best-effort cleanup. Normal close paths
       are explicit OCaml calls and may release the runtime lock. */
    api.close(&db->db);
    db->db = NULL;
  }
}

static void conn_finalize(value v_conn)
{
  eta_duckdb_conn *conn = (eta_duckdb_conn *)Data_custom_val(v_conn);
  if (conn->conn != NULL && api.loaded) {
    /* See db_finalize for why custom finalizers stay inside the runtime lock. */
    api.disconnect(&conn->conn);
    conn->conn = NULL;
  }
}

static void appender_finalize(value v_appender)
{
  eta_duckdb_appender *appender = (eta_duckdb_appender *)Data_custom_val(v_appender);
  if (appender->appender != NULL && api.loaded) {
    /* See db_finalize for why custom finalizers stay inside the runtime lock. */
    (void)api.appender_destroy(&appender->appender);
    appender->appender = NULL;
  }
}

static void result_owner_finalize(value v_owner)
{
  eta_duckdb_result_owner *owner =
    (eta_duckdb_result_owner *)Data_custom_val(v_owner);
  if (owner->active && api.loaded) {
    /* See db_finalize for why custom finalizers stay inside the runtime lock. */
    api.destroy_result(&owner->result);
    owner->active = 0;
  }
}

static void ptr_owner_finalize(value v_owner)
{
  eta_duckdb_ptr_owner *owner =
    (eta_duckdb_ptr_owner *)Data_custom_val(v_owner);
  if (owner->ptr != NULL && api.loaded) {
    void *ptr = owner->ptr;
    owner->ptr = NULL;
    api.free_ptr(ptr);
  }
}

static void data_chunk_owner_finalize(value v_owner)
{
  eta_duckdb_data_chunk_owner *owner =
    (eta_duckdb_data_chunk_owner *)Data_custom_val(v_owner);
  if (owner->chunk != NULL && api.loaded) {
    duckdb_data_chunk chunk = owner->chunk;
    owner->chunk = NULL;
    api.destroy_data_chunk(&chunk);
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

static struct custom_operations result_owner_ops = {
  "eta.duckdb.result_owner", result_owner_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations ptr_owner_ops = {
  "eta.duckdb.ptr_owner", ptr_owner_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations data_chunk_owner_ops = {
  "eta.duckdb.data_chunk_owner", data_chunk_owner_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static duckdb_database db_val(value v) { return ((eta_duckdb_db *)Data_custom_val(v))->db; }
static duckdb_connection conn_val(value v) { return ((eta_duckdb_conn *)Data_custom_val(v))->conn; }
static void appender_destroy_blocking(eta_duckdb_appender *appender)
{
  if (appender->appender != NULL) {
    duckdb_appender handle = appender->appender;
    appender->appender = NULL;
    caml_enter_blocking_section();
    (void)api.appender_destroy(&handle);
    caml_leave_blocking_section();
  }
}

static int appender_close_destroy_blocking(eta_duckdb_appender *appender)
{
  int rc = 0;
  if (appender->appender != NULL) {
    duckdb_appender handle = appender->appender;
    appender->appender = NULL;
    caml_enter_blocking_section();
    rc = api.appender_close(handle);
    (void)api.appender_destroy(&handle);
    caml_leave_blocking_section();
  }
  return rc;
}

static value result_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  eta_duckdb_result_owner *owner;
  v_owner = caml_alloc_custom(&result_owner_ops, sizeof(eta_duckdb_result_owner), 0, 1);
  owner = (eta_duckdb_result_owner *)Data_custom_val(v_owner);
  memset(&owner->result, 0, sizeof(owner->result));
  owner->active = 0;
  CAMLreturn(v_owner);
}

static duckdb_result *result_owner_val(value v_owner)
{
  return &((eta_duckdb_result_owner *)Data_custom_val(v_owner))->result;
}

static void result_owner_activate(value v_owner)
{
  ((eta_duckdb_result_owner *)Data_custom_val(v_owner))->active = 1;
}

static void result_owner_destroy(value v_owner)
{
  eta_duckdb_result_owner *owner =
    (eta_duckdb_result_owner *)Data_custom_val(v_owner);
  if (owner->active) {
    api.destroy_result(&owner->result);
    owner->active = 0;
  }
}

static value ptr_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  eta_duckdb_ptr_owner *owner;
  v_owner = caml_alloc_custom(&ptr_owner_ops, sizeof(eta_duckdb_ptr_owner), 0, 1);
  owner = (eta_duckdb_ptr_owner *)Data_custom_val(v_owner);
  owner->ptr = NULL;
  CAMLreturn(v_owner);
}

static void ptr_owner_set(value v_owner, void *ptr)
{
  ((eta_duckdb_ptr_owner *)Data_custom_val(v_owner))->ptr = ptr;
}

static void ptr_owner_release(value v_owner)
{
  eta_duckdb_ptr_owner *owner =
    (eta_duckdb_ptr_owner *)Data_custom_val(v_owner);
  if (owner->ptr != NULL) {
    void *ptr = owner->ptr;
    owner->ptr = NULL;
    api.free_ptr(ptr);
  }
}

static value data_chunk_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  eta_duckdb_data_chunk_owner *owner;
  v_owner =
    caml_alloc_custom(&data_chunk_owner_ops, sizeof(eta_duckdb_data_chunk_owner), 0, 1);
  owner = (eta_duckdb_data_chunk_owner *)Data_custom_val(v_owner);
  owner->chunk = NULL;
  CAMLreturn(v_owner);
}

static void data_chunk_owner_set(value v_owner, duckdb_data_chunk chunk)
{
  ((eta_duckdb_data_chunk_owner *)Data_custom_val(v_owner))->chunk = chunk;
}

static void data_chunk_owner_release(value v_owner)
{
  eta_duckdb_data_chunk_owner *owner =
    (eta_duckdb_data_chunk_owner *)Data_custom_val(v_owner);
  if (owner->chunk != NULL) {
    duckdb_data_chunk chunk = owner->chunk;
    owner->chunk = NULL;
    api.destroy_data_chunk(&chunk);
  }
}

static int load_symbol(void **slot, const char *name)
{
  *slot = dlsym(api.handle, name);
  if (*slot == NULL) {
    snprintf(api.error, sizeof(api.error), "missing symbol %s", name);
    return 0;
  }
  return 1;
}

static void load_symbol_optional(void **slot, const char *name)
{
  *slot = dlsym(api.handle, name);
}

#define LOAD(name) load_symbol((void **)&api.name, "duckdb_" #name)
#define LOAD_AS(field, symbol) load_symbol((void **)&api.field, symbol)
#define LOAD_OPTIONAL(name) load_symbol_optional((void **)&api.name, "duckdb_" #name)
#define LOAD_OPTIONAL_AS(field, symbol) load_symbol_optional((void **)&api.field, symbol)

static void reset_failed_api_load_unlocked(void)
{
  void *handle = api.handle;
  char error[sizeof(api.error)];
  snprintf(error, sizeof(error), "%s",
           api.error[0] == '\0' ? "could not load libduckdb" : api.error);
  if (handle != NULL) dlclose(handle);
  memset(&api, 0, sizeof(api));
  snprintf(api.error, sizeof(api.error), "%s", error);
}

static int load_api_unlocked(void)
{
  if (api.loaded) return 1;
  if (api.attempted) return 0;
  api.attempted = 1;

  const char *env = getenv("ETA_DUCKDB_LIBRARY");
  const char *candidates[] = { env, "libduckdb.so", "libduckdb.so.1", "libduckdb.dylib", NULL };
  size_t candidate_count = sizeof(candidates) / sizeof(candidates[0]);
  for (size_t i = 0; i < candidate_count; i++) {
    if (candidates[i] == NULL || candidates[i][0] == '\0') continue;
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
      !LOAD(rows_changed) || !LOAD(column_name) || !LOAD(column_type) ||
      !LOAD(value_is_null) || !LOAD(value_boolean) || !LOAD(value_int64) ||
      !LOAD(value_double) || !LOAD(value_string) || !LOAD(value_blob) ||
      !LOAD(create_uuid) || !LOAD(get_varchar) || !LOAD(destroy_value) ||
      !LOAD_AS(free_ptr, "duckdb_free") ||
      !LOAD(prepare) || !LOAD(prepare_error) || !LOAD(destroy_prepare) ||
      !LOAD(bind_null) || !LOAD(bind_boolean) || !LOAD(bind_int64) ||
      !LOAD(bind_double) || !LOAD(bind_varchar) || !LOAD(bind_blob) ||
      !LOAD(execute_prepared) || !LOAD(appender_create) || !LOAD(appender_flush) ||
      !LOAD(appender_close) || !LOAD(appender_destroy) || !LOAD(append_bool) ||
      !LOAD(append_int64) || !LOAD(append_double) || !LOAD(append_varchar) ||
      !LOAD(append_blob) || !LOAD(append_null) || !LOAD(appender_end_row) ||
      !LOAD(interrupt)) {
    reset_failed_api_load_unlocked();
    return 0;
  }
  LOAD_OPTIONAL(get_type_id);
  LOAD_OPTIONAL(destroy_logical_type);
  LOAD_OPTIONAL(result_chunk_count);
  LOAD_OPTIONAL(result_get_chunk);
  LOAD_OPTIONAL(destroy_data_chunk);
  LOAD_OPTIONAL(data_chunk_get_size);
  LOAD_OPTIONAL(data_chunk_get_vector);
  LOAD_OPTIONAL(vector_get_column_type);
  LOAD_OPTIONAL(vector_get_data);
  LOAD_OPTIONAL(vector_get_validity);
  LOAD_OPTIONAL(list_vector_get_child);
  LOAD_OPTIONAL_AS(string_t_length, "duckdb_string_t_length");
  LOAD_OPTIONAL_AS(string_t_data, "duckdb_string_t_data");

  api.loaded = 1;
  return 1;
}

static int load_api(void)
{
  int loaded;
  pthread_mutex_lock(&api_mutex);
  loaded = load_api_unlocked();
  pthread_mutex_unlock(&api_mutex);
  return loaded;
}

static void ensure_loaded(void)
{
  if (!load_api()) caml_failwith(api.error);
}

static const char *missing_list_result_symbol(void)
{
  if (api.get_type_id == NULL) return "duckdb_get_type_id";
  if (api.destroy_logical_type == NULL) return "duckdb_destroy_logical_type";
  if (api.result_chunk_count == NULL) return "duckdb_result_chunk_count";
  if (api.result_get_chunk == NULL) return "duckdb_result_get_chunk";
  if (api.destroy_data_chunk == NULL) return "duckdb_destroy_data_chunk";
  if (api.data_chunk_get_size == NULL) return "duckdb_data_chunk_get_size";
  if (api.data_chunk_get_vector == NULL) return "duckdb_data_chunk_get_vector";
  if (api.vector_get_column_type == NULL) return "duckdb_vector_get_column_type";
  if (api.vector_get_data == NULL) return "duckdb_vector_get_data";
  if (api.vector_get_validity == NULL) return "duckdb_vector_get_validity";
  if (api.list_vector_get_child == NULL) return "duckdb_list_vector_get_child";
  if (api.string_t_length == NULL) return "duckdb_string_t_length";
  if (api.string_t_data == NULL) return "duckdb_string_t_data";
  return NULL;
}

static void ensure_list_result_api(void)
{
  const char *missing = missing_list_result_symbol();
  if (missing != NULL) {
    char message[160];
    snprintf(message, sizeof(message),
             "duckdb list result support unavailable: missing symbol %s", missing);
    caml_failwith(message);
  }
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
  const char *ocaml_path = String_val(v_path);
  char *path = caml_stat_strdup(ocaml_path);
  if (path == NULL) caml_failwith("duckdb allocation failed");
  duckdb_database db = NULL;
  int rc;
  caml_enter_blocking_section();
  rc = api.open(path[0] == '\0' ? NULL : path, &db);
  caml_leave_blocking_section();
  caml_stat_free(path);
  if (rc != 0) caml_failwith("duckdb_open failed");
  v_block = caml_alloc_custom(&db_ops, sizeof(eta_duckdb_db), 0, 1);
  ((eta_duckdb_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim value eta_duckdb_close_database(value v_db)
{
  CAMLparam1(v_db);
  ensure_loaded();
  duckdb_database db = db_val(v_db);
  if (db != NULL) {
    caml_enter_blocking_section();
    api.close(&db);
    caml_leave_blocking_section();
    ((eta_duckdb_db *)Data_custom_val(v_db))->db = db;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_connect(value v_db)
{
  CAMLparam1(v_db);
  CAMLlocal1(v_block);
  ensure_loaded();
  duckdb_connection conn = NULL;
  duckdb_database db = db_val(v_db);
  int rc;
  caml_enter_blocking_section();
  rc = api.connect(db, &conn);
  caml_leave_blocking_section();
  if (rc != 0) caml_failwith("duckdb_connect failed");
  v_block = caml_alloc_custom(&conn_ops, sizeof(eta_duckdb_conn), 0, 1);
  ((eta_duckdb_conn *)Data_custom_val(v_block))->conn = conn;
  CAMLreturn(v_block);
}

CAMLprim value eta_duckdb_disconnect(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  duckdb_connection conn = conn_val(v_conn);
  if (conn != NULL) {
    caml_enter_blocking_section();
    api.disconnect(&conn);
    caml_leave_blocking_section();
    ((eta_duckdb_conn *)Data_custom_val(v_conn))->conn = conn;
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

static value cons(value head, value tail)
{
  CAMLparam2(head, tail);
  CAMLlocal1(cell);
  cell = caml_alloc(2, 0);
  Store_field(cell, 0, head);
  Store_field(cell, 1, tail);
  CAMLreturn(cell);
}

static int vector_type_id(duckdb_vector vector)
{
  duckdb_logical_type logical_type = api.vector_get_column_type(vector);
  int typ = logical_type == NULL ? 0 : api.get_type_id(logical_type);
  if (logical_type != NULL) api.destroy_logical_type(&logical_type);
  return typ;
}

static int vector_row_is_valid(duckdb_vector vector, idx_t row)
{
  uint64_t *validity = api.vector_get_validity(vector);
  if (validity == NULL) return 1;
  return (validity[row / 64] & (1ULL << (row % 64))) != 0;
}

static value make_string_block_len(int tag, const char *s, uint32_t len)
{
  CAMLparam0();
  CAMLlocal2(str, out);
  if (len > 0 && s == NULL) caml_failwith("duckdb string has null data");
  str = caml_alloc_string(len);
  if (len > 0) memcpy(Bytes_val(str), s, len);
  out = make_block(tag, str);
  CAMLreturn(out);
}

static value make_owned_string_block_len(int tag, char *s, idx_t len)
{
  CAMLparam0();
  CAMLlocal3(str, out, owner);
  owner = ptr_owner_alloc();
  if (s != NULL) ptr_owner_set(owner, s);
  if (len > (idx_t)Max_wosize) {
    ptr_owner_release(owner);
    caml_failwith("duckdb string too large for OCaml string");
  }
  if (len > 0 && s == NULL) {
    ptr_owner_release(owner);
    caml_failwith("duckdb string has null data");
  }
  str = caml_alloc_string((mlsize_t)len);
  if (len > 0) memcpy(Bytes_val(str), s, (size_t)len);
  out = make_block(tag, str);
  ptr_owner_release(owner);
  CAMLreturn(out);
}

static value string_value_from_result(duckdb_result *result, idx_t col, idx_t row,
                                      int tag)
{
  duckdb_string s = api.value_string(result, col, row);
  return make_owned_string_block_len(tag, s.data, s.size);
}

static value uuid_value_from_bits(duckdb_uhugeint bits)
{
  CAMLparam0();
  duckdb_value uuid = api.create_uuid(bits);
  char *s;
  if (uuid == NULL) caml_failwith("duckdb uuid conversion failed");
  s = api.get_varchar(uuid);
  api.destroy_value(&uuid);
  if (s == NULL) caml_failwith("duckdb uuid string conversion failed");
  CAMLreturn(make_owned_string_block_len(10, s, (idx_t)strlen(s)));
}

static value value_from_vector(duckdb_vector vector, idx_t row);
static value value_from_result(duckdb_result *result, idx_t col, idx_t row);

static value list_value_from_vector(duckdb_vector vector, idx_t row)
{
  CAMLparam0();
  CAMLlocal3(out, child_value, list_value);
  duckdb_list_entry *entries = (duckdb_list_entry *)api.vector_get_data(vector);
  duckdb_list_entry entry = entries[row];
  duckdb_vector child = api.list_vector_get_child(vector);
  if (entry.length > (uint64_t)Max_long) caml_failwith("duckdb list too large");
  out = Val_emptylist;
  for (uint64_t i = entry.length; i > 0; i--) {
    child_value = value_from_vector(child, (idx_t)(entry.offset + i - 1));
    out = cons(child_value, out);
  }
  list_value = make_block(13, out);
  CAMLreturn(list_value);
}

static value value_from_vector(duckdb_vector vector, idx_t row)
{
  CAMLparam0();
  CAMLlocal2(out, bytes);
  if (!vector_row_is_valid(vector, row)) CAMLreturn(Val_int(0));
  int typ = vector_type_id(vector);
  switch (typ) {
  case ETA_DUCKDB_TYPE_BOOLEAN:
    out = make_block(0, Val_bool(((uint8_t *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_TINYINT:
    out = make_block(1, Val_long(((int8_t *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_SMALLINT:
    out = make_block(1, Val_long(((int16_t *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_INTEGER:
    out = make_block(1, Val_long(((int32_t *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_BIGINT: {
    int64_t v = ((int64_t *)api.vector_get_data(vector))[row];
    if (v >= (int64_t)INT32_MIN && v <= (int64_t)INT32_MAX) {
      out = make_block(1, Val_long((intnat)v));
    } else {
      out = make_block(2, caml_copy_int64(v));
    }
    break;
  }
  case ETA_DUCKDB_TYPE_FLOAT:
    out = make_block(3, caml_copy_double((double)((float *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_DOUBLE:
    out = make_block(3, caml_copy_double(((double *)api.vector_get_data(vector))[row]));
    break;
  case ETA_DUCKDB_TYPE_LIST:
    out = list_value_from_vector(vector, row);
    break;
  case ETA_DUCKDB_TYPE_VARCHAR: {
    duckdb_string_t *strings = (duckdb_string_t *)api.vector_get_data(vector);
    duckdb_string_t *s = &strings[row];
    out = make_string_block_len(4, api.string_t_data(s), api.string_t_length(*s));
    break;
  }
  case ETA_DUCKDB_TYPE_BLOB: {
    duckdb_string_t *strings = (duckdb_string_t *)api.vector_get_data(vector);
    duckdb_string_t *s = &strings[row];
    uint32_t len = api.string_t_length(*s);
    const char *data = api.string_t_data(s);
    if (len > 0 && data == NULL) caml_failwith("duckdb blob has null data");
    bytes = caml_alloc_string(len);
    if (len > 0) memcpy(Bytes_val(bytes), data, len);
    out = make_block(5, bytes);
    break;
  }
  case ETA_DUCKDB_TYPE_UUID: {
    duckdb_uhugeint *values = (duckdb_uhugeint *)api.vector_get_data(vector);
    duckdb_uhugeint bits = values[row];
    bits.upper ^= UINT64_C(0x8000000000000000);
    CAMLreturn(uuid_value_from_bits(bits));
  }
  default: {
    caml_failwith("duckdb unsupported vector result type");
  }
  }
  CAMLreturn(out);
}

static int vector_type_supported_directly(int typ)
{
  switch (typ) {
  case ETA_DUCKDB_TYPE_BOOLEAN:
  case ETA_DUCKDB_TYPE_TINYINT:
  case ETA_DUCKDB_TYPE_SMALLINT:
  case ETA_DUCKDB_TYPE_INTEGER:
  case ETA_DUCKDB_TYPE_BIGINT:
  case ETA_DUCKDB_TYPE_FLOAT:
  case ETA_DUCKDB_TYPE_DOUBLE:
  case ETA_DUCKDB_TYPE_LIST:
  case ETA_DUCKDB_TYPE_UUID:
  case ETA_DUCKDB_TYPE_VARCHAR:
  case ETA_DUCKDB_TYPE_BLOB:
    return 1;
  default:
    return 0;
  }
}

static value value_from_vector_or_result(duckdb_result *result, idx_t col,
                                         idx_t global_row, duckdb_vector vector,
                                         idx_t row)
{
  int typ = vector_type_id(vector);
  if (vector_type_supported_directly(typ)) return value_from_vector(vector, row);
  return value_from_result(result, col, global_row);
}

static value value_from_result(duckdb_result *result, idx_t col, idx_t row)
{
  CAMLparam0();
  CAMLlocal3(out, bytes, owner);
  if (api.value_is_null(result, col, row)) CAMLreturn(Val_int(0));
  int typ = api.column_type(result, col);
  switch (typ) {
  case ETA_DUCKDB_TYPE_BOOLEAN:
    out = make_block(0, Val_bool(api.value_boolean(result, col, row)));
    CAMLreturn(out);
  case ETA_DUCKDB_TYPE_TINYINT:
  case ETA_DUCKDB_TYPE_SMALLINT:
  case ETA_DUCKDB_TYPE_INTEGER:
  case ETA_DUCKDB_TYPE_BIGINT: {
    int64_t v = api.value_int64(result, col, row);
    if (v >= (int64_t)INT32_MIN && v <= (int64_t)INT32_MAX) {
      out = make_block(1, Val_long((intnat)v));
    } else {
      out = make_block(2, caml_copy_int64(v));
    }
    CAMLreturn(out);
  }
  case ETA_DUCKDB_TYPE_FLOAT:
  case ETA_DUCKDB_TYPE_DOUBLE:
    out = make_block(3, caml_copy_double(api.value_double(result, col, row)));
    CAMLreturn(out);
  case ETA_DUCKDB_TYPE_VARCHAR:
    CAMLreturn(string_value_from_result(result, col, row, 4));
  case ETA_DUCKDB_TYPE_BLOB: {
    duckdb_blob blob = api.value_blob(result, col, row);
    owner = ptr_owner_alloc();
    if (blob.data != NULL) ptr_owner_set(owner, blob.data);
    if (blob.size > (idx_t)Max_wosize) {
      ptr_owner_release(owner);
      caml_failwith("duckdb blob too large for OCaml string");
    }
    if (blob.size > 0 && blob.data == NULL) caml_failwith("duckdb blob has null data");
    bytes = caml_alloc_string((mlsize_t)blob.size);
    if (blob.size > 0) memcpy(Bytes_val(bytes), blob.data, (size_t)blob.size);
    ptr_owner_release(owner);
    out = make_block(5, bytes);
    CAMLreturn(out);
  }
  case ETA_DUCKDB_TYPE_LIST:
    caml_failwith("duckdb list result requires chunk materialization");
  case ETA_DUCKDB_TYPE_UUID:
    caml_failwith("duckdb uuid result requires chunk materialization");
  default: {
    int tag = 4;
    if (typ == ETA_DUCKDB_TYPE_DECIMAL) tag = 6;
    else if (typ == ETA_DUCKDB_TYPE_DATE) tag = 7;
    else if (typ == ETA_DUCKDB_TYPE_TIME || typ == ETA_DUCKDB_TYPE_TIME_TZ) tag = 8;
    else if (typ == ETA_DUCKDB_TYPE_TIMESTAMP ||
             typ == ETA_DUCKDB_TYPE_TIMESTAMP_S ||
             typ == ETA_DUCKDB_TYPE_TIMESTAMP_MS ||
             typ == ETA_DUCKDB_TYPE_TIMESTAMP_NS ||
             typ == ETA_DUCKDB_TYPE_TIMESTAMP_TZ)
      tag = 9;
    else if (typ == ETA_DUCKDB_TYPE_ENUM) tag = 12;
    CAMLreturn(string_value_from_result(result, col, row, tag));
  }
  }
}

static value duckdb_column_names(duckdb_result *result, idx_t cols)
{
  CAMLparam0();
  CAMLlocal2(field_names, field_name);
  if (cols > (idx_t)Max_wosize) caml_failwith("duckdb column count too large");
  field_names = caml_alloc((mlsize_t)cols, 0);
  /* caml_copy_string can allocate and run the GC. Tag-0 blocks are scanned, so
     every field must hold a valid OCaml value before the first copy. */
  for (idx_t col_idx = 0; col_idx < cols; col_idx++) {
    Store_field(field_names, (mlsize_t)col_idx, Val_int(0));
  }
  for (idx_t col_idx = 0; col_idx < cols; col_idx++) {
    const char *name = api.column_name(result, col_idx);
    field_name = caml_copy_string(name == NULL ? "" : name);
    caml_modify(&Field(field_names, (mlsize_t)col_idx), field_name);
  }
  CAMLreturn(field_names);
}

static int result_uses_chunk_materialization(duckdb_result *result, idx_t cols)
{
  for (idx_t col_idx = 0; col_idx < cols; col_idx++) {
    int typ = api.column_type(result, col_idx);
    if (typ == ETA_DUCKDB_TYPE_LIST || typ == ETA_DUCKDB_TYPE_UUID) return 1;
  }
  return 0;
}

static value materialize_rows_from_chunks(duckdb_result *result, idx_t cols,
                                          value field_names)
{
  CAMLparam1(field_names);
  CAMLlocal5(rows, row_list, pair, value_v, chunk_owner);
  idx_t chunk_count = api.result_chunk_count(*result);
  idx_t total_rows = api.row_count(result);
  idx_t rows_after = 0;
  rows = Val_emptylist;
  for (idx_t chunk_pos = chunk_count; chunk_pos > 0; chunk_pos--) {
    chunk_owner = data_chunk_owner_alloc();
    duckdb_data_chunk chunk = api.result_get_chunk(*result, chunk_pos - 1);
    if (chunk == NULL) {
      data_chunk_owner_release(chunk_owner);
      continue;
    }
    data_chunk_owner_set(chunk_owner, chunk);
    idx_t count = api.data_chunk_get_size(chunk);
    idx_t chunk_start = total_rows - rows_after - count;
    for (idx_t r = count; r > 0; r--) {
      idx_t row_idx = r - 1;
      idx_t global_row_idx = chunk_start + row_idx;
      row_list = Val_emptylist;
      for (idx_t c = cols; c > 0; c--) {
        idx_t col_idx = c - 1;
        duckdb_vector vector = api.data_chunk_get_vector(chunk, col_idx);
        value_v =
          value_from_vector_or_result(result, col_idx, global_row_idx, vector, row_idx);
        pair = caml_alloc_tuple(2);
        Store_field(pair, 0, Field(field_names, (mlsize_t)col_idx));
        Store_field(pair, 1, value_v);
        row_list = cons(pair, row_list);
      }
      rows = cons(row_list, rows);
    }
    data_chunk_owner_release(chunk_owner);
    rows_after += count;
  }
  CAMLreturn(rows);
}

static value materialize_rows(duckdb_result *result)
{
  CAMLparam0();
  CAMLlocal5(rows, row_list, pair, field_names, value_v);
  idx_t cols = api.column_count(result);
  /* The public query API returns Row.t list, so this path must materialize the
     result. Keep schema-level OCaml values outside the row loop; a streaming
     API should use a separate cursor entrypoint instead of hiding one behind a
     list-returning contract. */
  field_names = duckdb_column_names(result, cols);
  if (result_uses_chunk_materialization(result, cols)) {
    ensure_list_result_api();
    rows = materialize_rows_from_chunks(result, cols, field_names);
    CAMLreturn(rows);
  }
  idx_t count = api.row_count(result);
  rows = Val_emptylist;
  for (idx_t r = count; r > 0; r--) {
    idx_t row_idx = r - 1;
    row_list = Val_emptylist;
    for (idx_t c = cols; c > 0; c--) {
      idx_t col_idx = c - 1;
      value_v = value_from_result(result, col_idx, row_idx);
      pair = caml_alloc_tuple(2);
      Store_field(pair, 0, Field(field_names, (mlsize_t)col_idx));
      Store_field(pair, 1, value_v);
      row_list = cons(pair, row_list);
    }
    rows = cons(row_list, rows);
  }
  CAMLreturn(rows);
}

typedef struct duckdb_input_copy {
  void *data;
  struct duckdb_input_copy *next;
} duckdb_input_copy;

typedef struct {
  duckdb_input_copy *head;
} duckdb_input_copies;

static void duckdb_input_copies_free(duckdb_input_copies *copies)
{
  duckdb_input_copy *cur = copies->head;
  while (cur != NULL) {
    duckdb_input_copy *next = cur->next;
    caml_stat_free(cur->data);
    caml_stat_free(cur);
    cur = next;
  }
  copies->head = NULL;
}

static int duckdb_input_copies_track(duckdb_input_copies *copies, void *data)
{
  duckdb_input_copy *copy = caml_stat_alloc(sizeof(*copy));
  if (copy == NULL) {
    caml_stat_free(data);
    return 0;
  }
  copy->data = data;
  copy->next = copies->head;
  copies->head = copy;
  return 1;
}

static int duckdb_input_copy_string(duckdb_input_copies *copies, const char *source,
                                    const char **out)
{
  char *copy = caml_stat_strdup(source == NULL ? "" : source);
  if (copy == NULL) return 0;
  if (!duckdb_input_copies_track(copies, copy)) return 0;
  *out = copy;
  return 1;
}

static int duckdb_input_copy_bytes(duckdb_input_copies *copies, const void *source,
                                   size_t len, const void **out)
{
  void *copy = caml_stat_alloc(len == 0 ? 1 : len);
  if (copy == NULL) return 0;
  if (len > 0) memcpy(copy, source, len);
  if (!duckdb_input_copies_track(copies, copy)) return 0;
  *out = copy;
  return 1;
}

static int bind_value(duckdb_prepared_statement stmt, idx_t index, value v,
                      duckdb_input_copies *copies)
{
  int rc;
  if (Is_long(v)) {
    caml_enter_blocking_section();
    rc = api.bind_null(stmt, index);
    caml_leave_blocking_section();
    return rc;
  }
  int tag = Tag_val(v);
  switch (tag) {
  case 0: {
    int bool_value = Bool_val(Field(v, 0));
    caml_enter_blocking_section();
    rc = api.bind_boolean(stmt, index, bool_value);
    caml_leave_blocking_section();
    return rc;
  }
  case 1: {
    int64_t int_value = Long_val(Field(v, 0));
    caml_enter_blocking_section();
    rc = api.bind_int64(stmt, index, int_value);
    caml_leave_blocking_section();
    return rc;
  }
  case 2: {
    int64_t int_value = Int64_val(Field(v, 0));
    caml_enter_blocking_section();
    rc = api.bind_int64(stmt, index, int_value);
    caml_leave_blocking_section();
    return rc;
  }
  case 3: {
    double float_value = Double_val(Field(v, 0));
    caml_enter_blocking_section();
    rc = api.bind_double(stmt, index, float_value);
    caml_leave_blocking_section();
    return rc;
  }
  case 4: {
    const char *text;
    if (!duckdb_input_copy_string(copies, String_val(Field(v, 0)), &text)) return -2;
    caml_enter_blocking_section();
    rc = api.bind_varchar(stmt, index, text);
    caml_leave_blocking_section();
    return rc;
  }
  case 5: {
    const void *data;
    value bytes = Field(v, 0);
    size_t len = (size_t)caml_string_length(bytes);
    if (!duckdb_input_copy_bytes(copies, Bytes_val(bytes), len, &data)) return -2;
    caml_enter_blocking_section();
    rc = api.bind_blob(stmt, index, data, (idx_t)len);
    caml_leave_blocking_section();
    return rc;
  }
  case 6:
  case 7:
  case 8:
  case 9:
  case 10:
  case 11:
  case 12: {
    const char *text;
    if (!duckdb_input_copy_string(copies, String_val(Field(v, 0)), &text)) return -2;
    caml_enter_blocking_section();
    rc = api.bind_varchar(stmt, index, text);
    caml_leave_blocking_section();
    return rc;
  }
  default:
    return -1; /* unsupported type; caller reports the error after cleanup */
  }
}

static int bind_params(duckdb_prepared_statement stmt, value params,
                       duckdb_input_copies *copies)
{
  CAMLparam1(params);
  idx_t index = 1;
  while (params != Val_emptylist) {
    int rc = bind_value(stmt, index, Field(params, 0), copies);
    if (rc != 0) CAMLreturnT(int, rc);
    params = Field(params, 1);
    index++;
  }
  CAMLreturnT(int, 0);
}

CAMLprim value eta_duckdb_query(value v_conn, value v_sql, value v_params)
{
  CAMLparam3(v_conn, v_sql, v_params);
  CAMLlocal2(rows, result_owner);
  ensure_loaded();
  duckdb_prepared_statement stmt = NULL;
  duckdb_result result;
  duckdb_input_copies copies = { NULL };
  duckdb_connection conn = conn_val(v_conn);
  const char *sql;
  int rc;
  memset(&result, 0, sizeof(result));
  result_owner = result_owner_alloc();
  if (!duckdb_input_copy_string(&copies, String_val(v_sql), &sql))
    caml_failwith("duckdb allocation failed");
  caml_enter_blocking_section();
  rc = api.prepare(conn, sql, &stmt);
  caml_leave_blocking_section();
  if (rc != 0) {
    const char *err = stmt == NULL ? "prepare failed" : api.prepare_error(stmt);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "prepare failed" : err);
    if (stmt != NULL) api.destroy_prepare(&stmt);
    duckdb_input_copies_free(&copies);
    caml_failwith(buffer);
  }
  rc = bind_params(stmt, v_params, &copies);
  if (rc != 0) {
    api.destroy_prepare(&stmt);
    duckdb_input_copies_free(&copies);
    caml_failwith(rc == -2 ? "duckdb allocation failed" : "duckdb bind failed");
  }
  caml_enter_blocking_section();
  rc = api.execute_prepared(stmt, &result);
  caml_leave_blocking_section();
  api.destroy_prepare(&stmt);
  duckdb_input_copies_free(&copies);
  if (rc != 0) {
    const char *err = api.result_error(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    api.destroy_result(&result);
    caml_failwith(buffer);
  }
  *result_owner_val(result_owner) = result;
  result_owner_activate(result_owner);
  rows = materialize_rows(result_owner_val(result_owner));
  result_owner_destroy(result_owner);
  CAMLreturn(rows);
}

CAMLprim value eta_duckdb_execute(value v_conn, value v_sql, value v_params)
{
  CAMLparam3(v_conn, v_sql, v_params);
  ensure_loaded();
  duckdb_prepared_statement stmt = NULL;
  duckdb_result result;
  duckdb_input_copies copies = { NULL };
  duckdb_connection conn = conn_val(v_conn);
  const char *sql;
  int rc;
  memset(&result, 0, sizeof(result));
  if (!duckdb_input_copy_string(&copies, String_val(v_sql), &sql))
    caml_failwith("duckdb allocation failed");
  caml_enter_blocking_section();
  rc = api.prepare(conn, sql, &stmt);
  caml_leave_blocking_section();
  if (rc != 0) {
    const char *err = stmt == NULL ? "prepare failed" : api.prepare_error(stmt);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "prepare failed" : err);
    if (stmt != NULL) api.destroy_prepare(&stmt);
    duckdb_input_copies_free(&copies);
    caml_failwith(buffer);
  }
  rc = bind_params(stmt, v_params, &copies);
  if (rc != 0) {
    api.destroy_prepare(&stmt);
    duckdb_input_copies_free(&copies);
    caml_failwith(rc == -2 ? "duckdb allocation failed" : "duckdb bind failed");
  }
  caml_enter_blocking_section();
  rc = api.execute_prepared(stmt, &result);
  caml_leave_blocking_section();
  api.destroy_prepare(&stmt);
  duckdb_input_copies_free(&copies);
  if (rc != 0) {
    const char *err = api.result_error(&result);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "execute failed" : err);
    api.destroy_result(&result);
    caml_failwith(buffer);
  }
  idx_t changed = api.rows_changed(&result);
  api.destroy_result(&result);
  if (changed > (idx_t)Max_long) caml_failwith("duckdb changed-row count too large");
  CAMLreturn(Val_long((intnat)changed));
}

CAMLprim value eta_duckdb_exec_script(value v_conn, value v_sql)
{
  CAMLparam2(v_conn, v_sql);
  ensure_loaded();
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  char *sql = caml_stat_strdup(String_val(v_sql));
  if (sql == NULL) caml_failwith("duckdb allocation failed");
  int rc;
  caml_enter_blocking_section();
  rc = api.query(conn_val(v_conn), sql, &result);
  caml_leave_blocking_section();
  caml_stat_free(sql);
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
  duckdb_connection conn = conn_val(v_conn);
  char *schema = NULL;
  char *table = caml_stat_strdup(String_val(v_table));
  int rc;
  if (table == NULL) caml_failwith("duckdb allocation failed");
  if (Is_block(v_schema)) {
    schema = caml_stat_strdup(String_val(Field(v_schema, 0)));
    if (schema == NULL) {
      caml_stat_free(table);
      caml_failwith("duckdb allocation failed");
    }
  }
  caml_enter_blocking_section();
  rc = api.appender_create(conn, schema, table, &appender);
  caml_leave_blocking_section();
  if (schema != NULL) caml_stat_free(schema);
  caml_stat_free(table);
  if (rc != 0) {
    caml_failwith("duckdb_appender_create failed");
  }
  v_block = caml_alloc_custom(&appender_ops, sizeof(eta_duckdb_appender), 0, 1);
  ((eta_duckdb_appender *)Data_custom_val(v_block))->appender = appender;
  CAMLreturn(v_block);
}

static int append_value(duckdb_appender appender, value v, duckdb_input_copies *copies)
{
  int rc = 0;
  if (Is_long(v)) {
    caml_enter_blocking_section();
    rc = api.append_null(appender);
    caml_leave_blocking_section();
    return rc;
  }
  else {
    switch (Tag_val(v)) {
    case 0: {
      int bool_value = Bool_val(Field(v, 0));
      caml_enter_blocking_section();
      rc = api.append_bool(appender, bool_value);
      caml_leave_blocking_section();
      break;
    }
    case 1: {
      int64_t int_value = Long_val(Field(v, 0));
      caml_enter_blocking_section();
      rc = api.append_int64(appender, int_value);
      caml_leave_blocking_section();
      break;
    }
    case 2: {
      int64_t int_value = Int64_val(Field(v, 0));
      caml_enter_blocking_section();
      rc = api.append_int64(appender, int_value);
      caml_leave_blocking_section();
      break;
    }
    case 3: {
      double float_value = Double_val(Field(v, 0));
      caml_enter_blocking_section();
      rc = api.append_double(appender, float_value);
      caml_leave_blocking_section();
      break;
    }
    case 4: {
      const char *text;
      if (!duckdb_input_copy_string(copies, String_val(Field(v, 0)), &text)) return -2;
      caml_enter_blocking_section();
      rc = api.append_varchar(appender, text);
      caml_leave_blocking_section();
      break;
    }
    case 5: {
      const void *data;
      value bytes = Field(v, 0);
      size_t len = (size_t)caml_string_length(bytes);
      if (!duckdb_input_copy_bytes(copies, Bytes_val(bytes), len, &data)) return -2;
      caml_enter_blocking_section();
      rc = api.append_blob(appender, data, (idx_t)len);
      caml_leave_blocking_section();
      break;
    }
    case 6:
    case 7:
    case 8:
    case 9:
    case 10:
    case 11:
    case 12: {
      const char *text;
      if (!duckdb_input_copy_string(copies, String_val(Field(v, 0)), &text)) return -2;
      caml_enter_blocking_section();
      rc = api.append_varchar(appender, text);
      caml_leave_blocking_section();
      break;
    }
    default:
      return -3;
    }
  }
  return rc;
}

CAMLprim value eta_duckdb_appender_append_row(value v_appender, value values)
{
  CAMLparam2(v_appender, values);
  ensure_loaded();
  eta_duckdb_appender *appender_block =
    (eta_duckdb_appender *)Data_custom_val(v_appender);
  duckdb_appender appender = appender_block->appender;
  duckdb_input_copies copies = { NULL };
  int rc;
  if (appender == NULL) caml_failwith("duckdb appender is closed");
  while (values != Val_emptylist) {
    rc = append_value(appender, Field(values, 0), &copies);
    if (rc != 0) {
      duckdb_input_copies_free(&copies);
      appender_destroy_blocking(appender_block);
      if (rc == -2) caml_failwith("duckdb allocation failed");
      if (rc == -3) caml_failwith("cannot append DuckDB list or struct values");
      caml_failwith("duckdb append value failed");
    }
    values = Field(values, 1);
  }
  caml_enter_blocking_section();
  rc = api.appender_end_row(appender);
  caml_leave_blocking_section();
  duckdb_input_copies_free(&copies);
  if (rc != 0) {
    appender_destroy_blocking(appender_block);
    caml_failwith("duckdb_appender_end_row failed");
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_appender_flush(value v_appender)
{
  CAMLparam1(v_appender);
  ensure_loaded();
  eta_duckdb_appender *appender_block =
    (eta_duckdb_appender *)Data_custom_val(v_appender);
  duckdb_appender appender = appender_block->appender;
  if (appender == NULL) caml_failwith("duckdb appender is closed");
  int rc;
  caml_enter_blocking_section();
  rc = api.appender_flush(appender);
  caml_leave_blocking_section();
  if (rc != 0) {
    appender_destroy_blocking(appender_block);
    caml_failwith("duckdb_appender_flush failed");
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_duckdb_appender_close(value v_appender)
{
  CAMLparam1(v_appender);
  ensure_loaded();
  eta_duckdb_appender *appender = (eta_duckdb_appender *)Data_custom_val(v_appender);
  if (appender->appender != NULL) {
    int rc;
    rc = appender_close_destroy_blocking(appender);
    if (rc != 0) caml_failwith("duckdb_appender_close failed");
  }
  CAMLreturn(Val_unit);
}
