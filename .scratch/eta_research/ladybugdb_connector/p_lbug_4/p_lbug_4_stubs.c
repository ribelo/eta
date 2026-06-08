#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <lbug.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

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

static void check(lbug_state state, const char *context)
{
  if (state != LbugSuccess) fail_lbug(context);
}

static const char *state_name(lbug_state state)
{
  return state == LbugSuccess ? "LbugSuccess" : "LbugError";
}

static void report_query(struct buf *b, lbug_connection *conn, const char *label, const char *query)
{
  lbug_query_result result = {NULL, false};
  lbug_state state = lbug_connection_query(conn, query, &result);
  bool success = state == LbugSuccess && lbug_query_result_is_success(&result);
  appendf(b, "%s.state=%s\n", label, state_name(state));
  appendf(b, "%s.success=%s\n", label, success ? "true" : "false");
  if (!success) {
    char *err = state == LbugSuccess ? lbug_query_result_get_error_message(&result) : lbug_get_last_error();
    appendf(b, "%s.error=%s\n", label, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    if (result._query_result != NULL) {
      char *result_err = lbug_query_result_get_error_message(&result);
      appendf(b, "%s.result_error=%s\n", label, result_err ? result_err : "unknown");
      if (result_err) lbug_destroy_string(result_err);
    } else {
      appendf(b, "%s.result_error=(no result handle)\n", label);
    }
  }
  if (state == LbugSuccess) lbug_query_result_destroy(&result);
}

static void exec_ok(lbug_connection *conn, const char *query)
{
  lbug_query_result result = {NULL, false};
  check(lbug_connection_query(conn, query, &result), query);
  if (!lbug_query_result_is_success(&result)) {
    char *err = lbug_query_result_get_error_message(&result);
    char msg[1024];
    snprintf(msg, sizeof(msg), "%s: %s", query, err ? err : "unknown");
    if (err) lbug_destroy_string(err);
    lbug_query_result_destroy(&result);
    caml_failwith(msg);
  }
  lbug_query_result_destroy(&result);
}

static void report_closed_handle_child(struct buf *b)
{
  pid_t pid = fork();
  if (pid == 0) {
    lbug_database db = {NULL};
    lbug_connection conn = {NULL};
    lbug_query_result result = {NULL, false};
    if (lbug_database_init(":memory:", lbug_default_system_config(), &db) != LbugSuccess) _exit(101);
    if (lbug_connection_init(&db, &conn) != LbugSuccess) _exit(102);
    lbug_connection_destroy(&conn);
    lbug_state state = lbug_connection_query(&conn, "RETURN 1", &result);
    if (state == LbugSuccess) lbug_query_result_destroy(&result);
    lbug_database_destroy(&db);
    _exit(state == LbugSuccess ? 0 : 10);
  }

  int status = 0;
  waitpid(pid, &status, 0);
  if (WIFSIGNALED(status)) {
    appendf(b, "closed_connection_child.signal=%d\n", WTERMSIG(status));
    appendf(b, "closed_connection_child.class=unsafe_handle_crash\n");
  } else {
    int code = WEXITSTATUS(status);
    appendf(b, "closed_connection_child.exit=%d\n", code);
    appendf(b, "closed_connection_child.class=%s\n",
        code == 0 ? "unexpected_success" : "closed_handle_error_or_setup_failure");
  }
}

CAMLprim value eta_lbug_p4_run(value unit_value)
{
  CAMLparam1(unit_value);
  struct buf b = {{0}, 0};
  lbug_database db = {NULL};
  lbug_connection conn = {NULL};

  check(lbug_database_init(":memory:", lbug_default_system_config(), &db), "database_init");
  check(lbug_connection_init(&db, &conn), "connection_init");

  appendf(&b, "ladybug_version=%s\n", lbug_get_version());

  exec_ok(&conn, "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, PRIMARY KEY(id))");
  exec_ok(&conn, "CREATE (:Person {id: 1, name: 'Ada', age: 42})");
  exec_ok(&conn, "CREATE NODE TABLE N(id INT64, PRIMARY KEY(id))");
  exec_ok(&conn, "UNWIND range(1, 20000) AS i CREATE (:N {id: i})");

  report_query(&b, &conn, "syntax_error", "MATCH (p:Person RETURN p");
  report_query(&b, &conn, "type_mismatch", "MATCH (p:Person) WHERE p.age + 'x' > 1 RETURN p");
  report_query(&b, &conn, "integrity_violation", "CREATE (:Person {id: 1, name: 'Dup', age: 1})");

  check(lbug_connection_set_query_timeout(&conn, 1), "set timeout");
  report_query(&b, &conn, "timeout_interrupt", "MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id)");
  check(lbug_connection_set_query_timeout(&conn, 0), "clear timeout");

  report_closed_handle_child(&b);

  appendf(&b, "recommended_error_variant=Connection_closed_or_invalid | Query_syntax | Type_mismatch | Integrity_violation | Timeout_or_interrupt | Other\n");

  lbug_connection_destroy(&conn);
  lbug_database_destroy(&db);

  value ret = caml_copy_string(b.data);
  CAMLreturn(ret);
}
