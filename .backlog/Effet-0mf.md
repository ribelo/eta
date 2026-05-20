---
id: Effet-0mf
title: "A3: Interpreter span emission"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T11:51:53.205Z
created_by: backlog
updated_at: 2026-05-19T12:32:46.221Z
closed_at: 2026-05-19T12:32:46.221Z
close_reason: Runtime now emits spans for Named/Annotate using a runtime tracer
  parameter, maps success/fail/die/interrupt/both statuses, records V-O6 in
  journal.md, and passes 56 tests.
dependencies:
  - issue_id: Effet-0mf
    depends_on_id: Effet-dsd
    type: parent-child
    created_at: 2026-05-19T11:53:15.274Z
    created_by: backlog
  - issue_id: Effet-0mf
    depends_on_id: Effet-2ft
    type: blocks
    created_at: 2026-05-19T11:53:39.866Z
    created_by: backlog
---

# A3: Interpreter span emission

## description

Rewrite the Named and Annotate interpreter cases to call the tracer in env, opening and closing real spans around bodies. This is where AST decorations become observable. Status maps from Cause: Pure success -> Ok, typed Fail -> Error msg, Die exn -> Error msg, Interrupt -> Cancelled, Both _ -> Error 'multiple'.

## design

In packages/effet/runtime.ml, the Named (name, body) case obtains a tracer from env, calls begin_span, runs body, derives status from the returned result or the propagated cause, calls end_span with that status, and propagates the body's outcome. Annotate (key, value, body) calls add_attr on the tracer (which buffers if no span is active, see A1's pending-attrs) then runs body unchanged.nnThis task settles the design fork in epic A: env-row tracer (V-O3 as written) vs runtime-parameter tracer. Investigate which causes less type-signature pollution across the existing test suite. Implement the chosen option and document the decision in journal.md as V-O6 with the rationale.

## acceptance criteria

An effect Effect.named 'foo' (Effect.pure 1) run with an env carrying an in-memory tracer produces a span named 'foo' with status Ok. An effect Effect.named 'fails' (Effect.fail `Boom) produces a span named 'fails' with status Error. An effect inside Effect.uninterruptible cancelled by an outer race produces a span with status Cancelled. Annotate placed inside Named attaches its key/value to that span. Annotate placed outside Named (in pipe order, before Named in the AST) buffers and attaches to the next opened span. Status mapping for all Cause variants is exercised by tests. Journal.md gains a V-O6 entry recording the env-row vs runtime-param decision.
