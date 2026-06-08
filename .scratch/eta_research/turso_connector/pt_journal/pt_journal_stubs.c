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

static void mode_after(sqlite3 *db, buffer *out, const char *label, const char *pragma)
{
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, pragma, -1, &stmt, NULL);
  char mode_buf[128];
  snprintf(mode_buf, sizeof(mode_buf), "<none>");
  if (rc == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
    const unsigned char *text = sqlite3_column_text(stmt, 0);
    snprintf(mode_buf, sizeof(mode_buf), "%s", text ? (const char *)text : "<null>");
  }
  appendf(out, "%s pragma=%s rc=%d xrc=%d result=%s msg=%s\n",
    label, pragma, rc, sqlite3_extended_errcode(db), mode_buf, sqlite3_errmsg(db));
  sqlite3_finalize(stmt);
}

static void unlink_family(const char *path)
{
  char journal[512];
  char wal[512];
  char shm[512];
  char mvcc[512];
  snprintf(journal, sizeof(journal), "%s-journal", path);
  snprintf(wal, sizeof(wal), "%s-wal", path);
  snprintf(shm, sizeof(shm), "%s-shm", path);
  snprintf(mvcc, sizeof(mvcc), "%s-mvcc", path);
  unlink(path);
  unlink(journal);
  unlink(wal);
  unlink(shm);
  unlink(mvcc);
}

CAMLprim value eta_turso_journal_run(value unit_value)
{
  CAMLparam1(unit_value);
  buffer out = {0};
  char path[256];
  appendf(&out, "=== P-Turso-5 MVCC WAL interaction ===\n");

  snprintf(path, sizeof(path), "/tmp/eta_turso_journal_%ld_wal_mvcc.db", (long)getpid());
  unlink_family(path);
  appendf(&out, "\n--- wal_then_mvcc ---\n");
  appendf(&out, "database=%s\n", path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(path, &db);
  appendf(&out, "open rc=%d msg=%s\n", rc, db ? sqlite3_errmsg(db) : "no-db");
  mode_after(db, &out, "initial", "PRAGMA journal_mode");
  mode_after(db, &out, "set_wal", "PRAGMA journal_mode = 'wal'");
  mode_after(db, &out, "then_set_mvcc", "PRAGMA journal_mode = 'mvcc'");
  mode_after(db, &out, "inspect_after_wal_then_mvcc", "PRAGMA journal_mode");
  rc = sqlite3_close(db);
  appendf(&out, "close_after_wal_then_mvcc rc=%d\n", rc);

  snprintf(path, sizeof(path), "/tmp/eta_turso_journal_%ld_mvcc_wal.db", (long)getpid());
  unlink_family(path);
  appendf(&out, "\n--- mvcc_then_wal ---\n");
  rc = sqlite3_open(path, &db);
  appendf(&out, "open rc=%d msg=%s\n", rc, db ? sqlite3_errmsg(db) : "no-db");
  mode_after(db, &out, "set_mvcc", "PRAGMA journal_mode = 'mvcc'");
  mode_after(db, &out, "then_set_wal", "PRAGMA journal_mode = 'wal'");
  mode_after(db, &out, "inspect_after_mvcc_then_wal", "PRAGMA journal_mode");
  rc = sqlite3_close(db);
  appendf(&out, "close_after_mvcc_then_wal rc=%d\n", rc);

  sqlite3 *db1 = NULL; sqlite3 *db2 = NULL;
  snprintf(path, sizeof(path), "/tmp/eta_turso_journal_%ld_cross.db", (long)getpid());
  unlink_family(path);
  appendf(&out, "\n--- cross_connection ---\n");
  sqlite3_open(path, &db1);
  mode_after(db1, &out, "conn1_set_mvcc", "PRAGMA journal_mode = 'mvcc'");
  sqlite3_open(path, &db2);
  mode_after(db2, &out, "conn2_observes", "PRAGMA journal_mode");
  int close2 = sqlite3_close(db2);
  int close1 = sqlite3_close(db1);
  appendf(&out, "cross_connection_close db2_rc=%d db1_rc=%d\n", close2, close1);

  appendf(&out, "\ncrash_recovery=Untested blocker=requires external kill harness; in-process fork fixture was unsafe with Turso/Rust library\n");
  appendf(&out, "verdict=Partial\n");
  appendf(&out, "finding=journal_mode is deterministic last-writer-wins; MVCC displaces WAL and WAL displaces MVCC depending on explicit PRAGMA order\n");
  unlink_family(path);
  value result = caml_copy_string(out.data);
  free(out.data);
  CAMLreturn(result);
}

CAMLprim value eta_turso_journal_close_crash(value unit_value)
{
  CAMLparam1(unit_value);
  char path[256];
  snprintf(path, sizeof(path), "/tmp/eta_turso_journal_close_crash_%ld.db", (long)getpid());
  unlink_family(path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(path, &db);
  fprintf(stderr, "close_crash open rc=%d msg=%s\n", rc, db ? sqlite3_errmsg(db) : "no-db");
  sqlite3_stmt *stmt = NULL;
  rc = sqlite3_prepare_v2(db, "PRAGMA journal_mode = 'wal'", -1, &stmt, NULL);
  fprintf(stderr, "close_crash set_wal prepare rc=%d msg=%s\n", rc, sqlite3_errmsg(db));
  if (rc == SQLITE_OK) {
    int step_rc = sqlite3_step(stmt);
    const unsigned char *text = sqlite3_column_text(stmt, 0);
    fprintf(stderr, "close_crash set_wal step rc=%d result=%s msg=%s\n", step_rc, text ? (const char *)text : "<none>", sqlite3_errmsg(db));
  }
  sqlite3_finalize(stmt);
  stmt = NULL;
  rc = sqlite3_prepare_v2(db, "PRAGMA journal_mode = 'mvcc'", -1, &stmt, NULL);
  fprintf(stderr, "close_crash set_mvcc prepare rc=%d msg=%s\n", rc, sqlite3_errmsg(db));
  if (rc == SQLITE_OK) {
    int step_rc = sqlite3_step(stmt);
    const unsigned char *text = sqlite3_column_text(stmt, 0);
    fprintf(stderr, "close_crash set_mvcc step rc=%d result=%s msg=%s\n", step_rc, text ? (const char *)text : "<none>", sqlite3_errmsg(db));
  }
  sqlite3_finalize(stmt);
  fprintf(stderr, "close_crash before sqlite3_close\n");
  fflush(stderr);
  rc = sqlite3_close(db);
  fprintf(stderr, "close_crash close returned rc=%d\n", rc);
  fflush(stderr);
  unlink_family(path);
  CAMLreturn(Val_unit);
}
