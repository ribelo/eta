---
id: Effet-6mx
title: "A2: Effect.fn and Effect.here_attr smart constructors"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T11:51:53.305Z
created_by: backlog
updated_at: 2026-05-19T12:32:46.221Z
closed_at: 2026-05-19T12:32:46.221Z
close_reason: Added Effect.here_attr and Effect.fn with mli docs, location
  attribute coverage, and verified full suite (56 tests).
dependencies:
  - issue_id: Effet-6mx
    depends_on_id: Effet-dsd
    type: parent-child
    created_at: 2026-05-19T11:53:15.173Z
    created_by: backlog
  - issue_id: Effet-6mx
    depends_on_id: Effet-2ft
    type: blocks
    created_at: 2026-05-19T11:53:38.660Z
    created_by: backlog
---

# A2: Effect.fn and Effect.here_attr smart constructors

## description

Add the user-facing convenience constructors that combine name + location decoration in one pipe-friendly call. These are pure sugar over the existing Named and Annotate AST nodes; no new GADT cases.

## design

Effect.here_attr : (string * int * int * int) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t attaches a 'loc' attribute via existing Annotate. Effect.fn : (string * int * int * int) -> string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t is here_attr followed by named. Public mli entries include doc comments showing the idiom: Effect.fn __POS__ __FUNCTION__ body. The position quadruple matches __POS__'s native shape (string * int * int * int).

## acceptance criteria

Effect.here_attr and Effect.fn are exported from packages/effet/effect.mli with documentation comments. Effect.fn pos name body is observably equivalent to body |> Effect.here_attr pos |> Effect.named name. A test builds an effect with Effect.fn __POS__ __FUNCTION__ body, runs it through an in-memory tracer, and asserts the resulting span has the expected fully-qualified name and a 'loc' attribute pointing at this test file. Full test suite passes.
