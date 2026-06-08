#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sqlite3.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

static void log_exec(buffer *out, sqlite3 *db, const char *label, const char *sql)
{
  int rc = sqlite3_exec(db, sql, NULL, NULL, NULL);
  appendf(out, "%s rc=%d xrc=%d msg=%s sql=%s\n",
    label, rc, sqlite3_extended_errcode(db), sqlite3_errmsg(db), sql);
}

CAMLprim value eta_turso_error_codes_run(value unit_value)
{
  CAMLparam1(unit_value);
  buffer out = {0};
  char path[256];
  snprintf(path, sizeof(path), "/tmp/eta_turso_errors_%ld.db", (long)getpid());
  unlink(path);
  appendf(&out, "=== P-Turso-6 conflict error code surface ===\n");
  sqlite3 *setup = NULL;
  sqlite3_open(path, &setup);
  log_exec(&out, setup, "setup_mvcc", "PRAGMA journal_mode = 'mvcc'");
  log_exec(&out, setup, "setup_table", "CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)");
  log_exec(&out, setup, "setup_seed", "INSERT INTO counter VALUES (1, 0)");
  sqlite3_close(setup);

  sqlite3 *a = NULL; sqlite3 *b = NULL;
  sqlite3_open(path, &a);
  sqlite3_open(path, &b);
  sqlite3_busy_timeout(a, 50);
  sqlite3_busy_timeout(b, 50);
  log_exec(&out, a, "a_begin", "BEGIN CONCURRENT");
  log_exec(&out, b, "b_begin", "BEGIN CONCURRENT");
  log_exec(&out, b, "b_snapshot_read", "SELECT n FROM counter WHERE id = 1");
  log_exec(&out, a, "a_update", "UPDATE counter SET n = n + 1 WHERE id = 1");
  log_exec(&out, a, "a_commit", "COMMIT");
  log_exec(&out, b, "b_update_after_a_commit", "UPDATE counter SET n = n + 1 WHERE id = 1");
  log_exec(&out, b, "b_commit_conflict", "COMMIT");
  log_exec(&out, b, "b_rollback_after_conflict", "ROLLBACK");
  sqlite3_close(b);
  sqlite3_close(a);
  appendf(&out, "verdict=Partial\n");
  appendf(&out, "mapping=conflict surfaced as raw rc/xrc above; if rc=1 with empty msg, driver cannot distinguish without string/code support\n");
  unlink(path);
  value result = caml_copy_string(out.data);
  free(out.data);
  CAMLreturn(result);
}
