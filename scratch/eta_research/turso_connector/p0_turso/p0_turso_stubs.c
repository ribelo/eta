/* P0 Turso C API link probe — stubs for OCaml FFI.
   Confirms libturso_sqlite3 is reachable and functional via direct C stubs. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>

/* ---- sqlite3_libversion : unit -> string ---- */
CAMLprim value eta_turso_p0_version(value unit_value)
{
  CAMLparam1(unit_value);
  const char *ver = sqlite3_libversion();
  if (ver == NULL) {
    caml_failwith("sqlite3_libversion returned NULL");
  }
  CAMLreturn(caml_copy_string(ver));
}

/* ---- Helper: raise Failure with context + sqlite3 error ---- */
static void fail_with_sqlite_error(sqlite3 *db, const char *context)
{
  const char *message = db == NULL ? "sqlite failure" : sqlite3_errmsg(db);
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, message);
  if (db != NULL) {
    sqlite3_close(db);
  }
  caml_failwith(buffer);
}

/* ---- smoke_test : unit -> string ----
   Opens in-memory database, creates a table, inserts a row, queries it back.
   Returns "p0_turso_smoke=count:N" on success. */
CAMLprim value eta_turso_p0_smoke(value unit_value)
{
  CAMLparam1(unit_value);
  sqlite3 *db = NULL;
  sqlite3_stmt *stmt = NULL;
  int rc;

  /* Open in-memory database */
  rc = sqlite3_open(":memory:", &db);
  if (rc != SQLITE_OK) {
    fail_with_sqlite_error(db, "open");
  }

  /* Create table and insert */
  rc = sqlite3_exec(
    db,
    "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL);"
    "INSERT INTO t (name) VALUES ('turso');",
    NULL,
    NULL,
    NULL);
  if (rc != SQLITE_OK) {
    fail_with_sqlite_error(db, "exec");
  }

  /* Query count */
  rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    fail_with_sqlite_error(db, "prepare");
  }

  rc = sqlite3_step(stmt);
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    fail_with_sqlite_error(db, "step");
  }

  int count = (int)sqlite3_column_int64(stmt, 0);
  rc = sqlite3_finalize(stmt);
  if (rc != SQLITE_OK) {
    fail_with_sqlite_error(db, "finalize");
  }

  rc = sqlite3_close(db);
  if (rc != SQLITE_OK) {
    fail_with_sqlite_error(db, "close");
  }

  char buffer[64];
  snprintf(buffer, sizeof(buffer), "p0_turso_smoke=count:%d", count);
  CAMLreturn(caml_copy_string(buffer));
}

/* ---- api_survey : unit -> string ----
   Returns a multi-line string summarizing key C API capabilities. */
CAMLprim value eta_turso_p0_api_survey(value unit_value)
{
  CAMLparam1(unit_value);
  char buf[4096];
  int off = 0;

  off += snprintf(buf + off, sizeof(buf) - off,
    "=== Turso C API Survey ===\n"
    "Version: %s\n"
    "SQLite compatibility: %s\n\n"
    "--- Lifecycle ---\n"
    "  sqlite3_open / sqlite3_open_v2  (Database)\n"
    "  sqlite3_close                   (Database)\n\n"
    "--- Prepare / Step / Finalize ---\n"
    "  sqlite3_prepare_v2              (Database, sql -> Statement)\n"
    "  sqlite3_bind_* family           (bind values to params)\n"
    "  sqlite3_step                    (Statement -> SQLITE_ROW/SQLITE_DONE)\n"
    "  sqlite3_finalize                (Statement)\n\n"
    "--- Column Access ---\n"
    "  sqlite3_column_count            (Statement -> int)\n"
    "  sqlite3_column_type             (Statement, col -> type)\n"
    "  sqlite3_column_name             (Statement, col -> const char*)\n"
    "  sqlite3_column_int / int64 / double / text / blob\n\n"
    "--- Cancellation ---\n"
    "  sqlite3_interrupt               (Database)\n\n"
    "--- Errors ---\n"
    "  sqlite3_errmsg                  (Database -> const char*)\n"
    "  sqlite3_errcode                 (Database -> int)\n\n"
    "--- Thread Safety ---\n"
    "  sqlite3_open_v2 with SQLITE_OPEN_NOMUTEX / SQLITE_OPEN_FULLMUTEX\n"
    "  Same as SQLite: one connection per thread\n\n"
    "--- Turso-Specific Features ---\n"
    "  BEGIN CONCURRENT               (MVCC for concurrent writes)\n"
    "  Vector data type               (VECTOR type for embeddings)\n"
    "  Encryption at rest             (encryption key at open time)\n"
    "  Async I/O                      (io_uring on Linux)\n"
    "  CDC                            (Change Data Capture)\n\n"
    "--- Key Differences from SQLite ---\n"
    "  1. BEGIN CONCURRENT: allows multiple writers via MVCC\n"
    "  2. Vector type: native vector search support\n"
    "  3. Encryption: built-in encryption at rest\n"
    "  4. Async I/O: io_uring support on Linux\n"
    "  5. CDC: real-time change tracking\n"
    "  6. Memory safety: implemented in Rust\n",
    sqlite3_libversion(),
    "Full (SQLite 3.42.0 compatible)"
  );

  CAMLreturn(caml_copy_string(buf));
}
