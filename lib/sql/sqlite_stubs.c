#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <sqlite3.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  sqlite3 *db;
} eta_sqlite_db;

typedef struct {
  sqlite3_stmt *stmt;
} eta_sqlite_stmt;

static void eta_sqlite_finalize_db(value v_db)
{
  eta_sqlite_db *db = (eta_sqlite_db *)Data_custom_val(v_db);
  if (db->db != NULL) {
    /* Custom finalizers run from the OCaml runtime's finalization path; entering
       a blocking section here aborts under OCaml 5. Explicit close functions
       below release the runtime lock, so finalization is only a last-resort
       cleanup path for leaked handles. */
    (void)sqlite3_close_v2(db->db);
    db->db = NULL;
  }
}

static void eta_sqlite_finalize_stmt(value v_stmt)
{
  eta_sqlite_stmt *stmt = (eta_sqlite_stmt *)Data_custom_val(v_stmt);
  if (stmt->stmt != NULL) {
    /* See eta_sqlite_finalize_db: explicit statement finalization releases the
       runtime lock; the custom finalizer must stay within runtime finalizer
       constraints. */
    (void)sqlite3_finalize(stmt->stmt);
    stmt->stmt = NULL;
  }
}

static struct custom_operations eta_sqlite_db_ops = {
  "eta.sqlite.db",
  eta_sqlite_finalize_db,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations eta_sqlite_stmt_ops = {
  "eta.sqlite.stmt",
  eta_sqlite_finalize_stmt,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static sqlite3 *eta_sqlite_db_val(value v_db)
{
  eta_sqlite_db *db = (eta_sqlite_db *)Data_custom_val(v_db);
  return db->db;
}

static sqlite3_stmt *eta_sqlite_stmt_val(value v_stmt)
{
  eta_sqlite_stmt *stmt = (eta_sqlite_stmt *)Data_custom_val(v_stmt);
  return stmt->stmt;
}

static char *eta_sqlite_copy_ocaml_string(value v_string, size_t *len_out)
{
  mlsize_t len = caml_string_length(v_string);
  char *copy = malloc((size_t)len + 1);
  if (copy == NULL) {
    return NULL;
  }
  memcpy(copy, String_val(v_string), (size_t)len);
  copy[len] = '\0';
  if (len_out != NULL) {
    *len_out = (size_t)len;
  }
  return copy;
}

CAMLprim intnat eta_sqlite_rc_ok(value v_unit)
{
  (void)v_unit;
  return SQLITE_OK;
}

CAMLprim value eta_sqlite_rc_ok_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_OK);
}

CAMLprim intnat eta_sqlite_rc_row(value v_unit)
{
  (void)v_unit;
  return SQLITE_ROW;
}

CAMLprim value eta_sqlite_rc_row_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_ROW);
}

CAMLprim intnat eta_sqlite_rc_done(value v_unit)
{
  (void)v_unit;
  return SQLITE_DONE;
}

CAMLprim value eta_sqlite_rc_done_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_DONE);
}

CAMLprim intnat eta_sqlite_rc_misuse(value v_unit)
{
  (void)v_unit;
  return SQLITE_MISUSE;
}

CAMLprim value eta_sqlite_rc_misuse_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_MISUSE);
}

CAMLprim intnat eta_sqlite_rc_range(value v_unit)
{
  (void)v_unit;
  return SQLITE_RANGE;
}

CAMLprim value eta_sqlite_rc_range_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_RANGE);
}

CAMLprim intnat eta_sqlite_rc_constraint(value v_unit)
{
  (void)v_unit;
  return SQLITE_CONSTRAINT;
}

CAMLprim value eta_sqlite_rc_constraint_bc(value v_unit)
{
  (void)v_unit;
  return Val_int(SQLITE_CONSTRAINT);
}

static int eta_sqlite_flags_of_mode(intnat mode)
{
  switch (mode) {
  case 0:
    return SQLITE_OPEN_READONLY | SQLITE_OPEN_URI;
  case 1:
    return SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI;
  default:
    return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI;
  }
}

CAMLprim value eta_sqlite_open(value v_path, intnat mode)
{
  CAMLparam1(v_path);
  CAMLlocal1(v_block);
  sqlite3 *db = NULL;
  char *path = eta_sqlite_copy_ocaml_string(v_path, NULL);
  int rc;
  if (path == NULL) {
    caml_failwith("sqlite open: out of memory");
  }
  caml_enter_blocking_section();
  rc = sqlite3_open_v2(path, &db, eta_sqlite_flags_of_mode(mode), NULL);
  caml_leave_blocking_section();
  free(path);
  if (rc != SQLITE_OK) {
    const char *message = db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db);
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "sqlite open: %s", message);
    if (db != NULL) {
      (void)sqlite3_close_v2(db);
    }
    caml_failwith(buffer);
  }

  v_block = caml_alloc_custom(&eta_sqlite_db_ops, sizeof(eta_sqlite_db), 0, 1);
  ((eta_sqlite_db *)Data_custom_val(v_block))->db = db;
  CAMLreturn(v_block);
}

CAMLprim value eta_sqlite_open_bc(value v_path, value v_mode)
{
  return eta_sqlite_open(v_path, Int_val(v_mode));
}

CAMLprim intnat eta_sqlite_close(value v_db)
{
  CAMLparam1(v_db);
  sqlite3 *db = eta_sqlite_db_val(v_db);
  int rc;
  if (db == NULL) {
    CAMLreturnT(intnat, SQLITE_OK);
  }
  caml_enter_blocking_section();
  rc = sqlite3_close_v2(db);
  caml_leave_blocking_section();
  if (rc == SQLITE_OK) {
    ((eta_sqlite_db *)Data_custom_val(v_db))->db = NULL;
  }
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_close_bc(value v_db)
{
  return Val_int(eta_sqlite_close(v_db));
}

CAMLprim intnat eta_sqlite_busy_timeout(value v_db, intnat ms)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_busy_timeout(db, (int)ms);
}

CAMLprim value eta_sqlite_busy_timeout_bc(value v_db, value v_ms)
{
  return Val_int(eta_sqlite_busy_timeout(v_db, Int_val(v_ms)));
}

CAMLprim intnat eta_sqlite_exec_script(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  sqlite3 *db = eta_sqlite_db_val(v_db);
  char *sql;
  char *errmsg = NULL;
  int rc;
  if (db == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  sql = eta_sqlite_copy_ocaml_string(v_sql, NULL);
  if (sql == NULL) {
    CAMLreturnT(intnat, SQLITE_NOMEM);
  }
  caml_enter_blocking_section();
  rc = sqlite3_exec(db, sql, NULL, NULL, &errmsg);
  caml_leave_blocking_section();
  free(sql);
  if (errmsg != NULL) {
    sqlite3_free(errmsg);
  }
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_exec_script_bc(value v_db, value v_sql)
{
  return Val_int(eta_sqlite_exec_script(v_db, v_sql));
}

CAMLprim value eta_sqlite_prepare(value v_db, value v_sql)
{
  CAMLparam2(v_db, v_sql);
  CAMLlocal1(v_stmt);
  sqlite3 *db = eta_sqlite_db_val(v_db);
  sqlite3_stmt *stmt = NULL;
  size_t sql_len;
  char *sql;
  int rc;
  if (db == NULL) {
    caml_failwith("sqlite prepare: database is closed");
  }
  sql = eta_sqlite_copy_ocaml_string(v_sql, &sql_len);
  if (sql == NULL) {
    caml_failwith("sqlite prepare: out of memory");
  }
  if (sql_len > INT_MAX) {
    free(sql);
    caml_failwith("sqlite prepare: SQL string too long");
  }
  caml_enter_blocking_section();
  rc = sqlite3_prepare_v2(db, sql, (int)sql_len, &stmt, NULL);
  caml_leave_blocking_section();
  free(sql);
  if (rc != SQLITE_OK || stmt == NULL) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "sqlite prepare: %s", sqlite3_errmsg(db));
    caml_failwith(buffer);
  }

  v_stmt = caml_alloc_custom(&eta_sqlite_stmt_ops, sizeof(eta_sqlite_stmt), 0, 1);
  ((eta_sqlite_stmt *)Data_custom_val(v_stmt))->stmt = stmt;
  CAMLreturn(v_stmt);
}

CAMLprim intnat eta_sqlite_finalize(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) {
    CAMLreturnT(intnat, SQLITE_OK);
  }
  caml_enter_blocking_section();
  rc = sqlite3_finalize(stmt);
  caml_leave_blocking_section();
  ((eta_sqlite_stmt *)Data_custom_val(v_stmt))->stmt = NULL;
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_finalize_bc(value v_stmt)
{
  return Val_int(eta_sqlite_finalize(v_stmt));
}

CAMLprim intnat eta_sqlite_reset(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  caml_enter_blocking_section();
  rc = sqlite3_reset(stmt);
  caml_leave_blocking_section();
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_reset_bc(value v_stmt)
{
  return Val_int(eta_sqlite_reset(v_stmt));
}

CAMLprim intnat eta_sqlite_clear_bindings(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_clear_bindings(stmt);
}

CAMLprim value eta_sqlite_clear_bindings_bc(value v_stmt)
{
  return Val_int(eta_sqlite_clear_bindings(v_stmt));
}

CAMLprim intnat eta_sqlite_bind_parameter_count(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_bind_parameter_count(stmt);
}

CAMLprim value eta_sqlite_bind_parameter_count_bc(value v_stmt)
{
  return Val_int(eta_sqlite_bind_parameter_count(v_stmt));
}

CAMLprim intnat eta_sqlite_bind_null(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_null(stmt, (int)index);
}

CAMLprim value eta_sqlite_bind_null_bc(value v_stmt, value v_index)
{
  return Val_int(eta_sqlite_bind_null(v_stmt, Int_val(v_index)));
}

CAMLprim intnat eta_sqlite_bind_int64(value v_stmt, intnat index, int64_t value)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_int64(stmt, (int)index, (sqlite3_int64)value);
}

CAMLprim value eta_sqlite_bind_int64_bc(value v_stmt, value v_index, value v_value)
{
  return Val_int(eta_sqlite_bind_int64(v_stmt, Int_val(v_index), Int64_val(v_value)));
}

CAMLprim intnat eta_sqlite_bind_int(value v_stmt, intnat index, intnat value)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_int64(stmt, (int)index, (sqlite3_int64)value);
}

CAMLprim value eta_sqlite_bind_int_bc(value v_stmt, value v_index, value v_value)
{
  return Val_int(eta_sqlite_bind_int(v_stmt, Int_val(v_index), Int_val(v_value)));
}

CAMLprim intnat eta_sqlite_bind_text(value v_stmt, intnat index, value v_text)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
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

CAMLprim value eta_sqlite_bind_text_bc(value v_stmt, value v_index, value v_text)
{
  return Val_int(eta_sqlite_bind_text(v_stmt, Int_val(v_index), v_text));
}

CAMLprim intnat eta_sqlite_bind_float(value v_stmt, intnat index, double value)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_double(stmt, (int)index, value);
}

CAMLprim value eta_sqlite_bind_float_bc(value v_stmt, value v_index, value v_value)
{
  return Val_int(eta_sqlite_bind_float(v_stmt, Int_val(v_index), Double_val(v_value)));
}

CAMLprim intnat eta_sqlite_bind_blob(value v_stmt, intnat index, value v_blob)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_blob(
    stmt,
    (int)index,
    Bytes_val(v_blob),
    (int)caml_string_length(v_blob),
    SQLITE_TRANSIENT);
}

CAMLprim value eta_sqlite_bind_blob_bc(value v_stmt, value v_index, value v_blob)
{
  return Val_int(eta_sqlite_bind_blob(v_stmt, Int_val(v_index), v_blob));
}

CAMLprim intnat eta_sqlite_bind_zeroblob(value v_stmt, intnat index, intnat size)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_bind_zeroblob(stmt, (int)index, (int)size);
}

CAMLprim value eta_sqlite_bind_zeroblob_bc(value v_stmt, value v_index, value v_size)
{
  return Val_int(eta_sqlite_bind_zeroblob(v_stmt, Int_val(v_index), Int_val(v_size)));
}

CAMLprim intnat eta_sqlite_step(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  int rc;
  if (stmt == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  caml_enter_blocking_section();
  rc = sqlite3_step(stmt);
  caml_leave_blocking_section();
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_step_bc(value v_stmt)
{
  return Val_int(eta_sqlite_step(v_stmt));
}

CAMLprim int64_t eta_sqlite_column_int64(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_column_int64(stmt, (int)index);
}

CAMLprim value eta_sqlite_column_int64_bc(value v_stmt, value v_index)
{
  return caml_copy_int64(eta_sqlite_column_int64(v_stmt, Int_val(v_index)));
}

CAMLprim intnat eta_sqlite_column_int(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return (intnat)sqlite3_column_int64(stmt, (int)index);
}

CAMLprim value eta_sqlite_column_int_bc(value v_stmt, value v_index)
{
  return Val_int(eta_sqlite_column_int(v_stmt, Int_val(v_index)));
}

CAMLprim value eta_sqlite_column_text(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  const unsigned char *text;
  int len;
  if (stmt == NULL) {
    caml_failwith("sqlite column_text: statement is finalized");
  }
  text = sqlite3_column_text(stmt, (int)index);
  len = sqlite3_column_bytes(stmt, (int)index);
  CAMLreturn(caml_alloc_initialized_string(len, text == NULL ? "" : (const char *)text));
}

CAMLprim value eta_sqlite_column_text_bc(value v_stmt, value v_index)
{
  return eta_sqlite_column_text(v_stmt, Int_val(v_index));
}

CAMLprim double eta_sqlite_column_float(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0.0;
  }
  return sqlite3_column_double(stmt, (int)index);
}

CAMLprim value eta_sqlite_column_float_bc(value v_stmt, value v_index)
{
  return caml_copy_double(eta_sqlite_column_float(v_stmt, Int_val(v_index)));
}

CAMLprim value eta_sqlite_column_blob(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  const void *blob;
  int len;
  if (stmt == NULL) {
    caml_failwith("sqlite column_blob: statement is finalized");
  }
  blob = sqlite3_column_blob(stmt, (int)index);
  len = sqlite3_column_bytes(stmt, (int)index);
  CAMLreturn(caml_alloc_initialized_string(len, blob == NULL ? "" : (const char *)blob));
}

CAMLprim value eta_sqlite_column_blob_bc(value v_stmt, value v_index)
{
  return eta_sqlite_column_blob(v_stmt, Int_val(v_index));
}

CAMLprim value eta_sqlite_column_is_null(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return Val_true;
  }
  return Val_bool(sqlite3_column_type(stmt, (int)index) == SQLITE_NULL);
}

CAMLprim value eta_sqlite_column_is_null_bc(value v_stmt, value v_index)
{
  return eta_sqlite_column_is_null(v_stmt, Int_val(v_index));
}

CAMLprim intnat eta_sqlite_column_count(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_column_count(stmt);
}

CAMLprim value eta_sqlite_column_count_bc(value v_stmt)
{
  return Val_int(eta_sqlite_column_count(v_stmt));
}

CAMLprim value eta_sqlite_column_name(value v_stmt, intnat index)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  const char *name;
  if (stmt == NULL) {
    caml_failwith("sqlite column_name: statement is finalized");
  }
  name = sqlite3_column_name(stmt, (int)index);
  CAMLreturn(caml_copy_string(name == NULL ? "" : name));
}

CAMLprim value eta_sqlite_column_name_bc(value v_stmt, value v_index)
{
  return eta_sqlite_column_name(v_stmt, Int_val(v_index));
}

CAMLprim intnat eta_sqlite_column_type_code(value v_stmt, intnat index)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return SQLITE_NULL;
  }
  return sqlite3_column_type(stmt, (int)index);
}

CAMLprim value eta_sqlite_column_type_code_bc(value v_stmt, value v_index)
{
  return Val_int(eta_sqlite_column_type_code(v_stmt, Int_val(v_index)));
}

CAMLprim intnat eta_sqlite_data_count(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return 0;
  }
  return sqlite3_data_count(stmt);
}

CAMLprim value eta_sqlite_data_count_bc(value v_stmt)
{
  return Val_int(eta_sqlite_data_count(v_stmt));
}

CAMLprim value eta_sqlite_statement_sql(value v_stmt)
{
  CAMLparam1(v_stmt);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  const char *sql;
  if (stmt == NULL) {
    caml_failwith("sqlite statement_sql: statement is finalized");
  }
  sql = sqlite3_sql(stmt);
  CAMLreturn(caml_copy_string(sql == NULL ? "" : sql));
}

CAMLprim value eta_sqlite_expanded_sql(value v_stmt)
{
  CAMLparam1(v_stmt);
  CAMLlocal1(result);
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  char *sql;
  if (stmt == NULL) {
    caml_failwith("sqlite expanded_sql: statement is finalized");
  }
  sql = sqlite3_expanded_sql(stmt);
  result = caml_copy_string(sql == NULL ? "" : sql);
  if (sql != NULL) {
    sqlite3_free(sql);
  }
  CAMLreturn(result);
}

CAMLprim value eta_sqlite_statement_readonly(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return Val_false;
  }
  return Val_bool(sqlite3_stmt_readonly(stmt));
}

CAMLprim value eta_sqlite_statement_readonly_bc(value v_stmt)
{
  return eta_sqlite_statement_readonly(v_stmt);
}

CAMLprim value eta_sqlite_statement_busy(value v_stmt)
{
  sqlite3_stmt *stmt = eta_sqlite_stmt_val(v_stmt);
  if (stmt == NULL) {
    return Val_false;
  }
  return Val_bool(sqlite3_stmt_busy(stmt));
}

CAMLprim value eta_sqlite_statement_busy_bc(value v_stmt)
{
  return eta_sqlite_statement_busy(v_stmt);
}

CAMLprim intnat eta_sqlite_changes(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return 0;
  }
  return sqlite3_changes(db);
}

CAMLprim value eta_sqlite_changes_bc(value v_db)
{
  return Val_int(eta_sqlite_changes(v_db));
}

CAMLprim intnat eta_sqlite_total_changes(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return 0;
  }
  return sqlite3_total_changes(db);
}

CAMLprim value eta_sqlite_total_changes_bc(value v_db)
{
  return Val_int(eta_sqlite_total_changes(v_db));
}

CAMLprim int64_t eta_sqlite_last_insert_rowid(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return 0;
  }
  return sqlite3_last_insert_rowid(db);
}

CAMLprim value eta_sqlite_last_insert_rowid_bc(value v_db)
{
  return caml_copy_int64(eta_sqlite_last_insert_rowid(v_db));
}

CAMLprim intnat eta_sqlite_error_code(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_errcode(db);
}

CAMLprim value eta_sqlite_error_code_bc(value v_db)
{
  return Val_int(eta_sqlite_error_code(v_db));
}

CAMLprim intnat eta_sqlite_extended_error_code(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_extended_errcode(db);
}

CAMLprim value eta_sqlite_extended_error_code_bc(value v_db)
{
  return Val_int(eta_sqlite_extended_error_code(v_db));
}

CAMLprim value eta_sqlite_error_message(value v_db)
{
  CAMLparam1(v_db);
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    CAMLreturn(caml_copy_string("database is closed"));
  }
  CAMLreturn(caml_copy_string(sqlite3_errmsg(db)));
}

CAMLprim value eta_sqlite_autocommit(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return Val_true;
  }
  return Val_bool(sqlite3_get_autocommit(db));
}

CAMLprim value eta_sqlite_autocommit_bc(value v_db)
{
  return eta_sqlite_autocommit(v_db);
}

CAMLprim value eta_sqlite_database_readonly(value v_db, value v_name)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  int rc;
  if (db == NULL) {
    return Val_false;
  }
  rc = sqlite3_db_readonly(db, String_val(v_name));
  return Val_bool(rc > 0);
}

CAMLprim value eta_sqlite_database_readonly_bc(value v_db, value v_name)
{
  return eta_sqlite_database_readonly(v_db, v_name);
}

CAMLprim value eta_sqlite_interrupt(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db != NULL) {
    sqlite3_interrupt(db);
  }
  return Val_unit;
}

CAMLprim value eta_sqlite_is_interrupted(value v_db)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return Val_false;
  }
  return Val_bool(sqlite3_is_interrupted(db));
}

CAMLprim value eta_sqlite_is_interrupted_bc(value v_db)
{
  return eta_sqlite_is_interrupted(v_db);
}

CAMLprim value eta_sqlite_complete(value v_sql)
{
  return Val_bool(sqlite3_complete(String_val(v_sql)));
}

CAMLprim value eta_sqlite_complete_bc(value v_sql)
{
  return eta_sqlite_complete(v_sql);
}

CAMLprim intnat eta_sqlite_enable_load_extension(value v_db, value v_on)
{
  sqlite3 *db = eta_sqlite_db_val(v_db);
  if (db == NULL) {
    return SQLITE_MISUSE;
  }
  return sqlite3_enable_load_extension(db, Bool_val(v_on));
}

CAMLprim value eta_sqlite_enable_load_extension_bc(value v_db, value v_on)
{
  return Val_int(eta_sqlite_enable_load_extension(v_db, v_on));
}

CAMLprim intnat eta_sqlite_load_extension(value v_db, value v_path)
{
  CAMLparam2(v_db, v_path);
  sqlite3 *db = eta_sqlite_db_val(v_db);
  char *path;
  char *errmsg = NULL;
  int rc;
  if (db == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  path = eta_sqlite_copy_ocaml_string(v_path, NULL);
  if (path == NULL) {
    CAMLreturnT(intnat, SQLITE_NOMEM);
  }
  caml_enter_blocking_section();
  rc = sqlite3_load_extension(db, path, NULL, &errmsg);
  caml_leave_blocking_section();
  free(path);
  if (errmsg != NULL) {
    sqlite3_free(errmsg);
  }
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_load_extension_bc(value v_db, value v_path)
{
  return Val_int(eta_sqlite_load_extension(v_db, v_path));
}

static int eta_sqlite_backup_between(sqlite3 *dst, sqlite3 *src)
{
  sqlite3_backup *backup = sqlite3_backup_init(dst, "main", src, "main");
  int rc;
  if (backup == NULL) {
    return sqlite3_errcode(dst);
  }
  do {
    rc = sqlite3_backup_step(backup, 128);
  } while (rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED);
  if (rc == SQLITE_DONE) {
    rc = SQLITE_OK;
  }
  {
    int finish_rc = sqlite3_backup_finish(backup);
    if (rc == SQLITE_OK && finish_rc != SQLITE_OK) {
      rc = finish_rc;
    }
  }
  return rc;
}

CAMLprim intnat eta_sqlite_backup_to_path(value v_db, value v_path)
{
  CAMLparam2(v_db, v_path);
  sqlite3 *src = eta_sqlite_db_val(v_db);
  sqlite3 *dst = NULL;
  char *path;
  int rc;
  if (src == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  path = eta_sqlite_copy_ocaml_string(v_path, NULL);
  if (path == NULL) {
    CAMLreturnT(intnat, SQLITE_NOMEM);
  }
  caml_enter_blocking_section();
  rc = sqlite3_open_v2(path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
  if (rc != SQLITE_OK) {
    if (dst != NULL) {
      (void)sqlite3_close_v2(dst);
    }
    caml_leave_blocking_section();
    free(path);
    CAMLreturnT(intnat, rc);
  }
  rc = eta_sqlite_backup_between(dst, src);
  (void)sqlite3_close_v2(dst);
  caml_leave_blocking_section();
  free(path);
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_backup_to_path_bc(value v_db, value v_path)
{
  return Val_int(eta_sqlite_backup_to_path(v_db, v_path));
}

CAMLprim intnat eta_sqlite_restore_from_path(value v_db, value v_path)
{
  CAMLparam2(v_db, v_path);
  sqlite3 *dst = eta_sqlite_db_val(v_db);
  sqlite3 *src = NULL;
  char *path;
  int rc;
  if (dst == NULL) {
    CAMLreturnT(intnat, SQLITE_MISUSE);
  }
  path = eta_sqlite_copy_ocaml_string(v_path, NULL);
  if (path == NULL) {
    CAMLreturnT(intnat, SQLITE_NOMEM);
  }
  caml_enter_blocking_section();
  rc = sqlite3_open_v2(path, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
  if (rc != SQLITE_OK) {
    if (src != NULL) {
      (void)sqlite3_close_v2(src);
    }
    caml_leave_blocking_section();
    free(path);
    CAMLreturnT(intnat, rc);
  }
  rc = eta_sqlite_backup_between(dst, src);
  (void)sqlite3_close_v2(src);
  caml_leave_blocking_section();
  free(path);
  CAMLreturnT(intnat, rc);
}

CAMLprim value eta_sqlite_restore_from_path_bc(value v_db, value v_path)
{
  return Val_int(eta_sqlite_restore_from_path(v_db, v_path));
}
