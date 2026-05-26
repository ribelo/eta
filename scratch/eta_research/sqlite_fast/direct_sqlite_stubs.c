#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  sqlite3 *db;
} eta_sqlite_direct_db;

typedef struct {
  sqlite3_stmt *stmt;
} eta_sqlite_direct_stmt;

static void eta_sqlite_direct_finalize_db(value v_db)
{
  eta_sqlite_direct_db *db = (eta_sqlite_direct_db *)Data_custom_val(v_db);
  if (db->db != NULL) {
    (void)sqlite3_close_v2(db->db);
    db->db = NULL;
  }
}

static void eta_sqlite_direct_finalize_stmt(value v_stmt)
{
  eta_sqlite_direct_stmt *stmt = (eta_sqlite_direct_stmt *)Data_custom_val(v_stmt);
  if (stmt->stmt != NULL) {
    (void)sqlite3_finalize(stmt->stmt);
    stmt->stmt = NULL;
  }
}

static struct custom_operations eta_sqlite_direct_db_ops = {
  "eta.sqlite_fast_direct.db",
  eta_sqlite_direct_finalize_db,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations eta_sqlite_direct_stmt_ops = {
  "eta.sqlite_fast_direct.stmt",
  eta_sqlite_direct_finalize_stmt,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static sqlite3 *eta_sqlite_direct_db_val(value v_db)
{
  eta_sqlite_direct_db *db = (eta_sqlite_direct_db *)Data_custom_val(v_db);
  return db->db;
}

static sqlite3_stmt *eta_sqlite_direct_stmt_val(value v_stmt)
{
  eta_sqlite_direct_stmt *stmt = (eta_sqlite_direct_stmt *)Data_custom_val(v_stmt);
  return stmt->stmt;
}

CAMLprim intnat eta_sqlite_direct_rc_ok(value v_unit)
{
  (void)v_unit;
  return SQLITE_OK;
}

CAMLprim value eta_sqlite_direct_rc_ok_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_OK);
}

CAMLprim intnat eta_sqlite_direct_rc_row(value v_unit)
{
  (void)v_unit;
  return SQLITE_ROW;
}

CAMLprim value eta_sqlite_direct_rc_row_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_ROW);
}

CAMLprim intnat eta_sqlite_direct_rc_done(value v_unit)
{
  (void)v_unit;
  return SQLITE_DONE;
}

CAMLprim value eta_sqlite_direct_rc_done_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_DONE);
}

CAMLprim intnat eta_sqlite_direct_rc_misuse(value v_unit)
{
  (void)v_unit;
  return SQLITE_MISUSE;
}

CAMLprim value eta_sqlite_direct_rc_misuse_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_MISUSE);
}

CAMLprim intnat eta_sqlite_direct_rc_range(value v_unit)
{
  (void)v_unit;
  return SQLITE_RANGE;
}

CAMLprim value eta_sqlite_direct_rc_range_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_RANGE);
}

CAMLprim intnat eta_sqlite_direct_rc_constraint(value v_unit)
{
  (void)v_unit;
  return SQLITE_CONSTRAINT;
}

CAMLprim value eta_sqlite_direct_rc_constraint_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_CONSTRAINT);
}

CAMLprim value eta_sqlite_direct_open_memory(value v_unit)
{
  CAMLparam1(v_unit);
  CAMLlocal1(v_block);
  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(
    ":memory:",
    &db,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
    NULL);
  if (rc != SQLITE_OK) {
    const char *message = db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db);
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "sqlite open_memory: %s", message);
    if (db != NULL) {
      (void)sqlite3_close_v2(db);
    }
    caml_failwith(buffer);
  }

  v_block = caml_alloc_custom(&eta_sqlite_direct_db_ops, sizeof(eta_sqlite_direct_db), 0, 1);
  ((eta_sqlite_direct_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim intnat eta_sqlite_direct_close(value v_db)
{
  sqlite3 *db = eta_sqlite_direct_db_val(v_db);
  int rc;
  if (db == NULL) {
    return SQLITE_OK;
  }
  rc = sqlite3_close_v2(db);
  if (rc == SQLITE_OK) {
    ((eta_sqlite_direct_db *)Data_custom_val(v_db))->db = NULL;
  }
  return rc;
}

CAMLprim value eta_sqlite_direct_close_bc(value v_db)
{
  return Val_int(eta_sqlite_direct_close(v_db));
}

CAMLprim value eta_sqlite_direct_prepare(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  CAMLlocal1(v_stmt);
  sqlite3 *db = eta_sqlite_direct_db_val(v_db);
  sqlite3_stmt *stmt = NULL;
  int rc;
  if (db == NULL) {
    caml_failwith("sqlite prepare: database is closed");
  }
  rc = sqlite3_prepare_v2(
    db,
    String_val(v_sql),
    (int)caml_string_length(v_sql),
    &stmt,
    NULL);
  if (rc != SQLITE_OK || stmt == NULL) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "sqlite prepare: %s", sqlite3_errmsg(db));
    caml_failwith(buffer);
  }

  v_stmt =
    caml_alloc_custom(&eta_sqlite_direct_stmt_ops, sizeof(eta_sqlite_direct_stmt), 0, 1);
  ((eta_sqlite_direct_stmt *)Data_custom_val(v_stmt))->stmt = stmt;
  CAMLreturn(v_stmt);
}

CAMLprim intnat eta_sqlite_direct_finalize(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) {
    return SQLITE_OK;
  }
  rc = sqlite3_finalize(stmt);
  ((eta_sqlite_direct_stmt *)Data_custom_val(v_stmt))->stmt = NULL;
  return rc;
}

CAMLprim value eta_sqlite_direct_finalize_bc(value v_stmt)
{
  return Val_int(eta_sqlite_direct_finalize(v_stmt));
}

CAMLprim intnat eta_sqlite_direct_reset(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_reset(stmt);
}

CAMLprim value eta_sqlite_direct_reset_bc(value v_stmt)
{
  return Val_int(eta_sqlite_direct_reset(v_stmt));
}

CAMLprim intnat eta_sqlite_direct_clear_bindings(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_clear_bindings(stmt);
}

CAMLprim value eta_sqlite_direct_clear_bindings_bc(value v_stmt)
{
  return Val_int(eta_sqlite_direct_clear_bindings(v_stmt));
}

CAMLprim intnat eta_sqlite_direct_bind_parameter_count(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_bind_parameter_count(stmt);
}

CAMLprim value eta_sqlite_direct_bind_parameter_count_bc(value v_stmt)
{
  return Val_int(eta_sqlite_direct_bind_parameter_count(v_stmt));
}

CAMLprim intnat eta_sqlite_direct_bind_null(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_null(stmt, (int)index);
}

CAMLprim value eta_sqlite_direct_bind_null_bc(value v_stmt, value v_index)
{
  return Val_int(eta_sqlite_direct_bind_null(v_stmt, Int_val(v_index)));
}

CAMLprim intnat eta_sqlite_direct_bind_int64(value v_stmt, intnat index, int64_t value)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_int64(stmt, (int)index, (sqlite3_int64)value);
}

CAMLprim value eta_sqlite_direct_bind_int64_bc(value v_stmt, value v_index, value v_value)
{
  return Val_int(eta_sqlite_direct_bind_int64(v_stmt, Int_val(v_index), Int64_val(v_value)));
}

CAMLprim intnat eta_sqlite_direct_bind_int(value v_stmt, intnat index, intnat value)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_int64(stmt, (int)index, (sqlite3_int64)value);
}

CAMLprim value eta_sqlite_direct_bind_int_bc(value v_stmt, value v_index, value v_value)
{
  return Val_int(eta_sqlite_direct_bind_int(v_stmt, Int_val(v_index), Int_val(v_value)));
}

CAMLprim intnat eta_sqlite_direct_bind_text(value v_stmt, intnat index, value v_text)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_text(
    stmt,
    (int)index,
    String_val(v_text),
    (int)caml_string_length(v_text),
    SQLITE_TRANSIENT);
}

CAMLprim value eta_sqlite_direct_bind_text_bc(value v_stmt, value v_index, value v_text)
{
  return Val_int(eta_sqlite_direct_bind_text(v_stmt, Int_val(v_index), v_text));
}

CAMLprim intnat eta_sqlite_direct_step(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  caml_enter_blocking_section();
  rc = sqlite3_step(stmt);
  caml_leave_blocking_section();
  return rc;
}

CAMLprim value eta_sqlite_direct_step_bc(value v_stmt)
{
  return Val_int(eta_sqlite_direct_step(v_stmt));
}

CAMLprim int64_t eta_sqlite_direct_column_int64(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_column_int64(stmt, (int)index);
}

CAMLprim value eta_sqlite_direct_column_int64_bc(value v_stmt, value v_index)
{
  return caml_copy_int64(eta_sqlite_direct_column_int64(v_stmt, Int_val(v_index)));
}

CAMLprim intnat eta_sqlite_direct_column_int(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return (intnat)sqlite3_column_int64(stmt, (int)index);
}

CAMLprim value eta_sqlite_direct_column_int_bc(value v_stmt, value v_index)
{
  return Val_int(eta_sqlite_direct_column_int(v_stmt, Int_val(v_index)));
}

CAMLprim value eta_sqlite_direct_column_text(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_direct_stmt_val(v_stmt);
  const unsigned char *text;
  int len;
  if (stmt == NULL) {
    caml_failwith("sqlite column_text: statement is finalized");
  }
  text = sqlite3_column_text(stmt, (int)index);
  len = sqlite3_column_bytes(stmt, (int)index);
  CAMLreturn(caml_alloc_initialized_string(len, text == NULL ? "" : (const char *)text));
}

CAMLprim value eta_sqlite_direct_column_text_bc(value v_stmt, value v_index)
{
  return eta_sqlite_direct_column_text(v_stmt, Int_val(v_index));
}

CAMLprim intnat eta_sqlite_direct_changes(value v_db)
{
  sqlite3 *db = eta_sqlite_direct_db_val(v_db);
  if (db == NULL) {
    return 0;
  }
  return sqlite3_changes(db);
}

CAMLprim value eta_sqlite_direct_changes_bc(value v_db)
{
  return Val_int(eta_sqlite_direct_changes(v_db));
}

CAMLprim value eta_sqlite_direct_error_message(value v_db)
{
  CAMLparam1(v_db);
  sqlite3 *db = eta_sqlite_direct_db_val(v_db);
  if (db == NULL) {
    CAMLreturn(caml_copy_string("database is closed"));
  }
  CAMLreturn(caml_copy_string(sqlite3_errmsg(db)));
}
