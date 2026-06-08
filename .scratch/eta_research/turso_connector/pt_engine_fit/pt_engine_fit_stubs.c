#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void fail_sqlite(sqlite3 *db, const char *operation, int rc)
{
  char buffer[1024];
  const char *message = db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db);
  snprintf(buffer, sizeof(buffer), "%s rc=%d: %s", operation, rc, message);
  caml_failwith(buffer);
}

static sqlite3 *db_val(value v_db)
{
  return (sqlite3 *)(uintptr_t)Nativeint_val(v_db);
}

static sqlite3_stmt *stmt_val(value v_stmt)
{
  return (sqlite3_stmt *)(uintptr_t)Nativeint_val(v_stmt);
}

CAMLprim value eta_turso_pt_open(value v_path)
{
  CAMLparam1(v_path);
  sqlite3 *db = NULL;
  int rc = sqlite3_open(String_val(v_path), &db);
  if (rc != SQLITE_OK) {
    fail_sqlite(db, "sqlite3_open", rc);
  }
  CAMLreturn(caml_copy_nativeint((intnat)(uintptr_t)db));
}

CAMLprim value eta_turso_pt_close(value v_db)
{
  CAMLparam1(v_db);
  sqlite3 *db = db_val(v_db);
  int rc = sqlite3_close(db);
  if (rc != SQLITE_OK) {
    fail_sqlite(db, "sqlite3_close", rc);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_exec(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  sqlite3 *db = db_val(v_db);
  int rc;
  caml_enter_blocking_section();
  rc = sqlite3_exec(db, String_val(v_sql), NULL, NULL, NULL);
  caml_leave_blocking_section();
  if (rc != SQLITE_OK) {
    fail_sqlite(db, "sqlite3_exec", rc);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_prepare(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  sqlite3 *db = db_val(v_db);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, String_val(v_sql), -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    fail_sqlite(db, "sqlite3_prepare_v2", rc);
  }
  CAMLreturn(caml_copy_nativeint((intnat)(uintptr_t)stmt));
}

CAMLprim value eta_turso_pt_finalize(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int rc = sqlite3_finalize(stmt);
  if (rc != SQLITE_OK) {
    fail_sqlite(NULL, "sqlite3_finalize", rc);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_reset(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int rc = sqlite3_reset(stmt);
  if (rc != SQLITE_OK) {
    fail_sqlite(NULL, "sqlite3_reset", rc);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_step(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  int rc;
  caml_enter_blocking_section();
  rc = sqlite3_step(stmt);
  caml_leave_blocking_section();
  CAMLreturn(Val_int(rc));
}

CAMLprim value eta_turso_pt_bind_null(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  int rc = sqlite3_bind_null(stmt_val(v_stmt), Int_val(v_index));
  if (rc != SQLITE_OK) fail_sqlite(NULL, "sqlite3_bind_null", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_bind_int64(value v_stmt, value v_index, value v_value)
{
  CAMLparam3(v_stmt, v_index, v_value);
  int rc = sqlite3_bind_int64(stmt_val(v_stmt), Int_val(v_index), Int64_val(v_value));
  if (rc != SQLITE_OK) fail_sqlite(NULL, "sqlite3_bind_int64", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_bind_double(value v_stmt, value v_index, value v_value)
{
  CAMLparam3(v_stmt, v_index, v_value);
  int rc = sqlite3_bind_double(stmt_val(v_stmt), Int_val(v_index), Double_val(v_value));
  if (rc != SQLITE_OK) fail_sqlite(NULL, "sqlite3_bind_double", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_bind_text(value v_stmt, value v_index, value v_value)
{
  CAMLparam3(v_stmt, v_index, v_value);
  int rc = sqlite3_bind_text(stmt_val(v_stmt), Int_val(v_index), String_val(v_value), -1, SQLITE_TRANSIENT);
  if (rc != SQLITE_OK) fail_sqlite(NULL, "sqlite3_bind_text", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_bind_blob(value v_stmt, value v_index, value v_value)
{
  CAMLparam3(v_stmt, v_index, v_value);
  int rc = sqlite3_bind_blob(stmt_val(v_stmt), Int_val(v_index), Bytes_val(v_value), caml_string_length(v_value), SQLITE_TRANSIENT);
  if (rc != SQLITE_OK) fail_sqlite(NULL, "sqlite3_bind_blob", rc);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_turso_pt_column_count(value v_stmt)
{
  CAMLparam1(v_stmt);
  CAMLreturn(Val_int(sqlite3_column_count(stmt_val(v_stmt))));
}

CAMLprim value eta_turso_pt_column_name(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  const char *name = sqlite3_column_name(stmt_val(v_stmt), Int_val(v_index));
  CAMLreturn(caml_copy_string(name == NULL ? "" : name));
}

CAMLprim value eta_turso_pt_column_type(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  CAMLreturn(Val_int(sqlite3_column_type(stmt_val(v_stmt), Int_val(v_index))));
}

CAMLprim value eta_turso_pt_column_int64(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  CAMLreturn(caml_copy_int64(sqlite3_column_int64(stmt_val(v_stmt), Int_val(v_index))));
}

CAMLprim value eta_turso_pt_column_double(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  CAMLreturn(caml_copy_double(sqlite3_column_double(stmt_val(v_stmt), Int_val(v_index))));
}

CAMLprim value eta_turso_pt_column_text(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  const unsigned char *text = sqlite3_column_text(stmt_val(v_stmt), Int_val(v_index));
  CAMLreturn(caml_copy_string(text == NULL ? "" : (const char *)text));
}

CAMLprim value eta_turso_pt_column_blob(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  sqlite3_stmt *stmt = stmt_val(v_stmt);
  const void *blob = sqlite3_column_blob(stmt, Int_val(v_index));
  int len = sqlite3_column_bytes(stmt, Int_val(v_index));
  value out = caml_alloc_string(len);
  if (len > 0 && blob != NULL) memcpy(Bytes_val(out), blob, len);
  CAMLreturn(out);
}

CAMLprim value eta_turso_pt_column_is_null(value v_stmt, value v_index)
{
  CAMLparam2(v_stmt, v_index);
  CAMLreturn(Val_bool(sqlite3_column_type(stmt_val(v_stmt), Int_val(v_index)) == SQLITE_NULL));
}

CAMLprim value eta_turso_pt_interrupt(value v_db)
{
  CAMLparam1(v_db);
  sqlite3_interrupt(db_val(v_db));
  CAMLreturn(Val_unit);
}
