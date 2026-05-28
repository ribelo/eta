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
  if (b->off >= (int)sizeof(b->data)) {
    return;
  }
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(b->data + b->off, sizeof(b->data) - (size_t)b->off, fmt, args);
  va_end(args);
  if (n > 0) {
    b->off += n;
    if (b->off > (int)sizeof(b->data)) {
      b->off = (int)sizeof(b->data);
    }
  }
}

static void fail_lbug(const char *context)
{
  char *err = lbug_get_last_error();
  char msg[1024];
  snprintf(msg, sizeof(msg), "%s: %s", context, err ? err : "unknown");
  if (err) {
    lbug_destroy_string(err);
  }
  caml_failwith(msg);
}

static void check(lbug_state state, const char *context)
{
  if (state != LbugSuccess) {
    fail_lbug(context);
  }
}

static void dump_schema(struct buf *b, struct ArrowSchema *schema, int depth)
{
  if (schema == NULL) {
    appendf(b, "%*s(schema null)\n", depth * 2, "");
    return;
  }
  appendf(b, "%*sschema name=%s format=%s flags=%lld children=%lld metadata=%s release=%p\n",
      depth * 2, "",
      schema->name ? schema->name : "(null)",
      schema->format ? schema->format : "(null)",
      (long long)schema->flags,
      (long long)schema->n_children,
      schema->metadata ? schema->metadata : "(null)",
      (void*)schema->release);
  for (int64_t i = 0; i < schema->n_children; i++) {
    appendf(b, "%*schild[%lld]:\n", depth * 2, "", (long long)i);
    dump_schema(b, schema->children[i], depth + 1);
  }
}

static void dump_array(struct buf *b, struct ArrowArray *array, int depth)
{
  if (array == NULL) {
    appendf(b, "%*s(array null)\n", depth * 2, "");
    return;
  }
  appendf(b,
      "%*sarray length=%lld nulls=%lld offset=%lld buffers=%lld children=%lld release=%p\n",
      depth * 2, "",
      (long long)array->length,
      (long long)array->null_count,
      (long long)array->offset,
      (long long)array->n_buffers,
      (long long)array->n_children,
      (void*)array->release);
  for (int64_t i = 0; i < array->n_buffers; i++) {
    appendf(b, "%*sbuffer[%lld]=%p\n", depth * 2, "", (long long)i,
        array->buffers ? array->buffers[i] : NULL);
  }
  for (int64_t i = 0; i < array->n_children; i++) {
    appendf(b, "%*schild[%lld]:\n", depth * 2, "", (long long)i);
    dump_array(b, array->children[i], depth + 1);
  }
}

static int64_t read_i64(struct ArrowArray *array, int64_t row)
{
  const int64_t *values = (const int64_t*)array->buffers[1];
  return values[array->offset + row];
}

static int read_bool(struct ArrowArray *array, int64_t row)
{
  const uint8_t *bits = (const uint8_t*)array->buffers[1];
  int64_t bit = array->offset + row;
  return (bits[bit / 8] >> (bit % 8)) & 1;
}

static void read_utf8(struct ArrowArray *array, int64_t row, char *out, size_t out_len)
{
  const int32_t *offsets = (const int32_t*)array->buffers[1];
  const char *bytes = (const char*)array->buffers[2];
  int64_t logical_row = array->offset + row;
  int32_t start = offsets[logical_row];
  int32_t end = offsets[logical_row + 1];
  size_t len = (size_t)(end - start);
  if (len >= out_len) {
    len = out_len - 1;
  }
  memcpy(out, bytes + start, len);
  out[len] = '\0';
}

static void decode_node(struct buf *b, struct ArrowSchema *schema, struct ArrowArray *array)
{
  if (schema->n_children != 1 || array->n_children != 1) {
    appendf(b, "\ndecode_error=expected one result column\n");
    return;
  }
  struct ArrowSchema *node_schema = schema->children[0];
  struct ArrowArray *node = array->children[0];
  if (node_schema->n_children < 6 || node->n_children < 6) {
    appendf(b, "\ndecode_error=expected node fields _ID,_LABEL,id,name,age,active\n");
    return;
  }

  char label[128];
  char name[128];
  read_utf8(node->children[1], 0, label, sizeof(label));
  int64_t id = read_i64(node->children[2], 0);
  read_utf8(node->children[3], 0, name, sizeof(name));
  int64_t age = read_i64(node->children[4], 0);
  int active = read_bool(node->children[5], 0);

  struct ArrowArray *internal_id = node->children[0];
  int64_t internal_offset = read_i64(internal_id->children[0], 0);
  int64_t internal_table = read_i64(internal_id->children[1], 0);

  appendf(b, "\n-- Decoded NODE from Arrow C-data --\n");
  appendf(b, "decoded.label=%s\n", label);
  appendf(b, "decoded.internal_id.offset=%lld\n", (long long)internal_offset);
  appendf(b, "decoded.internal_id.table=%lld\n", (long long)internal_table);
  appendf(b, "decoded.properties.id=%lld\n", (long long)id);
  appendf(b, "decoded.properties.name=%s\n", name);
  appendf(b, "decoded.properties.age=%lld\n", (long long)age);
  appendf(b, "decoded.properties.active=%s\n", active ? "true" : "false");
  appendf(b, "decoded.assertions=%s\n",
      strcmp(label, "Person") == 0 && id == 7 && strcmp(name, "Ada") == 0 && age == 42 && active
          ? "pass"
          : "fail");
}

static void query(lbug_connection *conn, const char *sql)
{
  lbug_query_result result = {NULL, false};
  check(lbug_connection_query(conn, sql, &result), sql);
  lbug_query_result_destroy(&result);
}

CAMLprim value eta_lbug_p1_decode_node_record(value unit_value)
{
  CAMLparam1(unit_value);
  CAMLlocal1(ret);

  lbug_database db = {NULL};
  lbug_connection conn = {NULL};
  lbug_query_result result = {NULL, false};
  struct ArrowSchema schema = {0};
  struct ArrowArray array = {0};

  check(lbug_database_init(":memory:", lbug_default_system_config(), &db), "database_init");
  check(lbug_connection_init(&db, &conn), "connection_init");
  query(&conn, "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, active BOOL, PRIMARY KEY(id))");
  query(&conn, "CREATE (p:Person {id: 7, name: 'Ada', age: 42, active: true})");
  check(lbug_connection_query(&conn, "MATCH (p:Person {name: 'Ada'}) RETURN p", &result),
      "MATCH RETURN p");
  check(lbug_query_result_get_arrow_schema(&result, &schema), "get_arrow_schema");
  check(lbug_query_result_get_next_arrow_chunk(&result, 16, &array), "get_next_arrow_chunk");

  struct ArrowArray *node = array.children[0];
  char label[128];
  char name[128];
  read_utf8(node->children[1], 0, label, sizeof(label));
  int64_t id = read_i64(node->children[2], 0);
  read_utf8(node->children[3], 0, name, sizeof(name));
  int64_t age = read_i64(node->children[4], 0);
  int active = read_bool(node->children[5], 0);
  struct ArrowArray *internal_id = node->children[0];
  int64_t internal_offset = read_i64(internal_id->children[0], 0);
  int64_t internal_table = read_i64(internal_id->children[1], 0);

  if (array.release) {
    array.release(&array);
  }
  if (schema.release) {
    schema.release(&schema);
  }
  lbug_query_result_destroy(&result);
  lbug_connection_destroy(&conn);
  lbug_database_destroy(&db);

  ret = caml_alloc_tuple(7);
  Store_field(ret, 0, caml_copy_string(label));
  Store_field(ret, 1, caml_copy_int64(internal_offset));
  Store_field(ret, 2, caml_copy_int64(internal_table));
  Store_field(ret, 3, caml_copy_int64(id));
  Store_field(ret, 4, caml_copy_string(name));
  Store_field(ret, 5, caml_copy_int64(age));
  Store_field(ret, 6, Val_bool(active));
  CAMLreturn(ret);
}

CAMLprim value eta_lbug_p1_arrow_node_probe(value unit_value)
{
  CAMLparam1(unit_value);

  struct buf b = {{0}, 0};
  lbug_database db = {NULL};
  lbug_connection conn = {NULL};
  lbug_query_result result = {NULL, false};
  struct ArrowSchema schema = {0};
  struct ArrowArray array = {0};

  check(lbug_database_init(":memory:", lbug_default_system_config(), &db), "database_init");
  check(lbug_connection_init(&db, &conn), "connection_init");

  query(&conn, "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, active BOOL, PRIMARY KEY(id))");
  query(&conn, "CREATE (p:Person {id: 7, name: 'Ada', age: 42, active: true})");
  check(lbug_connection_query(&conn, "MATCH (p:Person {name: 'Ada'}) RETURN p", &result),
      "MATCH RETURN p");

  appendf(&b, "ladybug_version=%s\n", lbug_get_version());
  appendf(&b, "query=MATCH (p:Person {name: 'Ada'}) RETURN p\n");
  check(lbug_query_result_get_arrow_schema(&result, &schema), "get_arrow_schema");
  check(lbug_query_result_get_next_arrow_chunk(&result, 16, &array), "get_next_arrow_chunk");

  appendf(&b, "\n-- ArrowSchema --\n");
  dump_schema(&b, &schema, 0);
  appendf(&b, "\n-- ArrowArray --\n");
  dump_array(&b, &array, 0);
  decode_node(&b, &schema, &array);

  if (array.release) {
    array.release(&array);
  }
  if (schema.release) {
    schema.release(&schema);
  }
  lbug_query_result_destroy(&result);
  lbug_connection_destroy(&conn);
  lbug_database_destroy(&db);

  value ret = caml_copy_string(b.data);
  CAMLreturn(ret);
}
