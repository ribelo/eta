#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef SQLITE_BUSY
#define SQLITE_BUSY 5
#endif
#ifndef SQLITE_LOCKED
#define SQLITE_LOCKED 6
#endif

#define FIBERS 16
#define ITERS 100
#define MAX_RETRIES 10

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} buffer;

static void appendf(buffer *b, const char *fmt, ...)
{
  va_list ap;
  while (1) {
    if (b->cap == 0) {
      b->cap = 8192;
      b->data = malloc(b->cap);
      b->len = 0;
      b->data[0] = '\0';
    }
    va_start(ap, fmt);
    int written = vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap);
    va_end(ap);
    if (written < 0) abort();
    if (b->len + (size_t)written < b->cap) {
      b->len += (size_t)written;
      return;
    }
    b->cap *= 2;
    b->data = realloc(b->data, b->cap);
  }
}

typedef struct {
  const char *path;
  int hot_rows;
  int worker_id;
  int committed;
  int unrecovered;
  int busy;
  int locked;
  int generic_error;
  int max_attempts_seen;
  int retry_hist[MAX_RETRIES + 2];
  char first_error[256];
} worker_result;

static int exec_sql(sqlite3 *db, const char *sql)
{
  return sqlite3_exec(db, sql, NULL, NULL, NULL);
}

static void rollback(sqlite3 *db)
{
  sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
}

static void *worker_main(void *arg)
{
  worker_result *r = (worker_result *)arg;
  sqlite3 *db = NULL;
  int rc = sqlite3_open(r->path, &db);
  if (rc != SQLITE_OK) {
    snprintf(r->first_error, sizeof(r->first_error), "open rc=%d %s", rc, db ? sqlite3_errmsg(db) : "no-db");
    if (db != NULL) sqlite3_close(db);
    r->unrecovered = ITERS;
    return NULL;
  }
  sqlite3_busy_timeout(db, 50);
  exec_sql(db, "PRAGMA journal_mode = 'mvcc'");

  for (int i = 0; i < ITERS; i++) {
    int row_id = (r->worker_id % r->hot_rows) + 1;
    int committed = 0;
    for (int attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      char update_sql[160];
      rc = exec_sql(db, "BEGIN CONCURRENT");
      if (rc != SQLITE_OK) {
        if (rc == SQLITE_BUSY) r->busy++;
        else if (rc == SQLITE_LOCKED) r->locked++;
        else r->generic_error++;
        if (r->first_error[0] == '\0') {
          snprintf(r->first_error, sizeof(r->first_error), "BEGIN rc=%d xrc=%d msg=%s",
            rc, sqlite3_extended_errcode(db), sqlite3_errmsg(db));
        }
        rollback(db);
        usleep((unsigned int)(1000 * (attempt + 1)));
        continue;
      }

      snprintf(update_sql, sizeof(update_sql),
        "UPDATE counter SET counter = counter + 1 WHERE id = %d", row_id);
      rc = exec_sql(db, update_sql);
      if (rc == SQLITE_OK) {
        rc = exec_sql(db, "COMMIT");
      }
      if (rc == SQLITE_OK) {
        r->committed++;
        if (attempt > r->max_attempts_seen) r->max_attempts_seen = attempt;
        r->retry_hist[attempt]++;
        committed = 1;
        break;
      }

      if (rc == SQLITE_BUSY) r->busy++;
      else if (rc == SQLITE_LOCKED) r->locked++;
      else r->generic_error++;
      if (r->first_error[0] == '\0') {
        snprintf(r->first_error, sizeof(r->first_error), "txn rc=%d xrc=%d msg=%s",
          rc, sqlite3_extended_errcode(db), sqlite3_errmsg(db));
      }
      rollback(db);
      usleep((unsigned int)(1000 * (attempt + 1)));
    }
    if (!committed) {
      r->unrecovered++;
      r->retry_hist[MAX_RETRIES + 1]++;
    }
  }

  sqlite3_close(db);
  return NULL;
}

static int scalar_int(sqlite3 *db, const char *sql)
{
  sqlite3_stmt *stmt = NULL;
  int value = -1;
  int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
  if (rc == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
    value = (int)sqlite3_column_int64(stmt, 0);
  }
  sqlite3_finalize(stmt);
  return value;
}

static int run_scale(buffer *out, const char *path, int hot_rows)
{
  unlink(path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(path, &db);
  if (rc != SQLITE_OK) {
    appendf(out, "scale hot_rows=%d setup_open_failed rc=%d msg=%s\n",
      hot_rows, rc, db ? sqlite3_errmsg(db) : "no-db");
    if (db != NULL) sqlite3_close(db);
    return 0;
  }
  sqlite3_busy_timeout(db, 50);
  appendf(out, "\n--- scale hot_rows=%d ---\n", hot_rows);
  rc = exec_sql(db, "PRAGMA journal_mode = 'mvcc'");
  appendf(out, "pragma_mvcc rc=%d xrc=%d msg=%s\n", rc, sqlite3_extended_errcode(db), sqlite3_errmsg(db));
  rc = exec_sql(db, "CREATE TABLE counter (id INTEGER PRIMARY KEY, counter INTEGER NOT NULL)");
  if (rc != SQLITE_OK) {
    appendf(out, "create_failed rc=%d xrc=%d msg=%s\n", rc, sqlite3_extended_errcode(db), sqlite3_errmsg(db));
    sqlite3_close(db);
    return 0;
  }
  for (int i = 1; i <= hot_rows; i++) {
    char insert_sql[128];
    snprintf(insert_sql, sizeof(insert_sql), "INSERT INTO counter (id, counter) VALUES (%d, 0)", i);
    rc = exec_sql(db, insert_sql);
    if (rc != SQLITE_OK) {
      appendf(out, "insert_seed_failed id=%d rc=%d msg=%s\n", i, rc, sqlite3_errmsg(db));
      sqlite3_close(db);
      return 0;
    }
  }
  sqlite3_close(db);

  pthread_t threads[FIBERS];
  worker_result results[FIBERS];
  memset(results, 0, sizeof(results));
  for (int i = 0; i < FIBERS; i++) {
    results[i].path = path;
    results[i].hot_rows = hot_rows;
    results[i].worker_id = i;
    pthread_create(&threads[i], NULL, worker_main, &results[i]);
  }
  for (int i = 0; i < FIBERS; i++) {
    pthread_join(threads[i], NULL);
  }

  rc = sqlite3_open(path, &db);
  int total_counter = scalar_int(db, "SELECT SUM(counter) FROM counter");
  int row_count = scalar_int(db, "SELECT COUNT(*) FROM counter");
  sqlite3_close(db);

  int committed = 0, unrecovered = 0, busy = 0, locked = 0, generic_error = 0, max_attempts = 0;
  int hist[MAX_RETRIES + 2];
  memset(hist, 0, sizeof(hist));
  for (int i = 0; i < FIBERS; i++) {
    committed += results[i].committed;
    unrecovered += results[i].unrecovered;
    busy += results[i].busy;
    locked += results[i].locked;
    generic_error += results[i].generic_error;
    if (results[i].max_attempts_seen > max_attempts) max_attempts = results[i].max_attempts_seen;
    for (int j = 0; j < MAX_RETRIES + 2; j++) hist[j] += results[i].retry_hist[j];
  }

  appendf(out, "expected_counter=%d actual_counter=%d row_count=%d\n", FIBERS * ITERS, total_counter, row_count);
  appendf(out, "committed=%d unrecovered=%d busy=%d locked=%d generic_error=%d max_retries_seen=%d\n",
    committed, unrecovered, busy, locked, generic_error, max_attempts);
  appendf(out, "retry_histogram attempts=commits:");
  for (int j = 0; j <= MAX_RETRIES; j++) appendf(out, " %d=%d", j, hist[j]);
  appendf(out, " exhausted=%d\n", hist[MAX_RETRIES + 1]);
  appendf(out, "per_worker:");
  for (int i = 0; i < FIBERS; i++) {
    appendf(out, " w%d{ok=%d,unrec=%d,busy=%d,locked=%d,generic=%d,max=%d}",
      i, results[i].committed, results[i].unrecovered, results[i].busy,
      results[i].locked, results[i].generic_error, results[i].max_attempts_seen);
  }
  appendf(out, "\n");
  for (int i = 0; i < FIBERS; i++) {
    if (results[i].first_error[0] != '\0') {
      appendf(out, "first_error worker=%d %s\n", i, results[i].first_error);
    }
  }

  int ok = (total_counter == FIBERS * ITERS) && (committed == FIBERS * ITERS) && unrecovered == 0;
  appendf(out, "scale_verdict=%s\n", ok ? "Confirmed" : "Falsified");
  return ok;
}

CAMLprim value eta_turso_hot_row_run(value unit_value)
{
  CAMLparam1(unit_value);
  buffer out = {0};
  char path[256];
  appendf(&out, "=== P-Turso-2 hot-row contention under BEGIN CONCURRENT ===\n");
  appendf(&out, "threads=%d iterations_per_thread=%d max_retries=%d database_template=/tmp/eta_turso_hot_row_PID_ROWS.db\n",
    FIBERS, ITERS, MAX_RETRIES);
  snprintf(path, sizeof(path), "/tmp/eta_turso_hot_row_%ld_1.db", (long)getpid());
  int ok1 = run_scale(&out, path, 1);
  snprintf(path, sizeof(path), "/tmp/eta_turso_hot_row_%ld_4.db", (long)getpid());
  int ok4 = run_scale(&out, path, 4);
  snprintf(path, sizeof(path), "/tmp/eta_turso_hot_row_%ld_16.db", (long)getpid());
  int ok16 = run_scale(&out, path, 16);
  appendf(&out, "\nsummary hot_rows_1=%s hot_rows_4=%s hot_rows_16=%s\n",
    ok1 ? "Confirmed" : "Falsified",
    ok4 ? "Confirmed" : "Falsified",
    ok16 ? "Confirmed" : "Falsified");
  appendf(&out, "verdict=%s\n",
    ok1 && ok4 && ok16 ? "Confirmed" : (ok16 || ok4 ? "Partial" : "Falsified"));
  unlink(path);
  value result = caml_copy_string(out.data == NULL ? "" : out.data);
  free(out.data);
  CAMLreturn(result);
}
