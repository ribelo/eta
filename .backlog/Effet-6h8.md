---
id: Effet-6h8
title: issue carries no schema identity / source discriminator
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T21:08:32.532Z
created_by: backlog
updated_at: 2026-05-20T19:32:00.501Z
closed_at: 2026-05-20T19:32:00.501Z
close_reason: Fixed. issue extended with structured kind
  (Type_mismatch/Missing_field/Custom/Refinement_failed) and optional
  schema_name. render_issue includes schema name when present. Programmatic
  dispatch on kind without string parsing.
dependencies:
  - issue_id: Effet-6h8
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:12:23.668Z
    created_by: backlog
  - issue_id: Effet-6h8
    depends_on_id: Effet-a13
    type: blocks
    created_at: 2026-05-19T21:12:42.952Z
    created_by: backlog
---

# issue carries no schema identity / source discriminator

## description

packages/effet-schema/effet_schema.ml — type issue = { path : string list; message : string }. When errors are aggregated from multiple schemas, the user sees:

  Expected string, got 42 at users.0.email

But not which schema demanded a string at users.0.email. If the same JSON shape is decoded by both Schema.user and Schema.admin (e.g. trying both as a parse strategy), the issue text doesn't say which one rejected.

Effect-TS's Schema.ParseIssue carries an AST node reference / 'ast' property that lets consumers programmatically dispatch on issue source.

Effet's flat string message means:
- error categorisation is regex-on-message
- multilingual error rendering is impossible — message is a plain English string baked at decode time
- structured logging with schema-name fields requires parsing message back out

The fixture tests display strings; no fixture asserts that an issue can be classified by which schema produced it. This was assumed away.

## design

Extend issue with a discriminated source:

  type issue_kind =
    | Type_mismatch of { expected : string; got : string }
    | Missing_field of string
    | Custom of string                 (* user predicates from refine *)
    | Refinement_failed of { name : string; reason : string }

  type issue = {
    path : path_segment list;
    schema_name : string option;       (* from named record / brand / refine *)
    kind : issue_kind;
  }

The kind field is the structured replacement for message. render_issue still produces a human-readable string; programmatic consumers can pattern-match on kind for dispatch.

schema_name is populated from record1..6's name parameter, brand's name, refine's name, transform's name. nameless builtins (string, int, bool, float) leave it None.

Migration cost: tests asserting on issue.message change to assert on kind shape. Render functions stay as the human-readable path.

Coupled with Effet-a13 (path_segment) — they touch the same record. Either land them together or merge into one task.

## acceptance criteria

issue carries a structured kind field plus optional schema_name. render_issue produces a human-readable message that includes the schema name when present. A test verifies that decoding through Schema.user vs Schema.admin produces issues distinguishable by schema_name. Programmatic code can pattern-match on kind without parsing strings. Existing tests are updated. nix develop -c dune runtest --force passes.

## resolution

issue now carries schema_name : string option and structured issue_kind instead
of a flat message. Built-in mismatches and missing fields use structured kinds,
while issue text remains the custom issue helper. Named schemas stamp issues
when no more specific source exists. Tests verify that the same JSON decoded
through user and admin schemas produces distinguishable schema_name values and
pattern-matchable Type_mismatch data.
