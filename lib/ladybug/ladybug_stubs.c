#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
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

typedef struct eta_ladybug_conn_state {
  lbug_connection conn;
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  int mutex_initialized;
  int cond_initialized;
  int active;
  int closing;
} eta_ladybug_conn_state;

typedef struct {
  eta_ladybug_conn_state *state;
} eta_ladybug_conn;

typedef struct {
  struct ArrowSchema schema;
  struct ArrowArray array;
  bool schema_active;
  bool array_active;
} arrow_release_owner;

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
static pthread_mutex_t api_mutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_int fail_next_result_owner_alloc = 0;

CAMLprim value eta_ladybug_test_fail_next_result_owner_alloc(value v_unit)
{
  CAMLparam1(v_unit);
  (void)v_unit;
  atomic_store_explicit(&fail_next_result_owner_alloc, 1, memory_order_relaxed);
  CAMLreturn(Val_unit);
}

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
  eta_ladybug_conn *slot = (eta_ladybug_conn *)Data_custom_val(v_conn);
  eta_ladybug_conn_state *conn = slot->state;
  lbug_connection native;
  native.ptr = NULL;
  if (conn == NULL) return;
  slot->state = NULL;
  if (conn->mutex_initialized) {
    pthread_mutex_lock(&conn->mutex);
    if (conn->conn.ptr != NULL) {
      native = conn->conn;
      conn->conn.ptr = NULL;
    }
    pthread_mutex_unlock(&conn->mutex);
  } else if (conn->conn.ptr != NULL) {
    native = conn->conn;
    conn->conn.ptr = NULL;
  }
  if (native.ptr != NULL && api.loaded) api.connection_destroy(&native);
  if (conn->mutex_initialized) {
    if (conn->cond_initialized) {
      pthread_cond_destroy(&conn->cond);
      conn->cond_initialized = 0;
    }
    pthread_mutex_destroy(&conn->mutex);
    conn->mutex_initialized = 0;
  }
  free(conn);
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

static arrow_release_owner *arrow_owner_val(value v)
{
  return (arrow_release_owner *)Data_custom_val(v);
}

static void arrow_owner_release_array(arrow_release_owner *owner)
{
  if (owner->array_active) {
    void (*release)(struct ArrowArray *) = owner->array.release;
    owner->array_active = false;
    if (release != NULL) release(&owner->array);
    memset(&owner->array, 0, sizeof(owner->array));
  }
}

static void arrow_owner_release_schema(arrow_release_owner *owner)
{
  if (owner->schema_active) {
    void (*release)(struct ArrowSchema *) = owner->schema.release;
    owner->schema_active = false;
    if (release != NULL) release(&owner->schema);
    memset(&owner->schema, 0, sizeof(owner->schema));
  }
}

static void arrow_owner_finalize(value v_owner)
{
  arrow_release_owner *owner = arrow_owner_val(v_owner);
  arrow_owner_release_array(owner);
  arrow_owner_release_schema(owner);
}

static struct custom_operations arrow_owner_ops = {
  "eta.ladybug.arrow_release_owner", arrow_owner_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static value arrow_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  arrow_release_owner *owner;
  v_owner = caml_alloc_custom(&arrow_owner_ops, sizeof(arrow_release_owner), 0, 1);
  owner = arrow_owner_val(v_owner);
  memset(owner, 0, sizeof(*owner));
  CAMLreturn(v_owner);
}

static void arrow_owner_set_schema(arrow_release_owner *owner)
{
  owner->schema_active = owner->schema.release != NULL;
}

static void arrow_owner_set_array(arrow_release_owner *owner)
{
  owner->array_active = owner->array.release != NULL;
}

/* Owns an [lbug_query_result] in a finalized custom block. Query execution
   fills a stack result, which is then moved here before any OCaml allocation
   can raise (Arrow validation in materialize_arrow_rows, result_to_string, or
   Out_of_memory). If control leaves abnormally via caml_failwith's longjmp,
   the orphaned block's finalizer destroys the result instead of leaking it.
   Mirrors the DuckDB connector's result_owner.

   Ownership invariant (validated against the original cleanup paths): a
   successful connection_query / connection_execute (LbugSuccess) yields a
   result that owns foreign memory and must be destroyed, *independently* of
   query_result_is_success — a query that failed semantically still produces an
   owned result. Hence the owner is activated before the is_success check, and
   the is_success-false path destroys through the owner.

   The owner is allocated before query execution, so Out_of_memory cannot occur
   after a successful native query but before ownership transfer.

   Regression test: test/ladybug_leak (drives a materialize failure through a
   mock liblbug and asserts every created query result is destroyed, including
   owner-allocation fault injection). */
typedef struct {
  lbug_query_result result;
  bool active;
} eta_ladybug_result_owner;

static eta_ladybug_result_owner *result_owner_val(value v_owner)
{
  return (eta_ladybug_result_owner *)Data_custom_val(v_owner);
}

static void result_owner_finalize(value v_owner)
{
  eta_ladybug_result_owner *owner = result_owner_val(v_owner);
  if (owner->active && api.loaded) {
    api.query_result_destroy(&owner->result);
    owner->active = false;
  }
}

static struct custom_operations result_owner_ops = {
  "eta.ladybug.result_owner", result_owner_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static value result_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  eta_ladybug_result_owner *owner;
  if (atomic_exchange_explicit(&fail_next_result_owner_alloc, 0,
                               memory_order_relaxed) != 0) {
    caml_raise_out_of_memory();
  }
  v_owner = caml_alloc_custom(&result_owner_ops, sizeof(eta_ladybug_result_owner), 0, 1);
  owner = result_owner_val(v_owner);
  memset(&owner->result, 0, sizeof(owner->result));
  owner->active = false;
  CAMLreturn(v_owner);
}

static lbug_query_result *result_owner_result(value v_owner)
{
  return &result_owner_val(v_owner)->result;
}

static void result_owner_activate(value v_owner)
{
  result_owner_val(v_owner)->active = true;
}

static void result_owner_take(value v_owner, lbug_query_result *result)
{
  *result_owner_result(v_owner) = *result;
  result->ptr = NULL;
  result->owned = false;
  result_owner_activate(v_owner);
}

static void result_owner_destroy(value v_owner)
{
  eta_ladybug_result_owner *owner = result_owner_val(v_owner);
  if (owner->active) {
    api.query_result_destroy(&owner->result);
    owner->active = false;
  }
}

typedef struct {
  char *ptr;
} eta_ladybug_string_owner;

static eta_ladybug_string_owner *ladybug_string_owner_val(value v_owner)
{
  return (eta_ladybug_string_owner *)Data_custom_val(v_owner);
}

static void ladybug_string_owner_finalize(value v_owner)
{
  eta_ladybug_string_owner *owner = ladybug_string_owner_val(v_owner);
  if (owner->ptr != NULL && api.loaded) {
    api.destroy_string(owner->ptr);
    owner->ptr = NULL;
  }
}

static struct custom_operations ladybug_string_owner_ops = {
  "eta.ladybug.string_owner", ladybug_string_owner_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static value ladybug_string_owner_alloc(void)
{
  CAMLparam0();
  CAMLlocal1(v_owner);
  eta_ladybug_string_owner *owner;
  v_owner = caml_alloc_custom(&ladybug_string_owner_ops, sizeof(eta_ladybug_string_owner), 0, 1);
  owner = ladybug_string_owner_val(v_owner);
  owner->ptr = NULL;
  CAMLreturn(v_owner);
}

static void ladybug_string_owner_set(value v_owner, char *ptr)
{
  ladybug_string_owner_val(v_owner)->ptr = ptr;
}

static void ladybug_string_owner_release(value v_owner)
{
  eta_ladybug_string_owner *owner = ladybug_string_owner_val(v_owner);
  if (owner->ptr != NULL) {
    char *ptr = owner->ptr;
    owner->ptr = NULL;
    api.destroy_string(ptr);
  }
}

static lbug_database *db_val(value v) { return &((eta_ladybug_db *)Data_custom_val(v))->db; }

static eta_ladybug_conn_state *conn_state_val(value v_conn)
{
  eta_ladybug_conn *slot = (eta_ladybug_conn *)Data_custom_val(v_conn);
  return slot->state;
}

static int conn_acquire(value v_conn, lbug_connection *out)
{
  eta_ladybug_conn_state *slot = conn_state_val(v_conn);
  int acquired = 0;
  if (slot == NULL) return 0;
  pthread_mutex_lock(&slot->mutex);
  if (!slot->closing && slot->conn.ptr != NULL) {
    *out = slot->conn;
    slot->active++;
    acquired = 1;
  }
  pthread_mutex_unlock(&slot->mutex);
  return acquired;
}

static void conn_release(value v_conn)
{
  eta_ladybug_conn_state *slot = conn_state_val(v_conn);
  if (slot == NULL) return;
  pthread_mutex_lock(&slot->mutex);
  if (slot->active > 0) {
    slot->active--;
    if (slot->active == 0 && slot->cond_initialized)
      pthread_cond_broadcast(&slot->cond);
  }
  pthread_mutex_unlock(&slot->mutex);
}

static void conn_close_state_blocking(eta_ladybug_conn_state *slot)
{
  lbug_connection conn;
  conn.ptr = NULL;
  if (slot == NULL) return;
  caml_enter_blocking_section();
  pthread_mutex_lock(&slot->mutex);
  while (slot->closing && slot->conn.ptr != NULL && slot->cond_initialized)
    pthread_cond_wait(&slot->cond, &slot->mutex);
  if (slot->conn.ptr != NULL) {
    slot->closing = 1;
    while (slot->active > 0 && slot->cond_initialized)
      pthread_cond_wait(&slot->cond, &slot->mutex);
    conn = slot->conn;
    slot->conn.ptr = NULL;
    slot->closing = 0;
    if (slot->cond_initialized) pthread_cond_broadcast(&slot->cond);
  }
  pthread_mutex_unlock(&slot->mutex);
  if (conn.ptr != NULL) api.connection_destroy(&conn);
  caml_leave_blocking_section();
}

static void fail_connection_closed(void)
{
  caml_failwith("LadybugDB connection is closed");
}

static void conn_init(value v_conn, lbug_connection conn)
{
  eta_ladybug_conn *slot = (eta_ladybug_conn *)Data_custom_val(v_conn);
  eta_ladybug_conn_state *state = malloc(sizeof(eta_ladybug_conn_state));
  slot->state = NULL;
  if (state == NULL) {
    api.connection_destroy(&conn);
    caml_failwith("ladybug connect: state allocation failed");
  }
  state->conn = conn;
  state->mutex_initialized = 0;
  state->cond_initialized = 0;
  state->active = 0;
  state->closing = 0;
  if (pthread_mutex_init(&state->mutex, NULL) != 0) {
    api.connection_destroy(&state->conn);
    state->conn.ptr = NULL;
    free(state);
    caml_failwith("ladybug connect: mutex init failed");
  }
  state->mutex_initialized = 1;
  if (pthread_cond_init(&state->cond, NULL) != 0) {
    pthread_mutex_destroy(&state->mutex);
    state->mutex_initialized = 0;
    api.connection_destroy(&state->conn);
    state->conn.ptr = NULL;
    free(state);
    caml_failwith("ladybug connect: condition init failed");
  }
  state->cond_initialized = 1;
  slot->state = state;
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

#define LOAD(name) load_symbol((void **)&api.name, "lbug_" #name)

static int load_api_unlocked(void)
{
  if (api.loaded) return 1;
  if (api.attempted) return 0;
  api.attempted = 1;

  const char *env = getenv("ETA_LADYBUG_LIBRARY");
  const char *candidates[] = { env, "liblbug.so", "libladybug.so", "liblbug.dylib", NULL };
  size_t candidate_count = sizeof(candidates) / sizeof(candidates[0]);
  for (size_t i = 0; i < candidate_count; i++) {
    if (candidates[i] == NULL || candidates[i][0] == '\0') continue;
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

typedef struct string_copy {
  char *value;
  struct string_copy *next;
} string_copy;

typedef struct {
  string_copy *head;
} string_copies;

static void string_copies_free(string_copies *copies)
{
  string_copy *cur = copies->head;
  while (cur != NULL) {
    string_copy *next = cur->next;
    caml_stat_free(cur->value);
    free(cur);
    cur = next;
  }
  copies->head = NULL;
}

static int string_copies_add(string_copies *copies, const char *source, const char **out)
{
  char *copy = caml_stat_strdup(source == NULL ? "" : source);
  string_copy *node;
  if (copy == NULL) return 0;
  node = malloc(sizeof(*node));
  if (node == NULL) {
    caml_stat_free(copy);
    return 0;
  }
  node->value = copy;
  node->next = copies->head;
  copies->head = node;
  *out = copy;
  return 1;
}

static void fail_last_with_copies(const char *operation, string_copies *copies)
{
  char *err = api.get_last_error();
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", operation, err == NULL ? "unknown" : err);
  if (err != NULL) api.destroy_string(err);
  string_copies_free(copies);
  caml_failwith(buffer);
}

static lbug_value *create_lbug_value(value v, string_copies *copies);

static void destroy_lbug_values(lbug_value **values, uint64_t count)
{
  if (values == NULL) return;
  for (uint64_t i = 0; i < count; i++) {
    if (values[i] != NULL) api.value_destroy(values[i]);
  }
  free(values);
}

static lbug_value *create_lbug_list(value values, string_copies *copies)
{
  uint64_t count = 0;
  for (value cur = values; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  lbug_value **items = calloc((size_t)count, sizeof(lbug_value *));
  if (items == NULL) return NULL;
  uint64_t i = 0;
  for (value cur = values; cur != Val_emptylist; cur = Field(cur, 1)) {
    items[i] = create_lbug_value(Field(cur, 0), copies);
    if (items[i] == NULL) {
      destroy_lbug_values(items, i);
      return NULL;
    }
    i++;
  }
  lbug_value *list = NULL;
  if (api.value_create_list(count, items, &list) != LbugSuccess) {
    destroy_lbug_values(items, count);
    return NULL;
  }
  destroy_lbug_values(items, count);
  return list;
}

static lbug_value *create_lbug_map(value fields, string_copies *copies)
{
  uint64_t count = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  lbug_value **keys = calloc((size_t)count, sizeof(lbug_value *));
  lbug_value **vals = calloc((size_t)count, sizeof(lbug_value *));
  if (keys == NULL || vals == NULL) {
    free(keys);
    free(vals);
    return NULL;
  }
  uint64_t i = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) {
    value pair = Field(cur, 0);
    const char *key;
    if (!string_copies_add(copies, String_val(Field(pair, 0)), &key)) {
      destroy_lbug_values(keys, i);
      destroy_lbug_values(vals, i);
      return NULL;
    }
    keys[i] = api.value_create_string(key);
    vals[i] = create_lbug_value(Field(pair, 1), copies);
    if (keys[i] == NULL || vals[i] == NULL) {
      /* calloc leaves missing slots NULL, so include the partially-filled index
         to release whichever side succeeded before destroying both arrays. */
      destroy_lbug_values(keys, i + 1);
      destroy_lbug_values(vals, i + 1);
      return NULL;
    }
    i++;
  }
  lbug_value *map = NULL;
  if (api.value_create_map(count, keys, vals, &map) != LbugSuccess) {
    destroy_lbug_values(keys, count);
    destroy_lbug_values(vals, count);
    return NULL;
  }
  destroy_lbug_values(keys, count);
  destroy_lbug_values(vals, count);
  return map;
}

static lbug_value *create_lbug_struct(value fields, string_copies *copies)
{
  uint64_t count = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) count++;
  const char **names = calloc((size_t)count, sizeof(char *));
  lbug_value **vals = calloc((size_t)count, sizeof(lbug_value *));
  if (names == NULL || vals == NULL) {
    free(names);
    free(vals);
    return NULL;
  }
  uint64_t i = 0;
  for (value cur = fields; cur != Val_emptylist; cur = Field(cur, 1)) {
    value pair = Field(cur, 0);
    if (!string_copies_add(copies, String_val(Field(pair, 0)), &names[i])) {
      destroy_lbug_values(vals, i);
      free(names);
      return NULL;
    }
    vals[i] = create_lbug_value(Field(pair, 1), copies);
    if (vals[i] == NULL) {
      destroy_lbug_values(vals, i);
      free(names);
      return NULL;
    }
    i++;
  }
  lbug_value *struct_ = NULL;
  if (api.value_create_struct(count, names, vals, &struct_) != LbugSuccess) {
    free(names);
    destroy_lbug_values(vals, count);
    return NULL;
  }
  free(names);
  destroy_lbug_values(vals, count);
  return struct_;
}

static lbug_value *create_lbug_value(value v, string_copies *copies)
{
  if (Is_long(v)) return api.value_create_null();
  switch (Tag_val(v)) {
  case 0:
    return api.value_create_bool(Bool_val(Field(v, 0)));
  case 1:
    return api.value_create_int64(Int64_val(Field(v, 0)));
  case 2:
    return api.value_create_double(Double_val(Field(v, 0)));
  case 3: {
    const char *text;
    if (!string_copies_add(copies, String_val(Field(v, 0)), &text)) return NULL;
    return api.value_create_string(text);
  }
  case 4:
    return create_lbug_list(Field(v, 0), copies);
  case 5:
    return create_lbug_map(Field(v, 0), copies);
  case 6:
    return create_lbug_struct(Field(v, 0), copies);
  default:
    return NULL; /* unsupported type; caller handles the error */
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
  conn_init(v_block, conn);
  CAMLreturn(v_block);
}

CAMLprim value eta_ladybug_close_connection(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  eta_ladybug_conn_state *state = conn_state_val(v_conn);
  conn_close_state_blocking(state);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_ladybug_interrupt(value v_conn)
{
  CAMLparam1(v_conn);
  ensure_loaded();
  eta_ladybug_conn_state *slot = conn_state_val(v_conn);
  if (slot == NULL) CAMLreturn(Val_unit);
  pthread_mutex_lock(&slot->mutex);
  lbug_connection conn = slot->conn;
  if (conn.ptr != NULL) api.connection_interrupt(&conn);
  pthread_mutex_unlock(&slot->mutex);
  CAMLreturn(Val_unit);
}

static int bind_param(lbug_prepared_statement *stmt, value pair, string_copies *copies)
{
  const char *name;
  value v = Field(pair, 1);
  lbug_state state = LbugError;
  if (!string_copies_add(copies, String_val(Field(pair, 0)), &name)) return -2;
  if (Is_long(v)) {
    lbug_value *null_value = api.value_create_null();
    state = api.prepared_statement_bind_value(stmt, name, null_value);
    if (null_value != NULL) api.value_destroy(null_value);
  } else {
    switch (Tag_val(v)) {
    case 0: state = api.prepared_statement_bind_bool(stmt, name, Bool_val(Field(v, 0))); break;
    case 1: state = api.prepared_statement_bind_int64(stmt, name, Int64_val(Field(v, 0))); break;
    case 2: state = api.prepared_statement_bind_double(stmt, name, Double_val(Field(v, 0))); break;
    case 3: {
      const char *text;
      if (!string_copies_add(copies, String_val(Field(v, 0)), &text)) return -2;
      state = api.prepared_statement_bind_string(stmt, name, text);
      break;
    }
    case 4:
    case 5:
    case 6: {
      lbug_value *nested = create_lbug_value(v, copies);
      if (nested == NULL) return -2; /* create_lbug_value failed */
      state = api.prepared_statement_bind_value(stmt, name, nested);
      api.value_destroy(nested);
      break;
    }
    default: return -1; /* unsupported type */
    }
  }
  if (state != LbugSuccess) return -1;
  return 0;
}

static value result_to_string(lbug_query_result *result)
{
  CAMLparam0();
  CAMLlocal2(out, owner);
  char *s;
  owner = ladybug_string_owner_alloc();
  s = api.query_result_to_string(result);
  ladybug_string_owner_set(owner, s);
  out = caml_copy_string(s == NULL ? "" : s);
  ladybug_string_owner_release(owner);
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
  if (array == NULL || row < 0 || row >= array->length) caml_failwith("ladybug: malformed Arrow array");
  if (array->null_count == 0 || array->buffers == NULL || array->buffers[0] == NULL) return 1;
  const uint8_t *bits = (const uint8_t *)array->buffers[0];
  int64_t bit = array->offset + row;
  return (bits[bit / 8] >> (bit % 8)) & 1;
}

static void require_arrow_buffers(struct ArrowArray *array, int64_t count)
{
  if (array == NULL || array->n_buffers < count || array->buffers == NULL) {
    caml_failwith("ladybug: malformed Arrow buffers");
  }
  for (int64_t i = 1; i < count; i++) {
    if (array->buffers[i] == NULL) caml_failwith("ladybug: malformed Arrow buffers");
  }
}

static int64_t arrow_i64(struct ArrowArray *array, int64_t row)
{
  require_arrow_buffers(array, 2);
  const int64_t *values = (const int64_t *)array->buffers[1];
  return values[array->offset + row];
}

static double arrow_f64(struct ArrowArray *array, int64_t row)
{
  require_arrow_buffers(array, 2);
  const double *values = (const double *)array->buffers[1];
  return values[array->offset + row];
}

static int arrow_bool(struct ArrowArray *array, int64_t row)
{
  require_arrow_buffers(array, 2);
  const uint8_t *bits = (const uint8_t *)array->buffers[1];
  int64_t bit = array->offset + row;
  return (bits[bit / 8] >> (bit % 8)) & 1;
}

static value arrow_string(struct ArrowArray *array, int64_t row)
{
  CAMLparam0();
  CAMLlocal1(out);
  require_arrow_buffers(array, 3);
  int64_t logical = array->offset + row;
  const int32_t *offsets = (const int32_t *)array->buffers[1];
  const char *bytes = (const char *)array->buffers[2];
  int32_t start = offsets[logical];
  int32_t end = offsets[logical + 1];
  int32_t len = end - start;
  if (end < start || len < 0) caml_failwith("ladybug: malformed Arrow string offsets");
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
  if (schema == NULL || array == NULL || schema->n_children < 0 ||
      array->n_children < schema->n_children || schema->children == NULL ||
      array->children == NULL) {
    caml_failwith("ladybug: malformed Arrow struct");
  }
  props = Val_emptylist;
  for (int64_t i = schema->n_children; i > 0; i--) {
    int64_t idx = i - 1;
    if (schema->children[idx] == NULL || array->children[idx] == NULL) {
      caml_failwith("ladybug: malformed Arrow struct child");
    }
    const char *name = schema->children[idx]->name;
    if (skip_graph_fields && name != NULL &&
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
  if (schema == NULL || schema->n_children < 0 || schema->children == NULL) return -1;
  for (int64_t i = 0; i < schema->n_children; i++) {
    if (schema->children[i] != NULL && schema->children[i]->name != NULL && strcmp(schema->children[i]->name, name) == 0) {
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
  if (schema == NULL || array == NULL) caml_failwith("ladybug: malformed Arrow value");
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

static value arrow_field_names(struct ArrowSchema *schema)
{
  CAMLparam0();
  CAMLlocal2(field_names, field_name);
  if (schema == NULL || schema->n_children < 0 || schema->children == NULL) {
    caml_failwith("ladybug: malformed Arrow schema");
  }
  if (schema->n_children > (int64_t)Max_wosize)
    caml_failwith("ladybug: too many Arrow fields");
  field_names = caml_alloc((mlsize_t)schema->n_children, 0);
  /* caml_copy_string can allocate and run the GC. Tag-0 blocks are scanned, so
     every field must hold a valid OCaml value before the first copy. */
  for (int64_t col_idx = 0; col_idx < schema->n_children; col_idx++) {
    Store_field(field_names, (mlsize_t)col_idx, Val_int(0));
  }
  for (int64_t col_idx = 0; col_idx < schema->n_children; col_idx++) {
    if (schema->children[col_idx] == NULL) {
      caml_failwith("ladybug: malformed Arrow schema child");
    }
    field_name = caml_copy_string(schema->children[col_idx]->name == NULL ? "" : schema->children[col_idx]->name);
    caml_modify(&Field(field_names, (mlsize_t)col_idx), field_name);
  }
  CAMLreturn(field_names);
}

static value materialize_arrow_rows(lbug_query_result *result)
{
  CAMLparam0();
  CAMLlocal5(rows, row_list, pair, value_v, field_names);
  CAMLlocal1(v_owner);
  arrow_release_owner *owner;
  v_owner = arrow_owner_alloc();
  owner = arrow_owner_val(v_owner);
  /* OCaml allocations below may raise while Arrow resources are live. Keep
     the current schema/chunk in a custom block so its finalizer releases them
     if control leaves before the normal release path. The [result] itself is
     owned by the caller's result_owner, so this function only needs to protect
     the Arrow schema/chunk it borrows. */
  if (api.query_result_get_arrow_schema(result, &owner->schema) != LbugSuccess)
    fail_last("get_arrow_schema");
  arrow_owner_set_schema(owner);
  /* The public query API returns Row.t list, so this path must materialize the
     result. Keep schema-level OCaml values outside the row loop; a streaming
     API should use a separate cursor entrypoint instead of hiding one behind a
     list-returning contract. */
  field_names = arrow_field_names(&owner->schema);
  rows = Val_emptylist;
  for (;;) {
    memset(&owner->array, 0, sizeof(owner->array));
    if (api.query_result_get_next_arrow_chunk(result, 1024, &owner->array) != LbugSuccess) {
      arrow_owner_set_array(owner);
      arrow_owner_release_array(owner);
      arrow_owner_release_schema(owner);
      fail_last("get_next_arrow_chunk");
    }
    arrow_owner_set_array(owner);
    if (owner->array.release == NULL || owner->array.length == 0) {
      arrow_owner_release_array(owner);
      break;
    }
    for (int64_t row_idx = 0; row_idx < owner->array.length; row_idx++) {
      row_list = Val_emptylist;
      for (int64_t c = owner->schema.n_children; c > 0; c--) {
        int64_t col_idx = c - 1;
        value_v = arrow_value(owner->schema.children[col_idx], owner->array.children[col_idx], row_idx);
        pair = caml_alloc_tuple(2);
        Store_field(pair, 0, Field(field_names, (mlsize_t)col_idx));
        Store_field(pair, 1, value_v);
        row_list = cons(pair, row_list);
      }
      rows = cons(row_list, rows);
    }
    arrow_owner_release_array(owner);
  }
  arrow_owner_release_schema(owner);
  CAMLreturn(list_rev(rows));
}

static value execute_direct(value v_conn, value v_cypher)
{
  CAMLparam2(v_conn, v_cypher);
  CAMLlocal2(out, result_owner);
  lbug_connection conn;
  lbug_query_result result;
  result.ptr = NULL;
  result.owned = false;
  result_owner = result_owner_alloc();
  char *cypher_copy = caml_stat_strdup(String_val(v_cypher));
  if (cypher_copy == NULL) caml_failwith("LadybugDB allocation failed");
  lbug_state state;
  if (!conn_acquire(v_conn, &conn)) {
    caml_stat_free(cypher_copy);
    fail_connection_closed();
  }
  caml_enter_blocking_section();
  state = api.connection_query(&conn, cypher_copy, &result);
  caml_leave_blocking_section();
  conn_release(v_conn);
  caml_stat_free(cypher_copy);
  if (state != LbugSuccess) fail_last("connection_query");
  result_owner_take(result_owner, &result);
  if (!api.query_result_is_success(result_owner_result(result_owner))) {
    char *err = api.query_result_get_error_message(result_owner_result(result_owner));
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    result_owner_destroy(result_owner);
    caml_failwith(buffer);
  }
  out = result_to_string(result_owner_result(result_owner));
  result_owner_destroy(result_owner);
  CAMLreturn(out);
}

static value execute_prepared(value v_conn, value v_cypher, value params)
{
  CAMLparam3(v_conn, v_cypher, params);
  CAMLlocal2(out, result_owner);
  lbug_connection conn;
  lbug_prepared_statement stmt;
  lbug_query_result result;
  string_copies copies = { NULL };
  const char *cypher_copy;
  lbug_state state;
  stmt.ptr = NULL;
  stmt.bound_values = NULL;
  result.ptr = NULL;
  result.owned = false;
  result_owner = result_owner_alloc();
  if (!string_copies_add(&copies, String_val(v_cypher), &cypher_copy))
    caml_failwith("LadybugDB allocation failed");
  if (!conn_acquire(v_conn, &conn)) {
    string_copies_free(&copies);
    fail_connection_closed();
  }
  if (api.connection_prepare(&conn, cypher_copy, &stmt) != LbugSuccess) {
    conn_release(v_conn);
    fail_last_with_copies("prepare", &copies);
  }
  if (!api.prepared_statement_is_success(&stmt)) {
    char *err = api.prepared_statement_get_error_message(&stmt);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "prepare failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.prepared_statement_destroy(&stmt);
    string_copies_free(&copies);
    conn_release(v_conn);
    caml_failwith(buffer);
  }
  while (params != Val_emptylist) {
    if (bind_param(&stmt, Field(params, 0), &copies) != 0) {
      api.prepared_statement_destroy(&stmt);
      string_copies_free(&copies);
      conn_release(v_conn);
      caml_failwith("LadybugDB bind failed");
    }
    params = Field(params, 1);
  }
  caml_enter_blocking_section();
  state = api.connection_execute(&conn, &stmt, &result);
  caml_leave_blocking_section();
  if (state != LbugSuccess) {
    api.prepared_statement_destroy(&stmt);
    conn_release(v_conn);
    fail_last_with_copies("execute", &copies);
  }
  /* The query result is self-contained, so release the statement and input
     copies now — before any OCaml allocation below can raise — leaving the
     result as the only foreign resource that needs exception-safe cleanup. */
  api.prepared_statement_destroy(&stmt);
  string_copies_free(&copies);
  conn_release(v_conn);
  result_owner_take(result_owner, &result);
  if (!api.query_result_is_success(result_owner_result(result_owner))) {
    char *err = api.query_result_get_error_message(result_owner_result(result_owner));
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    result_owner_destroy(result_owner);
    caml_failwith(buffer);
  }
  out = result_to_string(result_owner_result(result_owner));
  result_owner_destroy(result_owner);
  CAMLreturn(out);
}

CAMLprim value eta_ladybug_query_string(value v_conn, value v_cypher, value v_params)
{
  CAMLparam3(v_conn, v_cypher, v_params);
  ensure_loaded();
  if (v_params == Val_emptylist) CAMLreturn(execute_direct(v_conn, v_cypher));
  CAMLreturn(execute_prepared(v_conn, v_cypher, v_params));
}

static value execute_direct_values(value v_conn, value v_cypher)
{
  CAMLparam2(v_conn, v_cypher);
  CAMLlocal2(out, result_owner);
  lbug_connection conn;
  lbug_query_result result;
  result.ptr = NULL;
  result.owned = false;
  result_owner = result_owner_alloc();
  char *cypher_copy = caml_stat_strdup(String_val(v_cypher));
  if (cypher_copy == NULL) caml_failwith("LadybugDB allocation failed");
  lbug_state state;
  if (!conn_acquire(v_conn, &conn)) {
    caml_stat_free(cypher_copy);
    fail_connection_closed();
  }
  caml_enter_blocking_section();
  state = api.connection_query(&conn, cypher_copy, &result);
  caml_leave_blocking_section();
  conn_release(v_conn);
  caml_stat_free(cypher_copy);
  if (state != LbugSuccess) fail_last("connection_query");
  result_owner_take(result_owner, &result);
  if (!api.query_result_is_success(result_owner_result(result_owner))) {
    char *err = api.query_result_get_error_message(result_owner_result(result_owner));
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    result_owner_destroy(result_owner);
    caml_failwith(buffer);
  }
  out = materialize_arrow_rows(result_owner_result(result_owner));
  result_owner_destroy(result_owner);
  CAMLreturn(out);
}

static value execute_prepared_values(value v_conn, value v_cypher, value params)
{
  CAMLparam3(v_conn, v_cypher, params);
  CAMLlocal2(out, result_owner);
  lbug_connection conn;
  lbug_prepared_statement stmt;
  lbug_query_result result;
  string_copies copies = { NULL };
  const char *cypher_copy;
  lbug_state state;
  stmt.ptr = NULL;
  stmt.bound_values = NULL;
  result.ptr = NULL;
  result.owned = false;
  result_owner = result_owner_alloc();
  if (!string_copies_add(&copies, String_val(v_cypher), &cypher_copy))
    caml_failwith("LadybugDB allocation failed");
  if (!conn_acquire(v_conn, &conn)) {
    string_copies_free(&copies);
    fail_connection_closed();
  }
  if (api.connection_prepare(&conn, cypher_copy, &stmt) != LbugSuccess) {
    conn_release(v_conn);
    fail_last_with_copies("prepare", &copies);
  }
  if (!api.prepared_statement_is_success(&stmt)) {
    char *err = api.prepared_statement_get_error_message(&stmt);
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "prepare failed" : err);
    if (err != NULL) api.destroy_string(err);
    api.prepared_statement_destroy(&stmt);
    string_copies_free(&copies);
    conn_release(v_conn);
    caml_failwith(buffer);
  }
  while (params != Val_emptylist) {
    if (bind_param(&stmt, Field(params, 0), &copies) != 0) {
      api.prepared_statement_destroy(&stmt);
      string_copies_free(&copies);
      conn_release(v_conn);
      caml_failwith("LadybugDB bind failed");
    }
    params = Field(params, 1);
  }
  caml_enter_blocking_section();
  state = api.connection_execute(&conn, &stmt, &result);
  caml_leave_blocking_section();
  if (state != LbugSuccess) {
    api.prepared_statement_destroy(&stmt);
    conn_release(v_conn);
    fail_last_with_copies("execute", &copies);
  }
  /* The query result is self-contained, so release the statement and input
     copies now — before any OCaml allocation below can raise — leaving the
     result as the only foreign resource that needs exception-safe cleanup. */
  api.prepared_statement_destroy(&stmt);
  string_copies_free(&copies);
  conn_release(v_conn);
  result_owner_take(result_owner, &result);
  if (!api.query_result_is_success(result_owner_result(result_owner))) {
    char *err = api.query_result_get_error_message(result_owner_result(result_owner));
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", err == NULL ? "query failed" : err);
    if (err != NULL) api.destroy_string(err);
    result_owner_destroy(result_owner);
    caml_failwith(buffer);
  }
  out = materialize_arrow_rows(result_owner_result(result_owner));
  result_owner_destroy(result_owner);
  CAMLreturn(out);
}

CAMLprim value eta_ladybug_query_values(value v_conn, value v_cypher, value v_params)
{
  CAMLparam3(v_conn, v_cypher, v_params);
  ensure_loaded();
  if (v_params == Val_emptylist) CAMLreturn(execute_direct_values(v_conn, v_cypher));
  CAMLreturn(execute_prepared_values(v_conn, v_cypher, v_params));
}
