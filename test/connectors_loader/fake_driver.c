#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t idx_t;
typedef uintptr_t ocaml_value;
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

static const idx_t duckdb_fake_rows = 128;

static void mutate_first_char(const char *value)
{
  if (value != NULL && value[0] != '\0') ((char *)value)[0] = '!';
}

static void mutate_first_byte(const void *data, idx_t size)
{
  if (data != NULL && size > 0) ((unsigned char *)data)[0] = '!';
}

const char *duckdb_library_version(void) { return "fake-duckdb"; }

int duckdb_open(const char *path, duckdb_database *out)
{
  (void)path;
  *out = malloc(1);
  return *out == NULL ? 1 : 0;
}

void duckdb_close(duckdb_database *db)
{
  if (db != NULL && *db != NULL) {
    free(*db);
    *db = NULL;
  }
}

int duckdb_connect(duckdb_database db, duckdb_connection *out)
{
  (void)db;
  *out = malloc(1);
  return *out == NULL ? 1 : 0;
}

void duckdb_disconnect(duckdb_connection *conn)
{
  if (conn != NULL && *conn != NULL) {
    free(*conn);
    *conn = NULL;
  }
}

int duckdb_query(duckdb_connection conn, const char *sql, duckdb_result *result)
{
  (void)conn;
  (void)sql;
  (void)result;
  return 0;
}

void duckdb_destroy_result(duckdb_result *result) { (void)result; }
const char *duckdb_result_error(duckdb_result *result) { (void)result; return "fake error"; }
idx_t duckdb_column_count(duckdb_result *result) { (void)result; return 1; }
idx_t duckdb_row_count(duckdb_result *result) { (void)result; return duckdb_fake_rows; }
const char *duckdb_column_name(duckdb_result *result, idx_t col) { (void)result; (void)col; return "payload"; }
int duckdb_column_type(duckdb_result *result, idx_t col) { (void)result; (void)col; return 18; }
int duckdb_value_is_null(duckdb_result *result, idx_t col, idx_t row) { (void)result; (void)col; (void)row; return 0; }
int duckdb_value_boolean(duckdb_result *result, idx_t col, idx_t row) { (void)result; (void)col; (void)row; return 0; }
int64_t duckdb_value_int64(duckdb_result *result, idx_t col, idx_t row) { (void)result; (void)col; (void)row; return 0; }
double duckdb_value_double(duckdb_result *result, idx_t col, idx_t row) { (void)result; (void)col; (void)row; return 0.0; }
char *duckdb_value_varchar(duckdb_result *result, idx_t col, idx_t row)
{
  (void)result;
  (void)col;
  (void)row;
  return NULL;
}

duckdb_blob duckdb_value_blob(duckdb_result *result, idx_t col, idx_t row)
{
  (void)result;
  (void)col;
  char buffer[32];
  int len = snprintf(buffer, sizeof(buffer), "blob-row-%03llu",
                     (unsigned long long)row);
  char *data = malloc((size_t)len);
  memcpy(data, buffer, (size_t)len);
  return (duckdb_blob){ data, (idx_t)len };
}

void duckdb_free(void *ptr)
{
  typedef ocaml_value (*gc_fn)(ocaml_value);
  typedef ocaml_value (*alloc_string_fn)(uintptr_t);
  gc_fn full_major = (gc_fn)dlsym(RTLD_DEFAULT, "caml_gc_full_major");
  alloc_string_fn alloc_string =
      (alloc_string_fn)dlsym(RTLD_DEFAULT, "caml_alloc_string");
  if (full_major != NULL) (void)full_major(1);
  if (alloc_string != NULL) {
    for (int i = 0; i < 4096; i++) {
      ocaml_value value = alloc_string(16);
      memset((void *)value, 0x5a, 16);
    }
  }
  free(ptr);
}

int duckdb_prepare(duckdb_connection conn, const char *sql, duckdb_prepared_statement *out)
{
  (void)conn;
  mutate_first_char(sql);
  *out = malloc(1);
  return *out == NULL ? 1 : 0;
}

const char *duckdb_prepare_error(duckdb_prepared_statement stmt) { (void)stmt; return "fake prepare error"; }
void duckdb_destroy_prepare(duckdb_prepared_statement *stmt)
{
  if (stmt != NULL && *stmt != NULL) {
    free(*stmt);
    *stmt = NULL;
  }
}

int duckdb_bind_null(duckdb_prepared_statement stmt, idx_t index) { (void)stmt; (void)index; return 0; }
int duckdb_bind_boolean(duckdb_prepared_statement stmt, idx_t index, int value) { (void)stmt; (void)index; (void)value; return 0; }
int duckdb_bind_int64(duckdb_prepared_statement stmt, idx_t index, int64_t value) { (void)stmt; (void)index; (void)value; return 0; }
int duckdb_bind_double(duckdb_prepared_statement stmt, idx_t index, double value) { (void)stmt; (void)index; (void)value; return 0; }
int duckdb_bind_varchar(duckdb_prepared_statement stmt, idx_t index, const char *value) { (void)stmt; (void)index; mutate_first_char(value); return 0; }
int duckdb_bind_blob(duckdb_prepared_statement stmt, idx_t index, const void *data, idx_t size) { (void)stmt; (void)index; mutate_first_byte(data, size); return 0; }
int duckdb_execute_prepared(duckdb_prepared_statement stmt, duckdb_result *result) { (void)stmt; (void)result; return 0; }
int duckdb_appender_create(duckdb_connection conn, const char *schema, const char *table, duckdb_appender *out) { (void)conn; mutate_first_char(schema); mutate_first_char(table); *out = malloc(1); return *out == NULL ? 1 : 0; }
int duckdb_appender_flush(duckdb_appender appender) { (void)appender; return 0; }
int duckdb_appender_close(duckdb_appender appender) { (void)appender; return 0; }
int duckdb_appender_destroy(duckdb_appender *appender) { if (appender != NULL && *appender != NULL) { free(*appender); *appender = NULL; } return 0; }
int duckdb_append_bool(duckdb_appender appender, int value) { (void)appender; (void)value; return 0; }
int duckdb_append_int64(duckdb_appender appender, int64_t value) { (void)appender; (void)value; return 0; }
int duckdb_append_double(duckdb_appender appender, double value) { (void)appender; (void)value; return 0; }
int duckdb_append_varchar(duckdb_appender appender, const char *value) { (void)appender; mutate_first_char(value); return 0; }
int duckdb_append_blob(duckdb_appender appender, const void *data, idx_t size) { (void)appender; mutate_first_byte(data, size); return 0; }
int duckdb_append_null(duckdb_appender appender) { (void)appender; return 0; }
int duckdb_appender_end_row(duckdb_appender appender) { (void)appender; return 0; }
void duckdb_interrupt(duckdb_connection conn) { (void)conn; }

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
} lbug_system_config;

typedef struct {
  bool success;
  char *text;
} fake_lbug_result;

typedef struct {
  bool success;
} fake_lbug_stmt;

static char *fake_strdup(const char *value)
{
  size_t len = strlen(value == NULL ? "" : value);
  char *copy = malloc(len + 1);
  if (copy == NULL) return NULL;
  memcpy(copy, value == NULL ? "" : value, len + 1);
  return copy;
}

const char *lbug_get_version(void) { return "fake-ladybug"; }
char *lbug_get_last_error(void) { return fake_strdup("fake ladybug error"); }
void lbug_destroy_string(char *value) { free(value); }
lbug_system_config lbug_default_system_config(void)
{
  lbug_system_config config;
  memset(&config, 0, sizeof(config));
  return config;
}
int lbug_database_init(const char *path, lbug_system_config config, lbug_database *out)
{
  (void)path;
  (void)config;
  out->ptr = malloc(1);
  return out->ptr == NULL ? LbugError : LbugSuccess;
}
void lbug_database_destroy(lbug_database *db)
{
  if (db != NULL && db->ptr != NULL) {
    free(db->ptr);
    db->ptr = NULL;
  }
}
int lbug_connection_init(lbug_database *db, lbug_connection *out)
{
  (void)db;
  out->ptr = malloc(1);
  return out->ptr == NULL ? LbugError : LbugSuccess;
}
void lbug_connection_destroy(lbug_connection *conn)
{
  if (conn != NULL && conn->ptr != NULL) {
    free(conn->ptr);
    conn->ptr = NULL;
  }
}
int lbug_connection_query(lbug_connection *conn, const char *cypher, lbug_query_result *out)
{
  (void)conn;
  (void)cypher;
  fake_lbug_result *result = malloc(sizeof(*result));
  if (result == NULL) return LbugError;
  result->success = true;
  result->text = fake_strdup("fake direct");
  out->ptr = result;
  out->owned = true;
  return LbugSuccess;
}
void lbug_connection_interrupt(lbug_connection *conn) { (void)conn; }
bool lbug_query_result_is_success(lbug_query_result *result)
{
  return result != NULL && result->ptr != NULL
         && ((fake_lbug_result *)result->ptr)->success;
}
char *lbug_query_result_get_error_message(lbug_query_result *result)
{
  (void)result;
  return fake_strdup("fake query failed");
}
char *lbug_query_result_to_string(lbug_query_result *result)
{
  fake_lbug_result *fake = result == NULL ? NULL : result->ptr;
  return fake_strdup(fake == NULL ? "" : fake->text);
}
int lbug_query_result_get_arrow_schema(lbug_query_result *result, void *schema)
{
  (void)result;
  (void)schema;
  return LbugError;
}
int lbug_query_result_get_next_arrow_chunk(lbug_query_result *result, int64_t rows,
                                           void *array)
{
  (void)result;
  (void)rows;
  (void)array;
  return LbugError;
}
void lbug_query_result_destroy(lbug_query_result *result)
{
  if (result != NULL && result->ptr != NULL) {
    fake_lbug_result *fake = result->ptr;
    free(fake->text);
    free(fake);
    result->ptr = NULL;
  }
}
int lbug_connection_prepare(lbug_connection *conn, const char *cypher,
                            lbug_prepared_statement *out)
{
  (void)conn;
  fake_lbug_stmt *stmt = malloc(sizeof(*stmt));
  if (stmt == NULL) return LbugError;
  stmt->success = true;
  mutate_first_char(cypher);
  out->ptr = stmt;
  out->bound_values = NULL;
  return LbugSuccess;
}
bool lbug_prepared_statement_is_success(lbug_prepared_statement *stmt)
{
  return stmt != NULL && stmt->ptr != NULL && ((fake_lbug_stmt *)stmt->ptr)->success;
}
char *lbug_prepared_statement_get_error_message(lbug_prepared_statement *stmt)
{
  (void)stmt;
  return fake_strdup("fake prepare failed");
}
void lbug_prepared_statement_destroy(lbug_prepared_statement *stmt)
{
  if (stmt != NULL && stmt->ptr != NULL) {
    free(stmt->ptr);
    stmt->ptr = NULL;
  }
}
int lbug_prepared_statement_bind_string(lbug_prepared_statement *stmt,
                                        const char *name, const char *value)
{
  (void)stmt;
  mutate_first_char(name);
  mutate_first_char(value);
  return LbugSuccess;
}
int lbug_prepared_statement_bind_int64(lbug_prepared_statement *stmt,
                                       const char *name, int64_t value)
{
  (void)stmt;
  (void)value;
  mutate_first_char(name);
  return LbugSuccess;
}
int lbug_prepared_statement_bind_double(lbug_prepared_statement *stmt,
                                        const char *name, double value)
{
  (void)stmt;
  (void)value;
  mutate_first_char(name);
  return LbugSuccess;
}
int lbug_prepared_statement_bind_bool(lbug_prepared_statement *stmt,
                                      const char *name, bool value)
{
  (void)stmt;
  (void)value;
  mutate_first_char(name);
  return LbugSuccess;
}
lbug_value *lbug_value_create_null(void) { return calloc(1, sizeof(lbug_value)); }
lbug_value *lbug_value_create_bool(bool value) { (void)value; return calloc(1, sizeof(lbug_value)); }
lbug_value *lbug_value_create_int64(int64_t value) { (void)value; return calloc(1, sizeof(lbug_value)); }
lbug_value *lbug_value_create_double(double value) { (void)value; return calloc(1, sizeof(lbug_value)); }
lbug_value *lbug_value_create_string(const char *value)
{
  mutate_first_char(value);
  return calloc(1, sizeof(lbug_value));
}
int lbug_value_create_list(uint64_t count, lbug_value **values, lbug_value **out)
{
  (void)count;
  (void)values;
  *out = calloc(1, sizeof(lbug_value));
  return *out == NULL ? LbugError : LbugSuccess;
}
int lbug_value_create_map(uint64_t count, lbug_value **keys, lbug_value **values,
                          lbug_value **out)
{
  (void)count;
  (void)keys;
  (void)values;
  *out = calloc(1, sizeof(lbug_value));
  return *out == NULL ? LbugError : LbugSuccess;
}
int lbug_value_create_struct(uint64_t count, const char **names, lbug_value **values,
                             lbug_value **out)
{
  (void)count;
  if (names != NULL) mutate_first_char(names[0]);
  (void)values;
  *out = calloc(1, sizeof(lbug_value));
  return *out == NULL ? LbugError : LbugSuccess;
}
void lbug_value_destroy(lbug_value *value) { free(value); }
int lbug_prepared_statement_bind_value(lbug_prepared_statement *stmt,
                                       const char *name, lbug_value *value)
{
  (void)stmt;
  (void)value;
  mutate_first_char(name);
  return LbugSuccess;
}
int lbug_connection_execute(lbug_connection *conn, lbug_prepared_statement *stmt,
                            lbug_query_result *out)
{
  (void)conn;
  (void)stmt;
  fake_lbug_result *result = malloc(sizeof(*result));
  if (result == NULL) return LbugError;
  result->success = true;
  result->text = fake_strdup("fake prepared");
  out->ptr = result;
  out->owned = true;
  return LbugSuccess;
}

void sqlite3_open_v2(void) {}
void sqlite3_close_v2(void) {}
void sqlite3_prepare_v2(void) {}
void sqlite3_finalize(void) {}
void sqlite3_step(void) {}
void sqlite3_bind_null(void) {}
void sqlite3_bind_int64(void) {}
void sqlite3_bind_double(void) {}
void sqlite3_bind_text(void) {}
void sqlite3_bind_blob(void) {}
void sqlite3_column_count(void) {}
void sqlite3_column_name(void) {}
void sqlite3_column_type(void) {}
void sqlite3_column_int64(void) {}
void sqlite3_column_double(void) {}
void sqlite3_column_text(void) {}
void sqlite3_column_blob(void) {}
void sqlite3_column_bytes(void) {}
void sqlite3_changes(void) {}
void sqlite3_busy_timeout(void) {}
void sqlite3_errcode(void) {}
void sqlite3_extended_errcode(void) {}
void sqlite3_errmsg(void) {}
