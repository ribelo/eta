#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sqlite3.h>
#include <stdio.h>

CAMLprim value eta_sqlite_p0_version(value unit_value)
{
  CAMLparam1(unit_value);
  CAMLreturn(caml_copy_string(sqlite3_libversion()));
}

static void eta_sqlite_p0_fail(sqlite3 *db, const char *context)
{
  const char *message = db == NULL ? "sqlite failure" : sqlite3_errmsg(db);
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, message);
  if (db != NULL) {
    sqlite3_close(db);
  }
  caml_failwith(buffer);
}

CAMLprim value eta_sqlite_p0_smoke(value unit_value)
{
  CAMLparam1(unit_value);
  sqlite3 *db = NULL;
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_open_v2(
    ":memory:",
    &db,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
    NULL);
  if (rc != SQLITE_OK) {
    eta_sqlite_p0_fail(db, "open");
  }

  rc = sqlite3_exec(
    db,
    "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL);"
    "INSERT INTO t (name) VALUES ('eta');",
    NULL,
    NULL,
    NULL);
  if (rc != SQLITE_OK) {
    eta_sqlite_p0_fail(db, "exec");
  }

  rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    eta_sqlite_p0_fail(db, "prepare");
  }

  rc = sqlite3_step(stmt);
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    eta_sqlite_p0_fail(db, "step");
  }

  int count = sqlite3_column_int(stmt, 0);
  rc = sqlite3_finalize(stmt);
  if (rc != SQLITE_OK) {
    eta_sqlite_p0_fail(db, "finalize");
  }

  rc = sqlite3_close(db);
  if (rc != SQLITE_OK) {
    eta_sqlite_p0_fail(db, "close");
  }

  char buffer[64];
  snprintf(buffer, sizeof(buffer), "p0_sqlite_smoke=count:%d", count);
  CAMLreturn(caml_copy_string(buffer));
}

