/* Minimal mock of liblbug used to exercise the LadybugDB stub error paths
   without a real LadybugDB build.

   It implements just enough of the lbug_* ABI for [eta_ladybug_query_values]
   (the no-params, row-materializing path) to reach [materialize_arrow_rows]
   with a live query result, then forces a failure inside materialization by
   reporting an Arrow-schema error. The point is to verify the C stub does not
   leak the query result when an OCaml exception unwinds the call.

   It tracks how many query results were created vs destroyed and writes the
   running totals to the file named by ETA_LADYBUG_MOCK_STATE so the OCaml test
   can assert that every created result is eventually destroyed. */

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

static int g_created = 0;
static int g_destroyed = 0;

static void write_state(void)
{
  const char *path = getenv("ETA_LADYBUG_MOCK_STATE");
  if (path == NULL || path[0] == '\0') return;
  FILE *f = fopen(path, "w");
  if (f == NULL) return;
  fprintf(f, "%d %d\n", g_created, g_destroyed);
  fclose(f);
}

const char *lbug_get_version(void) { return "mock-0"; }
char *lbug_get_last_error(void) { return NULL; }
void lbug_destroy_string(char *s) { free(s); }

lbug_system_config lbug_default_system_config(void)
{
  lbug_system_config config;
  memset(&config, 0, sizeof(config));
  return config;
}

lbug_state lbug_database_init(const char *path, lbug_system_config config,
                              lbug_database *db)
{
  (void)path;
  (void)config;
  db->ptr = malloc(1);
  return LbugSuccess;
}

void lbug_database_destroy(lbug_database *db)
{
  free(db->ptr);
  db->ptr = NULL;
}

lbug_state lbug_connection_init(lbug_database *db, lbug_connection *conn)
{
  (void)db;
  conn->ptr = malloc(1);
  return LbugSuccess;
}

void lbug_connection_destroy(lbug_connection *conn)
{
  free(conn->ptr);
  conn->ptr = NULL;
}

lbug_state lbug_connection_query(lbug_connection *conn, const char *cypher,
                                 lbug_query_result *result)
{
  (void)conn;
  (void)cypher;
  result->ptr = malloc(1);
  result->owned = true;
  g_created++;
  write_state();
  return LbugSuccess;
}

void lbug_connection_interrupt(lbug_connection *conn) { (void)conn; }

bool lbug_query_result_is_success(lbug_query_result *result)
{
  (void)result;
  return true;
}

char *lbug_query_result_get_error_message(lbug_query_result *result)
{
  (void)result;
  return NULL;
}

char *lbug_query_result_to_string(lbug_query_result *result)
{
  (void)result;
  return NULL;
}

/* Force materialize_arrow_rows to raise while the query result is live. */
lbug_state lbug_query_result_get_arrow_schema(lbug_query_result *result,
                                              struct ArrowSchema *schema)
{
  (void)result;
  (void)schema;
  return LbugError;
}

lbug_state lbug_query_result_get_next_arrow_chunk(lbug_query_result *result,
                                                  int64_t batch,
                                                  struct ArrowArray *array)
{
  (void)result;
  (void)batch;
  (void)array;
  return LbugError;
}

void lbug_query_result_destroy(lbug_query_result *result)
{
  if (result->ptr != NULL) {
    free(result->ptr);
    result->ptr = NULL;
    g_destroyed++;
    write_state();
  }
}

lbug_state lbug_connection_prepare(lbug_connection *conn, const char *cypher,
                                   lbug_prepared_statement *stmt)
{
  (void)conn;
  (void)cypher;
  stmt->ptr = malloc(1);
  stmt->bound_values = NULL;
  return LbugSuccess;
}

bool lbug_prepared_statement_is_success(lbug_prepared_statement *stmt)
{
  (void)stmt;
  return true;
}

char *lbug_prepared_statement_get_error_message(lbug_prepared_statement *stmt)
{
  (void)stmt;
  return NULL;
}

void lbug_prepared_statement_destroy(lbug_prepared_statement *stmt)
{
  free(stmt->ptr);
  stmt->ptr = NULL;
}

lbug_state lbug_prepared_statement_bind_string(lbug_prepared_statement *stmt,
                                               const char *name,
                                               const char *value)
{
  (void)stmt;
  (void)name;
  (void)value;
  return LbugSuccess;
}

lbug_state lbug_prepared_statement_bind_int64(lbug_prepared_statement *stmt,
                                              const char *name, int64_t value)
{
  (void)stmt;
  (void)name;
  (void)value;
  return LbugSuccess;
}

lbug_state lbug_prepared_statement_bind_double(lbug_prepared_statement *stmt,
                                               const char *name, double value)
{
  (void)stmt;
  (void)name;
  (void)value;
  return LbugSuccess;
}

lbug_state lbug_prepared_statement_bind_bool(lbug_prepared_statement *stmt,
                                             const char *name, bool value)
{
  (void)stmt;
  (void)name;
  (void)value;
  return LbugSuccess;
}

lbug_value *lbug_value_create_null(void) { return malloc(1); }
lbug_value *lbug_value_create_bool(bool v) { (void)v; return malloc(1); }
lbug_value *lbug_value_create_int64(int64_t v) { (void)v; return malloc(1); }
lbug_value *lbug_value_create_double(double v) { (void)v; return malloc(1); }
lbug_value *lbug_value_create_string(const char *v) { (void)v; return malloc(1); }

lbug_state lbug_value_create_list(uint64_t count, lbug_value **items,
                                  lbug_value **out)
{
  (void)count;
  (void)items;
  *out = malloc(1);
  return LbugSuccess;
}

lbug_state lbug_value_create_map(uint64_t count, lbug_value **keys,
                                 lbug_value **vals, lbug_value **out)
{
  (void)count;
  (void)keys;
  (void)vals;
  *out = malloc(1);
  return LbugSuccess;
}

lbug_state lbug_value_create_struct(uint64_t count, const char **names,
                                    lbug_value **vals, lbug_value **out)
{
  (void)count;
  (void)names;
  (void)vals;
  *out = malloc(1);
  return LbugSuccess;
}

void lbug_value_destroy(lbug_value *v) { free(v); }

lbug_state lbug_prepared_statement_bind_value(lbug_prepared_statement *stmt,
                                              const char *name, lbug_value *v)
{
  (void)stmt;
  (void)name;
  (void)v;
  return LbugSuccess;
}

lbug_state lbug_connection_execute(lbug_connection *conn,
                                   lbug_prepared_statement *stmt,
                                   lbug_query_result *result)
{
  (void)conn;
  (void)stmt;
  result->ptr = malloc(1);
  result->owned = true;
  g_created++;
  write_state();
  return LbugSuccess;
}
