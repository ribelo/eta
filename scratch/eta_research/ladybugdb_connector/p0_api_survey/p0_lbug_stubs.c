/* P0 LadybugDB C API link probe — stubs for OCaml FFI.
   Confirms liblbug is reachable and functional via direct C stubs. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <lbug.h>
#include <stdio.h>
#include <string.h>

/* ---- Helper: raise Failure with context ---- */
static void fail_with_error(const char *context, const char *detail)
{
  char buffer[1024];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail ? detail : "unknown");
  caml_failwith(buffer);
}

/* ---- version : unit -> string ---- */
CAMLprim value eta_lbug_p0_version(value unit_value)
{
  CAMLparam1(unit_value);
  const char *ver = lbug_get_version();
  if (ver == NULL) {
    caml_failwith("lbug_get_version returned NULL");
  }
  value ret = caml_copy_string(ver);
  CAMLdrop;
  return ret;
}

/* ---- smoke_test : unit -> string ---- */
CAMLprim value eta_lbug_p0_smoke(value unit_value)
{
  CAMLparam1(unit_value);
  
  /* Open in-memory database */
  lbug_database db = {NULL};
  lbug_connection conn = {NULL};
  lbug_query_result result = {NULL, false};
  
  lbug_state state = lbug_database_init(":memory:", lbug_default_system_config(), &db);
  if (state != LbugSuccess) {
    fail_with_error("lbug_database_init", lbug_get_last_error());
  }
  
  state = lbug_connection_init(&db, &conn);
  if (state != LbugSuccess) {
    lbug_database_destroy(&db);
    fail_with_error("lbug_connection_init", lbug_get_last_error());
  }
  
  /* Create node table */
  state = lbug_connection_query(&conn, "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, PRIMARY KEY(id))", &result);
  if (state != LbugSuccess) {
    const char *err = lbug_get_last_error();
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("create table", err);
  }
  lbug_query_result_destroy(&result);
  
  /* Insert a node */
  state = lbug_connection_query(&conn, "CREATE (p:Person {id: 1, name: 'Alice', age: 30})", &result);
  if (state != LbugSuccess) {
    const char *err = lbug_get_last_error();
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("insert", err);
  }
  lbug_query_result_destroy(&result);
  
  /* Query count */
  state = lbug_connection_query(&conn, "MATCH (p:Person) RETURN count(p)", &result);
  if (state != LbugSuccess) {
    const char *err = lbug_get_last_error();
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("query", err);
  }
  
  /* Get the count value */
  lbug_flat_tuple tuple = {NULL, false};
  state = lbug_query_result_get_next(&result, &tuple);
  if (state != LbugSuccess) {
    lbug_query_result_destroy(&result);
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("get_next", "failed to get result");
  }
  
  lbug_value lval = {NULL, false};
  state = lbug_flat_tuple_get_value(&tuple, 0, &lval);
  if (state != LbugSuccess) {
    lbug_flat_tuple_destroy(&tuple);
    lbug_query_result_destroy(&result);
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("get_value", "failed to get value");
  }
  
  int64_t count = 0;
  state = lbug_value_get_int64(&lval, &count);
  if (state != LbugSuccess) {
    lbug_value_destroy(&lval);
    lbug_flat_tuple_destroy(&tuple);
    lbug_query_result_destroy(&result);
    lbug_connection_destroy(&conn);
    lbug_database_destroy(&db);
    fail_with_error("get_int64", "failed to get int64");
  }
  
  lbug_value_destroy(&lval);
  lbug_flat_tuple_destroy(&tuple);
  lbug_query_result_destroy(&result);
  lbug_connection_destroy(&conn);
  lbug_database_destroy(&db);
  
  char buffer[64];
  snprintf(buffer, sizeof(buffer), "p0_lbug_smoke=count:%lld", (long long)count);
  value ret = caml_copy_string(buffer);
  CAMLdrop;
  return ret;
}

/* ---- api_survey : unit -> string ---- */
CAMLprim value eta_lbug_p0_api_survey(value unit_value)
{
  CAMLparam1(unit_value);
  char buf[4096];
  int off = 0;

  off += snprintf(buf + off, sizeof(buf) - off,
    "=== LadybugDB C API Survey ===\n"
    "Version: %s\n\n"
    "--- Lifecycle ---\n"
    "  lbug_database_init / lbug_database_destroy  (Database)\n"
    "  lbug_connection_init / lbug_connection_destroy  (Connection)\n\n"
    "--- Query Execution ---\n"
    "  lbug_connection_query                       (Connection, cypher -> Result)\n"
    "  lbug_query_result_get_next                  (Result -> Tuple)\n"
    "  lbug_query_result_has_next                  (Result -> bool)\n\n"
    "--- Prepared Statements ---\n"
    "  lbug_connection_prepare                     (Connection, cypher -> PreparedStatement)\n"
    "  lbug_prepared_statement_bind_*              (bind parameters)\n"
    "  lbug_connection_execute                     (PreparedStatement -> Result)\n\n"
    "--- Result Access ---\n"
    "  lbug_flat_tuple_get_value                   (Tuple, idx -> Value)\n"
    "  lbug_value_get_*                            (extract typed values)\n\n"
    "--- Arrow Integration ---\n"
    "  lbug_query_result_get_arrow                 (Result -> ArrowArray, ArrowSchema)\n"
    "  Arrow C data interface for zero-copy access\n\n"
    "--- Types ---\n"
    "  NODE, REL, PATH, LIST, MAP, STRUCT\n"
    "  INT8, INT16, INT32, INT64, FLOAT, DOUBLE\n"
    "  STRING, BLOB, DATE, TIMESTAMP, INTERVAL\n"
    "  BOOL, NULL\n\n"
    "--- Key Features ---\n"
    "  Property Graph data model (nodes, relationships)\n"
    "  Cypher query language\n"
    "  Full text search (built-in)\n"
    "  Vector indices (built-in)\n"
    "  Columnar storage\n"
    "  Multi-core parallelism\n"
    "  ACID transactions\n\n"
    "--- Thread Safety ---\n"
    "  One Connection per thread\n"
    "  Multiple connections per Database\n",
    lbug_get_version()
  );

  value ret = caml_copy_string(buf);
  CAMLdrop;
  return ret;
}
