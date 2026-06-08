#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef SQLITE_INTERRUPT
#define SQLITE_INTERRUPT 9
#endif

typedef struct { char *data; size_t len; size_t cap; } buffer;
static void appendf(buffer *b, const char *fmt, ...)
{
  va_list ap;
  while (1) {
    if (b->cap == 0) { b->cap = 8192; b->data = malloc(b->cap); b->len = 0; b->data[0] = '\0'; }
    va_start(ap, fmt);
    int n = vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap);
    va_end(ap);
    if (n < 0) abort();
    if (b->len + (size_t)n < b->cap) { b->len += (size_t)n; return; }
    b->cap *= 2; b->data = realloc(b->data, b->cap);
  }
}

typedef struct { sqlite3 *db; const char *sql; int rc; int xrc; char msg[256]; } run_arg;

static void *exec_thread(void *arg)
{
  run_arg *a = (run_arg *)arg;
  a->rc = sqlite3_exec(a->db, a->sql, NULL, NULL, NULL);
  a->xrc = sqlite3_extended_errcode(a->db);
  snprintf(a->msg, sizeof(a->msg), "%s", sqlite3_errmsg(a->db));
  return NULL;
}

static int scalar_int(sqlite3 *db, const char *sql)
{
  sqlite3_stmt *stmt = NULL;
  int v = -1;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
    v = (int)sqlite3_column_int64(stmt, 0);
  sqlite3_finalize(stmt);
  return v;
}

static int run_interrupt_case(buffer *out, sqlite3 *db, const char *label, const char *sql)
{
  run_arg arg = { .db = db, .sql = sql, .rc = -1, .xrc = -1, .msg = "" };
  pthread_t thread;
  pthread_create(&thread, NULL, exec_thread, &arg);
  usleep(25000);
  sqlite3_interrupt(db);
  pthread_join(thread, NULL);
  int reusable = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS reusable (id INTEGER); INSERT INTO reusable VALUES (1); DELETE FROM reusable;", NULL, NULL, NULL) == SQLITE_OK;
  int autocommit = sqlite3_get_autocommit(db);
  if (!autocommit) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
  appendf(out, "%s rc=%d xrc=%d msg=%s autocommit=%d reusable=%d\n",
    label, arg.rc, arg.xrc, arg.msg, autocommit, reusable);
  return arg.rc == SQLITE_INTERRUPT && reusable && autocommit;
}

CAMLprim value eta_turso_cancel_run(value unit_value)
{
  CAMLparam1(unit_value);
  buffer out = {0};
  char path[256];
  snprintf(path, sizeof(path), "/tmp/eta_turso_cancel_%ld.db", (long)getpid());
  unlink(path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(path, &db);
  appendf(&out, "=== P-Turso-3 cancellation under sqlite3_interrupt ===\n");
  appendf(&out, "open rc=%d msg=%s database=%s\n", rc, db ? sqlite3_errmsg(db) : "no-db", path);
  sqlite3_exec(db, "PRAGMA journal_mode = 'mvcc'", NULL, NULL, NULL);
  sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)", NULL, NULL, NULL);
  sqlite3_exec(db, "WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x < 2000) INSERT INTO t(id,n) SELECT x,0 FROM c", NULL, NULL, NULL);
  int ok_select = run_interrupt_case(&out, db, "long_select", "SELECT count(*) FROM t a, t b, t c, t d");
  int rows_before = scalar_int(db, "SELECT sum(n) FROM t");
  int ok_txn = run_interrupt_case(&out, db, "begin_concurrent_update", "BEGIN CONCURRENT; UPDATE t SET n = n + 1 WHERE id IN (SELECT a.id FROM t a, t b, t c); COMMIT");
  int rows_after = scalar_int(db, "SELECT sum(n) FROM t");
  appendf(&out, "rows_before=%d rows_after=%d\n", rows_before, rows_after);
  appendf(&out, "verdict=%s\n", ok_select && ok_txn && rows_before == rows_after ? "Confirmed" : "Falsified");
  sqlite3_close(db);
  unlink(path);
  value result = caml_copy_string(out.data);
  free(out.data);
  CAMLreturn(result);
}
