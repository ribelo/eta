#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SQLITE_OK 0
#define SQLITE_MISUSE 21
#define SQLITE_TOOBIG 18
#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_URI 0x00000040
#define SQLITE_TRANSIENT ((void (*)(void *))-1)

#ifndef __has_feature
#define __has_feature(x) 0
#endif

#if defined(__SANITIZE_ADDRESS__) || defined(__SANITIZE_THREAD__) ||          \
    __has_feature(address_sanitizer) || __has_feature(memory_sanitizer) ||    \
    __has_feature(thread_sanitizer)
#define ETA_TURSO_SANITIZER_BUILD 1
#else
#define ETA_TURSO_SANITIZER_BUILD 0
#endif

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

typedef struct { sqlite3 *db; } eta_turso_db;
typedef struct { sqlite3_stmt *stmt; } eta_turso_stmt;

typedef struct {
  void *handle;
  char error[512];
  int attempted;
  int loaded;
  int (*open_v2)(const char *, sqlite3 **, int, const char *);
  int (*close_v2)(sqlite3 *);
  int (*prepare_v2)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
  int (*finalize)(sqlite3_stmt *);
  int (*step)(sqlite3_stmt *);
  int (*bind_null)(sqlite3_stmt *, int);
  int (*bind_int64)(sqlite3_stmt *, int, int64_t);
  int (*bind_double)(sqlite3_stmt *, int, double);
  int (*bind_text)(sqlite3_stmt *, int, const char *, int, void (*)(void *));
  int (*bind_blob)(sqlite3_stmt *, int, const void *, int, void (*)(void *));
  int (*column_count)(sqlite3_stmt *);
  const char *(*column_name)(sqlite3_stmt *, int);
  int (*column_type)(sqlite3_stmt *, int);
  int64_t (*column_int64)(sqlite3_stmt *, int);
  double (*column_double)(sqlite3_stmt *, int);
  const unsigned char *(*column_text)(sqlite3_stmt *, int);
  const void *(*column_blob)(sqlite3_stmt *, int);
  int (*column_bytes)(sqlite3_stmt *, int);
  int (*changes)(sqlite3 *);
  int (*busy_timeout)(sqlite3 *, int);
  int (*errcode)(sqlite3 *);
  int (*extended_errcode)(sqlite3 *);
  const char *(*errmsg)(sqlite3 *);
} eta_turso_api;

static eta_turso_api api;
static pthread_mutex_t api_mutex = PTHREAD_MUTEX_INITIALIZER;

static void eta_turso_db_finalize(value v_db)
{
  eta_turso_db *db = (eta_turso_db *)Data_custom_val(v_db);
  if (db->db != NULL && api.loaded) {
    /* OCaml custom finalizers cannot safely enter blocking sections; explicit
       close/finalize functions below release the runtime lock. */
    (void)api.close_v2(db->db);
    db->db = NULL;
  }
}

static void eta_turso_stmt_finalize(value v_stmt)
{
  eta_turso_stmt *stmt = (eta_turso_stmt *)Data_custom_val(v_stmt);
  if (stmt->stmt != NULL && api.loaded) {
    /* See eta_turso_db_finalize for finalizer constraints. */
    (void)api.finalize(stmt->stmt);
    stmt->stmt = NULL;
  }
}

static struct custom_operations eta_turso_db_ops = {
  "eta.turso.db",
  eta_turso_db_finalize,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations eta_turso_stmt_ops = {
  "eta.turso.stmt",
  eta_turso_stmt_finalize,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static sqlite3 *db_val(value v_db) { return ((eta_turso_db *)Data_custom_val(v_db))->db; }
static sqlite3_stmt *stmt_val(value v_stmt) { return ((eta_turso_stmt *)Data_custom_val(v_stmt))->stmt; }

static void fail_closed_handle(const char *operation)
{
  char buffer[128];
  snprintf(buffer, sizeof(buffer), "%s: closed handle", operation);
  caml_failwith(buffer);
}

static sqlite3 *require_db(value v_db, const char *operation)
{
  sqlite3 *db = db_val(v_db);
  if (db == NULL) fail_closed_handle(operation);
  return db;
}

static sqlite3_stmt *require_stmt(value v_stmt, const char *operation)
{
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  if (stmt == NULL) fail_closed_handle(operation);
  return stmt;
}

static int ocaml_string_len_as_sqlite_int(value v_string, int *len_out)
{
  mlsize_t len = caml_string_length(v_string);
  if (len > (mlsize_t)INT_MAX) {
    return SQLITE_TOOBIG;
  }
  *len_out = (int)len;
  return SQLITE_OK;
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

#define LOAD(name) load_symbol((void **)&api.name, "sqlite3_" #name)

static int eta_turso_load_unlocked(void)
{
  if (api.loaded) return 1;
  if (api.attempted) return 0;
  api.attempted = 1;

  const char *env = getenv("ETA_TURSO_LIBRARY");
  const char *candidates[] = { env, "libturso_sqlite3.so", "libturso_sqlite3.so.0", "libturso_sqlite3.dylib", NULL };

  int dlopen_flags = RTLD_NOW | RTLD_LOCAL;
#if defined(RTLD_DEEPBIND) && !ETA_TURSO_SANITIZER_BUILD
  dlopen_flags |= RTLD_DEEPBIND;
#endif

  size_t candidate_count = sizeof(candidates) / sizeof(candidates[0]);
  for (size_t i = 0; i < candidate_count; i++) {
    if (candidates[i] == NULL || candidates[i][0] == '\0') continue;
    api.handle = dlopen(candidates[i], dlopen_flags);
    if (api.handle != NULL) break;
  }

  if (api.handle == NULL) {
    const char *err = dlerror();
    snprintf(api.error, sizeof(api.error), "%s", err == NULL ? "could not load libturso_sqlite3" : err);
    return 0;
  }

  if (!LOAD(open_v2) || !LOAD(close_v2) || !LOAD(prepare_v2) ||
      !LOAD(finalize) || !LOAD(step) || !LOAD(bind_null) ||
      !LOAD(bind_int64) || !LOAD(bind_double) || !LOAD(bind_text) ||
      !LOAD(bind_blob) || !LOAD(column_count) || !LOAD(column_name) ||
      !LOAD(column_type) || !LOAD(column_int64) || !LOAD(column_double) ||
      !LOAD(column_text) || !LOAD(column_blob) || !LOAD(column_bytes) ||
      !LOAD(changes) || !LOAD(busy_timeout) || !LOAD(errcode) ||
      !LOAD(extended_errcode) || !LOAD(errmsg)) {
    return 0;
  }

  api.loaded = 1;
  return 1;
}

static int eta_turso_load(void)
{
  int loaded;
  pthread_mutex_lock(&api_mutex);
  loaded = eta_turso_load_unlocked();
  pthread_mutex_unlock(&api_mutex);
  return loaded;
}

static void ensure_loaded(void)
{
  if (!eta_turso_load()) caml_failwith(api.error);
}

static int flags_of_mode(intnat mode)
{
  switch (mode) {
  case 0: return SQLITE_OPEN_READONLY | SQLITE_OPEN_URI;
  case 1: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI;
  default: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI;
  }
}

CAMLprim value eta_turso_available(value v_unit)
{
  CAMLparam1(v_unit);
  CAMLlocal2(some, message);
  if (eta_turso_load()) CAMLreturn(Val_none);
  message = caml_copy_string(api.error);
  some = caml_alloc(1, 0);
  Store_field(some, 0, message);
  CAMLreturn(some);
}

CAMLprim value eta_turso_open(value v_path, intnat mode)
{
  CAMLparam1(v_path);
  CAMLlocal1(v_block);
  ensure_loaded();
  sqlite3 *db = NULL;
  int rc;
  v_block = caml_alloc_custom(&eta_turso_db_ops, sizeof(eta_turso_db), 0, 1);
  ((eta_turso_db *)Data_custom_val(v_block))->db = NULL;
  char *path = strdup(String_val(v_path));
  if (path == NULL) caml_failwith("allocating Turso database path failed");
  caml_enter_blocking_section();
  rc = api.open_v2(path, &db, flags_of_mode(mode), NULL);
  caml_leave_blocking_section();
  free(path);
  if (rc != SQLITE_OK) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "sqlite3_open_v2 rc=%d: %s", rc, db == NULL ? "no handle" : api.errmsg(db));
    if (db != NULL) (void)api.close_v2(db);
    caml_failwith(buffer);
  }
  ((eta_turso_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim value eta_turso_open_bc(value v_path, value v_mode) { return eta_turso_open(v_path, Int_val(v_mode)); }

CAMLprim intnat eta_turso_close(value v_db)
{
  CAMLparam1(v_db);
  ensure_loaded();
  eta_turso_db *db = (eta_turso_db *)Data_custom_val(v_db);
  int rc;
  if (db->db == NULL) CAMLreturnT(intnat, SQLITE_OK);
  caml_enter_blocking_section();
  rc = api.close_v2(db->db);
  caml_leave_blocking_section();
  if (rc == SQLITE_OK) db->db = NULL;
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_turso_close_bc(value v_db) { return Val_int(eta_turso_close(v_db)); }

CAMLprim value eta_turso_prepare(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  CAMLlocal1(v_block);
  ensure_loaded();
  sqlite3 *db = db_val(v_db);
  if (db == NULL) caml_failwith("sqlite3_prepare_v2 rc=21: closed database");
  sqlite3_stmt *stmt = NULL;
  char *sql;
  int rc;
  v_block = caml_alloc_custom(&eta_turso_stmt_ops, sizeof(eta_turso_stmt), 0, 1);
  ((eta_turso_stmt *)Data_custom_val(v_block))->stmt = NULL;
  sql = caml_stat_strdup(String_val(v_sql));
  if (sql == NULL) caml_failwith("turso allocation failed");
  /* prepare_v2 may touch disk or extension state. Copy the OCaml string before
     releasing the runtime lock because String_val is not stable in a blocking
     section. */
  caml_enter_blocking_section();
  rc = api.prepare_v2(db, sql, -1, &stmt, NULL);
  caml_leave_blocking_section();
  caml_stat_free(sql);
  if (rc != SQLITE_OK) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "sqlite3_prepare_v2 rc=%d: %s", rc, db == NULL ? "closed" : api.errmsg(db));
    caml_failwith(buffer);
  }
  ((eta_turso_stmt *)Data_custom_val(v_block))->stmt = stmt;
  CAMLreturn(v_block);
}

CAMLprim intnat eta_turso_finalize(value v_stmt)
{
  CAMLparam1(v_stmt);
  ensure_loaded();
  eta_turso_stmt *stmt = (eta_turso_stmt *)Data_custom_val(v_stmt);
  int rc;
  if (stmt->stmt == NULL) CAMLreturnT(intnat, SQLITE_OK);
  caml_enter_blocking_section();
  rc = api.finalize(stmt->stmt);
  caml_leave_blocking_section();
  if (rc == SQLITE_OK) stmt->stmt = NULL;
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_turso_finalize_bc(value v_stmt) { return Val_int(eta_turso_finalize(v_stmt)); }

CAMLprim intnat eta_turso_step(value v_stmt)
{
  CAMLparam1(v_stmt);
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) CAMLreturnT(intnat, SQLITE_MISUSE);
  caml_enter_blocking_section();
  rc = api.step(stmt);
  caml_leave_blocking_section();
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_turso_step_bc(value v_stmt) { return Val_int(eta_turso_step(v_stmt)); }

CAMLprim intnat eta_turso_bind_null(value v_stmt, intnat index)
{
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  return stmt == NULL ? SQLITE_MISUSE : api.bind_null(stmt, (int)index);
}

CAMLprim value eta_turso_bind_null_bc(value v_stmt, value v_index) { return Val_int(eta_turso_bind_null(v_stmt, Int_val(v_index))); }

CAMLprim intnat eta_turso_bind_int64(value v_stmt, intnat index, int64_t value)
{
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  return stmt == NULL ? SQLITE_MISUSE : api.bind_int64(stmt, (int)index, value);
}

CAMLprim value eta_turso_bind_int64_bc(value v_stmt, value v_index, value v_value) { return Val_int(eta_turso_bind_int64(v_stmt, Int_val(v_index), Int64_val(v_value))); }

CAMLprim intnat eta_turso_bind_double(value v_stmt, intnat index, double value)
{
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  return stmt == NULL ? SQLITE_MISUSE : api.bind_double(stmt, (int)index, value);
}

CAMLprim value eta_turso_bind_double_bc(value v_stmt, value v_index, value v_value) { return Val_int(eta_turso_bind_double(v_stmt, Int_val(v_index), Double_val(v_value))); }

CAMLprim intnat eta_turso_bind_text(value v_stmt, intnat index, value v_value)
{
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int len;
  int rc;
  if (stmt == NULL) return SQLITE_MISUSE;
  rc = ocaml_string_len_as_sqlite_int(v_value, &len);
  if (rc != SQLITE_OK) return rc;
  return api.bind_text(stmt, (int)index, String_val(v_value), len,
      SQLITE_TRANSIENT);
}

CAMLprim value eta_turso_bind_text_bc(value v_stmt, value v_index, value v_value) { return Val_int(eta_turso_bind_text(v_stmt, Int_val(v_index), v_value)); }

CAMLprim intnat eta_turso_bind_blob(value v_stmt, intnat index, value v_value)
{
  ensure_loaded();
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int len;
  int rc;
  if (stmt == NULL) return SQLITE_MISUSE;
  rc = ocaml_string_len_as_sqlite_int(v_value, &len);
  if (rc != SQLITE_OK) return rc;
  return api.bind_blob(stmt, (int)index, Bytes_val(v_value), len,
      SQLITE_TRANSIENT);
}

CAMLprim value eta_turso_bind_blob_bc(value v_stmt, value v_index, value v_value) { return Val_int(eta_turso_bind_blob(v_stmt, Int_val(v_index), v_value)); }

CAMLprim intnat eta_turso_column_count(value v_stmt)
{
  ensure_loaded();
  return api.column_count(require_stmt(v_stmt, "sqlite3_column_count"));
}

CAMLprim value eta_turso_column_count_bc(value v_stmt) { return Val_int(eta_turso_column_count(v_stmt)); }

CAMLprim value eta_turso_column_name(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  ensure_loaded();
  const char *name = api.column_name(require_stmt(v_stmt, "sqlite3_column_name"), (int)index);
  CAMLreturn(caml_copy_string(name == NULL ? "" : name));
}

CAMLprim value eta_turso_column_name_bc(value v_stmt, value v_index) { return eta_turso_column_name(v_stmt, Int_val(v_index)); }

CAMLprim intnat eta_turso_column_type(value v_stmt, intnat index)
{
  ensure_loaded();
  return api.column_type(require_stmt(v_stmt, "sqlite3_column_type"), (int)index);
}

CAMLprim value eta_turso_column_type_bc(value v_stmt, value v_index) { return Val_int(eta_turso_column_type(v_stmt, Int_val(v_index))); }

CAMLprim int64_t eta_turso_column_int64(value v_stmt, intnat index)
{
  ensure_loaded();
  return api.column_int64(require_stmt(v_stmt, "sqlite3_column_int64"),
      (int)index);
}

CAMLprim value eta_turso_column_int64_bc(value v_stmt, value v_index) { return caml_copy_int64(eta_turso_column_int64(v_stmt, Int_val(v_index))); }

CAMLprim double eta_turso_column_double(value v_stmt, intnat index)
{
  ensure_loaded();
  return api.column_double(require_stmt(v_stmt, "sqlite3_column_double"),
      (int)index);
}

CAMLprim value eta_turso_column_double_bc(value v_stmt, value v_index) { return caml_copy_double(eta_turso_column_double(v_stmt, Int_val(v_index))); }

CAMLprim value eta_turso_column_text(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  ensure_loaded();
  sqlite3_stmt *stmt = require_stmt(v_stmt, "sqlite3_column_text");
  const unsigned char *text = api.column_text(stmt, (int)index);
  int len = api.column_bytes(stmt, (int)index);
  if (len < 0) caml_failwith("turso column_text: negative length");
  /* SQLite permits NULL for SQL NULL and zero-length values only. A positive
     byte count with a NULL pointer is a driver contract violation. */
  if (len > 0 && text == NULL) caml_failwith("turso column_text: null pointer for non-empty value");
  CAMLreturn(caml_alloc_initialized_string(len, len == 0 ? "" : (const char *)text));
}

CAMLprim value eta_turso_column_text_bc(value v_stmt, value v_index) { return eta_turso_column_text(v_stmt, Int_val(v_index)); }

CAMLprim value eta_turso_column_blob(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  ensure_loaded();
  sqlite3_stmt *stmt = require_stmt(v_stmt, "sqlite3_column_blob");
  const void *blob = api.column_blob(stmt, (int)index);
  int len = api.column_bytes(stmt, (int)index);
  if (len < 0) caml_failwith("turso column_blob: negative length");
  if (len > 0 && blob == NULL) caml_failwith("turso column_blob: null pointer for non-empty value");
  CAMLreturn(caml_alloc_initialized_string(len, len == 0 ? "" : (const char *)blob));
}

CAMLprim value eta_turso_column_blob_bc(value v_stmt, value v_index) { return eta_turso_column_blob(v_stmt, Int_val(v_index)); }

CAMLprim intnat eta_turso_changes(value v_db)
{
  ensure_loaded();
  return api.changes(require_db(v_db, "sqlite3_changes"));
}

CAMLprim value eta_turso_changes_bc(value v_db) { return Val_int(eta_turso_changes(v_db)); }

CAMLprim intnat eta_turso_busy_timeout(value v_db, intnat ms)
{
  ensure_loaded();
  sqlite3 *db = db_val(v_db);
  return db == NULL ? SQLITE_MISUSE : api.busy_timeout(db, (int)ms);
}

CAMLprim value eta_turso_busy_timeout_bc(value v_db, value v_ms) { return Val_int(eta_turso_busy_timeout(v_db, Int_val(v_ms))); }
CAMLprim intnat eta_turso_errcode(value v_db) { ensure_loaded(); sqlite3 *db = db_val(v_db); return db == NULL ? SQLITE_MISUSE : api.errcode(db); }
CAMLprim value eta_turso_errcode_bc(value v_db) { return Val_int(eta_turso_errcode(v_db)); }
CAMLprim intnat eta_turso_extended_errcode(value v_db) { ensure_loaded(); sqlite3 *db = db_val(v_db); return db == NULL ? SQLITE_MISUSE : api.extended_errcode(db); }
CAMLprim value eta_turso_extended_errcode_bc(value v_db) { return Val_int(eta_turso_extended_errcode(v_db)); }

CAMLprim value eta_turso_errmsg(value v_db)
{
  CAMLparam1(v_db);
  ensure_loaded();
  sqlite3 *db = db_val(v_db);
  CAMLreturn(caml_copy_string(db == NULL ? "closed database" : api.errmsg(db)));
}
