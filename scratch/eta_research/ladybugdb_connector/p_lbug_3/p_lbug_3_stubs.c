#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <lbug.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

struct buf {
  char data[32768];
  int off;
};

static void appendf(struct buf *b, const char *fmt, ...)
{
  if (b->off >= (int)sizeof(b->data)) return;
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(b->data + b->off, sizeof(b->data) - (size_t)b->off, fmt, args);
  va_end(args);
  if (n > 0) {
    b->off += n;
    if (b->off > (int)sizeof(b->data)) b->off = (int)sizeof(b->data);
  }
}

static void fail_lbug(const char *context)
{
  char *err = lbug_get_last_error();
  char msg[1024];
  snprintf(msg, sizeof(msg), "%s: %s", context, err ? err : "unknown");
  if (err) lbug_destroy_string(err);
  caml_failwith(msg);
}

static const char *state_name(lbug_state state)
{
  return state == LbugSuccess ? "LbugSuccess" : "LbugError";
}

static void check(lbug_state state, const char *context)
{
  if (state != LbugSuccess) fail_lbug(context);
}

static void exec_sql(lbug_connection *conn, const char *sql)
{
  lbug_query_result result = {NULL, false};
  check(lbug_connection_query(conn, sql, &result), sql);
  if (!lbug_query_result_is_success(&result)) {
    char *err = lbug_query_result_get_error_message(&result);
    char msg[1024];
    snprintf(msg, sizeof(msg), "%s result error: %s", sql, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    lbug_query_result_destroy(&result);
    caml_failwith(msg);
  }
  lbug_query_result_destroy(&result);
}

static void destroy_value_ptr(lbug_value *v)
{
  if (v != NULL) {
    lbug_value_destroy(v);
  }
}

static int64_t scalar_int64(lbug_query_result *result)
{
  lbug_flat_tuple tuple = {NULL, false};
  lbug_value value = {NULL, false};
  int64_t out = 0;
  check(lbug_query_result_get_next(result, &tuple), "get_next");
  check(lbug_flat_tuple_get_value(&tuple, 0, &value), "get_value");
  check(lbug_value_get_int64(&value, &out), "get_int64");
  lbug_value_destroy(&value);
  lbug_flat_tuple_destroy(&tuple);
  return out;
}

static bool scalar_bool(lbug_query_result *result)
{
  lbug_flat_tuple tuple = {NULL, false};
  lbug_value value = {NULL, false};
  bool out = false;
  check(lbug_query_result_get_next(result, &tuple), "get_next");
  check(lbug_flat_tuple_get_value(&tuple, 0, &value), "get_value");
  check(lbug_value_get_bool(&value, &out), "get_bool");
  lbug_value_destroy(&value);
  lbug_flat_tuple_destroy(&tuple);
  return out;
}

static void run_prepared(struct buf *b, lbug_connection *conn, const char *name,
    const char *query, void (*bind)(lbug_prepared_statement *stmt), int expect_count)
{
  lbug_prepared_statement stmt = {NULL, false};
  lbug_query_result result = {NULL, false};
  lbug_state state = lbug_connection_prepare(conn, query, &stmt);
  appendf(b, "%s.prepare_state=%s\n", name, state_name(state));
  if (state != LbugSuccess || !lbug_prepared_statement_is_success(&stmt)) {
    char *err = lbug_prepared_statement_get_error_message(&stmt);
    appendf(b, "%s.prepare_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    if (state == LbugSuccess) lbug_prepared_statement_destroy(&stmt);
    return;
  }

  bind(&stmt);
  state = lbug_connection_execute(conn, &stmt, &result);
  appendf(b, "%s.execute_state=%s\n", name, state_name(state));
  if (state != LbugSuccess || !lbug_query_result_is_success(&result)) {
    char *err = state == LbugSuccess ? lbug_query_result_get_error_message(&result) : lbug_get_last_error();
    appendf(b, "%s.execute_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
  } else {
    int64_t count = scalar_int64(&result);
    appendf(b, "%s.count=%lld\n", name, (long long)count);
    appendf(b, "%s.assertion=%s\n", name, count == expect_count ? "pass" : "fail");
  }
  if (state == LbugSuccess) lbug_query_result_destroy(&result);
  lbug_prepared_statement_destroy(&stmt);
}

static void run_prepared_bool(struct buf *b, lbug_connection *conn, const char *name,
    const char *query, void (*bind)(lbug_prepared_statement *stmt), bool expect)
{
  lbug_prepared_statement stmt = {NULL, false};
  lbug_query_result result = {NULL, false};
  lbug_state state = lbug_connection_prepare(conn, query, &stmt);
  appendf(b, "%s.prepare_state=%s\n", name, state_name(state));
  if (state != LbugSuccess || !lbug_prepared_statement_is_success(&stmt)) {
    char *err = lbug_prepared_statement_get_error_message(&stmt);
    appendf(b, "%s.prepare_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    if (state == LbugSuccess) lbug_prepared_statement_destroy(&stmt);
    return;
  }

  bind(&stmt);
  state = lbug_connection_execute(conn, &stmt, &result);
  appendf(b, "%s.execute_state=%s\n", name, state_name(state));
  if (state == LbugSuccess && lbug_query_result_is_success(&result)) {
    bool actual = scalar_bool(&result);
    appendf(b, "%s.value=%s\n", name, actual ? "true" : "false");
    appendf(b, "%s.assertion=%s\n", name, actual == expect ? "pass" : "fail");
  } else {
    char *err = state == LbugSuccess ? lbug_query_result_get_error_message(&result) : lbug_get_last_error();
    appendf(b, "%s.execute_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
  }
  if (state == LbugSuccess) lbug_query_result_destroy(&result);
  lbug_prepared_statement_destroy(&stmt);
}

static void run_prepared_success(struct buf *b, lbug_connection *conn, const char *name,
    const char *query, void (*bind)(lbug_prepared_statement *stmt))
{
  lbug_prepared_statement stmt = {NULL, false};
  lbug_query_result result = {NULL, false};
  lbug_state state = lbug_connection_prepare(conn, query, &stmt);
  appendf(b, "%s.prepare_state=%s\n", name, state_name(state));
  if (state != LbugSuccess || !lbug_prepared_statement_is_success(&stmt)) {
    char *err = lbug_prepared_statement_get_error_message(&stmt);
    appendf(b, "%s.prepare_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    if (state == LbugSuccess) lbug_prepared_statement_destroy(&stmt);
    return;
  }

  bind(&stmt);
  state = lbug_connection_execute(conn, &stmt, &result);
  appendf(b, "%s.execute_state=%s\n", name, state_name(state));
  if (state == LbugSuccess && lbug_query_result_is_success(&result)) {
    char *s = lbug_query_result_to_string(&result);
    appendf(b, "%s.result=%s\n", name, s ? s : "(null)");
    appendf(b, "%s.assertion=pass\n", name);
    if (s) lbug_destroy_string(s);
  } else {
    char *err = state == LbugSuccess ? lbug_query_result_get_error_message(&result) : lbug_get_last_error();
    appendf(b, "%s.execute_error=%s\n", name, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
  }
  if (state == LbugSuccess) lbug_query_result_destroy(&result);
  lbug_prepared_statement_destroy(&stmt);
}

static void bind_main(lbug_prepared_statement *stmt)
{
  check(lbug_prepared_statement_bind_string(stmt, "n", "Ada"), "bind n");
  check(lbug_prepared_statement_bind_int64(stmt, "a", 42), "bind a");
  check(lbug_prepared_statement_bind_double(stmt, "s", 99.5), "bind s");
  check(lbug_prepared_statement_bind_bool(stmt, "active", true), "bind active");
}

static void bind_empty(lbug_prepared_statement *stmt)
{
  check(lbug_prepared_statement_bind_string(stmt, "n", ""), "bind empty");
}

static void bind_long(lbug_prepared_statement *stmt)
{
  char s[2049];
  memset(s, 'x', sizeof(s) - 1);
  s[sizeof(s) - 1] = '\0';
  check(lbug_prepared_statement_bind_string(stmt, "n", s), "bind long");
}

static void bind_large(lbug_prepared_statement *stmt)
{
  check(lbug_prepared_statement_bind_int64(stmt, "id", 9223372036854775806LL), "bind large");
}

static void bind_null(lbug_prepared_statement *stmt)
{
  lbug_value *v = lbug_value_create_null();
  check(lbug_prepared_statement_bind_value(stmt, "nick", v), "bind null");
  destroy_value_ptr(v);
}

static void bind_list(lbug_prepared_statement *stmt)
{
  lbug_value *items[3];
  items[0] = lbug_value_create_int64(1);
  items[1] = lbug_value_create_int64(2);
  items[2] = lbug_value_create_int64(3);
  lbug_value *list = NULL;
  check(lbug_value_create_list(3, items, &list), "create list");
  check(lbug_prepared_statement_bind_value(stmt, "ids", list), "bind list");
  destroy_value_ptr(list);
  for (int i = 0; i < 3; i++) destroy_value_ptr(items[i]);
}

static void bind_map(lbug_prepared_statement *stmt)
{
  lbug_value *keys[2];
  lbug_value *vals[2];
  keys[0] = lbug_value_create_string("a");
  keys[1] = lbug_value_create_string("b");
  vals[0] = lbug_value_create_int64(10);
  vals[1] = lbug_value_create_int64(20);
  lbug_value *map = NULL;
  check(lbug_value_create_map(2, keys, vals, &map), "create map");
  check(lbug_prepared_statement_bind_value(stmt, "m", map), "bind map");
  destroy_value_ptr(map);
  for (int i = 0; i < 2; i++) {
    destroy_value_ptr(keys[i]);
    destroy_value_ptr(vals[i]);
  }
}

CAMLprim value eta_lbug_p3_run(value unit_value)
{
  CAMLparam1(unit_value);
  struct buf b = {{0}, 0};
  lbug_database db = {NULL};
  lbug_connection conn = {NULL};

  check(lbug_database_init(":memory:", lbug_default_system_config(), &db), "database_init");
  check(lbug_connection_init(&db, &conn), "connection_init");

  appendf(&b, "ladybug_version=%s\n", lbug_get_version());

  exec_sql(&conn,
      "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, score DOUBLE, active BOOL, nickname STRING, PRIMARY KEY(id))");
  exec_sql(&conn,
      "CREATE (:Person {id: 1, name: 'Ada', age: 42, score: 100.25, active: true, nickname: NULL})");
  exec_sql(&conn,
      "CREATE (:Person {id: 2, name: '', age: 1, score: 1.0, active: false, nickname: 'empty'})");

  char long_create[2300];
  memset(long_create, 0, sizeof(long_create));
  char long_name[2049];
  memset(long_name, 'x', sizeof(long_name) - 1);
  long_name[sizeof(long_name) - 1] = '\0';
  snprintf(long_create, sizeof(long_create),
      "CREATE (:Person {id: 3, name: '%s', age: 3, score: 3.0, active: true, nickname: 'long'})",
      long_name);
  exec_sql(&conn, long_create);
  exec_sql(&conn,
      "CREATE (:Person {id: 9223372036854775806, name: 'Max', age: 99, score: 9.0, active: true, nickname: 'large'})");

  run_prepared(&b, &conn, "primitive",
      "MATCH (p:Person {name: $n, age: $a, active: $active}) WHERE p.score > $s RETURN count(p)",
      bind_main, 1);
  run_prepared(&b, &conn, "empty_string",
      "MATCH (p:Person {name: $n}) RETURN count(p)", bind_empty, 1);
  run_prepared(&b, &conn, "long_string",
      "MATCH (p:Person {name: $n}) RETURN count(p)", bind_long, 1);
  run_prepared(&b, &conn, "large_int64",
      "MATCH (p:Person {id: $id}) RETURN count(p)", bind_large, 1);
  run_prepared_bool(&b, &conn, "null_optional",
      "RETURN $nick IS NULL", bind_null, true);
  run_prepared(&b, &conn, "list_value",
      "UNWIND $ids AS id MATCH (p:Person {id: id}) RETURN count(p)", bind_list, 3);
  run_prepared_success(&b, &conn, "map_value",
      "RETURN $m", bind_map);

  appendf(&b, "bytes_parameter.status=Untested\n");
  appendf(&b, "bytes_parameter.blocker=no lbug_value_create_blob or prepared_statement_bind_blob symbol in c_api/lbug.h\n");

  lbug_connection_destroy(&conn);
  lbug_database_destroy(&db);

  value ret = caml_copy_string(b.data);
  CAMLreturn(ret);
}
