---
id: Effet-a13
title: "issue.path: distinguish object key from array index"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T21:02:07.323Z
created_by: backlog
updated_at: 2026-05-20T19:21:25.000Z
dependencies:
  - issue_id: Effet-a13
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:11:35.824Z
    created_by: backlog
---

# issue.path: distinguish object key from array index

## description

packages/effet-schema/effet_schema.ml — issue.path is string list. Array decode stringifies indexes:

  loop (index + 1) values
    (List.rev_append (at (string_of_int index) item_issues) issues)

After this, downstream consumers cannot tell whether path = ['users'; '0'; 'name'] was 'users.0.name' (object key '0') or 'users[0].name' (array index 0). Effect-TS's Schema.ParseIssue distinguishes via PropertyKey | number.

Real-world consumers who care:
- API surfaces emitting RFC 6901 JSON Pointer (which has different escape rules for indices)
- JSONPath generation
- OpenAPI error responses
- IDE plugins highlighting the failing JSON location

The collapse to string was inherited from m_a_pure_schema_effect_policy.ml without testing path round-trip through any of these consumers.

## design

Change issue.path from string list to a discriminated list:

  type path_segment = Field of string | Index of int
  type issue = { path : path_segment list; message : string }

Update array decode to use Index index instead of string_of_int index. Update record decode to use Field name. Keep the at helper:

  val at : path_segment -> issue list -> issue list
  val at_field : string -> issue list -> issue list   (* shorthand *)
  val at_index : int -> issue list -> issue list      (* shorthand *)

Update render_issue / render_issues to render Index 0 as '[0]' (JSONPath style) or '0' (dotted) consistently. Default render: 'foo[0].bar'.

Add a helper that converts to JSON Pointer:
  val issue_to_json_pointer : issue -> string

Test: decode a value with a failing array element inside a record; assert path = [Field 'users'; Index 0; Field 'name']; assert json_pointer round-trip.

Migration cost: every test in run.ml that asserts on issue.path needs to update its expected list shape. ~15 sites. The fix is mechanical.

## acceptance criteria

issue.path is path_segment list distinguishing Field and Index. render_issue produces a readable rendering that visibly distinguishes object keys from array indexes. issue_to_json_pointer (or equivalent) is exported. Existing tests are updated to the new shape. nix develop -c dune runtest --force passes.

## resolution

`issue.path` is now `path_segment list` with `Field` and `Index`.
`render_issue` distinguishes `users[0].id` from `users.0.id`, and
`issue_to_json_pointer` is exported. Regression tests cover nested array paths
and numeric object keys.
