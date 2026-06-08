#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>

static sqlite3 *db_val(value v_db)
{
  return (sqlite3 *)(uintptr_t)Nativeint_val(v_db);
}

static void fail_sqlite(sqlite3 *db, const char *op, int rc)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s rc=%d msg=%s", op, rc,
    db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db));
  caml_failwith(buffer);
}

CAMLprim value eta_turso_pool_open(value v_path)
{
  CAMLparam1(v_path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(String_val(v_path), &db);
  if (rc != SQLITE_OK) fail_sqlite(db, "open", rc);
  sqlite3_busy_timeout(db, 50);
  CAMLreturn(caml_copy_nativeint((intnat)(uintptr_t)db));
}

CAMLprim value eta_turso_pool_close(value v_db)
{
  CAMLparam1(v_db);
  sqlite3 *db = db_val(v_db);
  int rc = sqlite3_close(db);
  if (rc != SQLITE_OK) fail_sqlite(db, "close", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pool_exec(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  sqlite3 *db = db_val(v_db);
  int rc = sqlite3_exec(db, String_val(v_sql), NULL, NULL, NULL);
  CAMLreturn(Val_bool(rc == SQLITE_OK));
}

