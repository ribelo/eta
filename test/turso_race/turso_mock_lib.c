#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define SQLITE_MISUSE 21
#define SQLITE_INTEGER 1
#define SQLITE_TEXT 3
#define SQLITE_ROW 100
#define SQLITE_DONE 101

typedef enum {
  STMT_DONE,
  STMT_JOURNAL_MODE,
  STMT_SLOW_ROW
} stmt_kind;

typedef struct sqlite3 {
  int closed;
  int active_prepare;
  int active_step;
} sqlite3;

typedef struct sqlite3_stmt {
  sqlite3 *db;
  stmt_kind kind;
  int step_count;
} sqlite3_stmt;

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_active_steps = 0;
static int g_close_while_active = 0;

static void write_state_locked(void)
{
  const char *path = getenv("ETA_TURSO_MOCK_STATE");
  if (path == NULL || path[0] == '\0') return;
  FILE *f = fopen(path, "w");
  if (f == NULL) return;
  fprintf(f, "%d %d\n", g_active_steps, g_close_while_active);
  fclose(f);
}

static void write_state(void)
{
  pthread_mutex_lock(&g_mutex);
  write_state_locked();
  pthread_mutex_unlock(&g_mutex);
}

int sqlite3_open_v2(const char *path, sqlite3 **out, int flags, const char *vfs)
{
  (void)path;
  (void)flags;
  (void)vfs;
  sqlite3 *db = calloc(1, sizeof(sqlite3));
  if (db == NULL) return SQLITE_ERROR;
  *out = db;
  write_state();
  return SQLITE_OK;
}

int sqlite3_close_v2(sqlite3 *db)
{
  if (db == NULL) return SQLITE_OK;
  pthread_mutex_lock(&g_mutex);
  if (db->active_prepare > 0 || db->active_step > 0) {
    g_close_while_active = 1;
    db->closed = 1;
    write_state_locked();
    pthread_mutex_unlock(&g_mutex);
    return SQLITE_OK;
  }
  db->closed = 1;
  write_state_locked();
  pthread_mutex_unlock(&g_mutex);
  free(db);
  return SQLITE_OK;
}

void sqlite3_interrupt(sqlite3 *db) { (void)db; }

static stmt_kind classify_sql(const char *sql)
{
  if (sql != NULL && strstr(sql, "PRAGMA journal_mode") != NULL)
    return STMT_JOURNAL_MODE;
  if (sql != NULL && strstr(sql, "eta_test_slow_step") != NULL)
    return STMT_SLOW_ROW;
  return STMT_DONE;
}

int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int nbytes,
                       sqlite3_stmt **out, const char **tail)
{
  (void)nbytes;
  if (tail != NULL) *tail = NULL;
  if (db == NULL || db->closed) return SQLITE_MISUSE;
  pthread_mutex_lock(&g_mutex);
  db->active_prepare++;
  pthread_mutex_unlock(&g_mutex);
  sqlite3_stmt *stmt = calloc(1, sizeof(sqlite3_stmt));
  pthread_mutex_lock(&g_mutex);
  db->active_prepare--;
  pthread_mutex_unlock(&g_mutex);
  if (stmt == NULL) return SQLITE_ERROR;
  stmt->db = db;
  stmt->kind = classify_sql(sql);
  stmt->step_count = 0;
  *out = stmt;
  return SQLITE_OK;
}

int sqlite3_finalize(sqlite3_stmt *stmt)
{
  free(stmt);
  return SQLITE_OK;
}

int sqlite3_step(sqlite3_stmt *stmt)
{
  if (stmt == NULL || stmt->db == NULL || stmt->db->closed) return SQLITE_MISUSE;
  if (stmt->kind == STMT_DONE) return SQLITE_DONE;
  if (stmt->step_count > 0) return SQLITE_DONE;
  if (stmt->kind == STMT_SLOW_ROW) {
    pthread_mutex_lock(&g_mutex);
    stmt->db->active_step++;
    g_active_steps++;
    write_state_locked();
    pthread_mutex_unlock(&g_mutex);
    usleep(200000);
    pthread_mutex_lock(&g_mutex);
    stmt->db->active_step--;
    g_active_steps--;
    write_state_locked();
    pthread_mutex_unlock(&g_mutex);
  }
  stmt->step_count++;
  return SQLITE_ROW;
}

int sqlite3_bind_null(sqlite3_stmt *stmt, int index)
{
  (void)stmt;
  (void)index;
  return SQLITE_OK;
}

int sqlite3_bind_int64(sqlite3_stmt *stmt, int index, int64_t value)
{
  (void)stmt;
  (void)index;
  (void)value;
  return SQLITE_OK;
}

int sqlite3_bind_double(sqlite3_stmt *stmt, int index, double value)
{
  (void)stmt;
  (void)index;
  (void)value;
  return SQLITE_OK;
}

int sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *value, int len,
                      void (*destructor)(void *))
{
  (void)stmt;
  (void)index;
  (void)value;
  (void)len;
  (void)destructor;
  return SQLITE_OK;
}

int sqlite3_bind_blob(sqlite3_stmt *stmt, int index, const void *value, int len,
                      void (*destructor)(void *))
{
  (void)stmt;
  (void)index;
  (void)value;
  (void)len;
  (void)destructor;
  return SQLITE_OK;
}

int sqlite3_column_count(sqlite3_stmt *stmt)
{
  return stmt != NULL && stmt->kind != STMT_DONE ? 1 : 0;
}

const char *sqlite3_column_name(sqlite3_stmt *stmt, int index)
{
  (void)stmt;
  (void)index;
  return "value";
}

int sqlite3_column_type(sqlite3_stmt *stmt, int index)
{
  (void)index;
  return stmt != NULL && stmt->kind == STMT_SLOW_ROW ? SQLITE_INTEGER : SQLITE_TEXT;
}

int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int index)
{
  (void)stmt;
  (void)index;
  return 42;
}

double sqlite3_column_double(sqlite3_stmt *stmt, int index)
{
  (void)stmt;
  (void)index;
  return 0.0;
}

const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int index)
{
  (void)index;
  if (stmt != NULL && stmt->kind == STMT_JOURNAL_MODE)
    return (const unsigned char *)"mvcc";
  return (const unsigned char *)"";
}

const void *sqlite3_column_blob(sqlite3_stmt *stmt, int index)
{
  (void)stmt;
  (void)index;
  return NULL;
}

int sqlite3_column_bytes(sqlite3_stmt *stmt, int index)
{
  (void)index;
  if (stmt != NULL && stmt->kind == STMT_JOURNAL_MODE) return 4;
  return 0;
}

int sqlite3_changes(sqlite3 *db)
{
  (void)db;
  return 0;
}

int sqlite3_busy_timeout(sqlite3 *db, int ms)
{
  (void)db;
  (void)ms;
  return SQLITE_OK;
}

int sqlite3_errcode(sqlite3 *db)
{
  (void)db;
  return SQLITE_OK;
}

int sqlite3_extended_errcode(sqlite3 *db)
{
  (void)db;
  return SQLITE_OK;
}

const char *sqlite3_errmsg(sqlite3 *db)
{
  (void)db;
  return "mock turso";
}
