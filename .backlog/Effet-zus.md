---
id: Effet-zus
title: Auto-instrumentation of Sync/Async leaves (V-O9)
status: closed
priority: 4
issue_type: task
created_at: 2026-05-19T14:26:14.496Z
created_by: backlog
updated_at: 2026-05-19T15:14:20.035Z
closed_at: 2026-05-19T15:14:20.035Z
close_reason: Added Runtime.create ?auto_instrument default false. When enabled
  Sync/Async leaves are wrapped in spans with parent context, sampler support,
  and Error status on exceptions. Added tests for default off, leaf span
  creation, nesting under named parent, failure status, and nix develop -c dune
  runtest --force passes.
---

# Auto-instrumentation of Sync/Async leaves (V-O9)

## description

Effect.sync and Effect.async leaves carry a string name today (used by collect_names), but the runtime does NOT wrap them in spans. Users who want every leaf instrumented must wrap each leaf in Effect.named manually. V-O9 defers: 'Auto-instrumentation of Sync / Async leaves.' This is a runtime-toggle feature: opt-in for users who want exhaustive traces (debugging, dev) and off by default (production volume).

## design

Runtime.create gains optional ?auto_instrument:bool argument; default false. When true, the interpreter Sync (name, f) and Async (name, f) cases are rewritten to: tracer.begin_span ~name; let v = f env in tracer.end_span ~status:Ok; v. On exception: tracer.end_span ~status:(Error msg); reraise. Pairs naturally with Effet-rv9 (sampling) — auto-instrument with sampler.ratio 0.01 captures 1% of leaf execution for production diagnostics. Active-span context propagation handled by the existing fiber-local key, so auto-instrumented leaves nest correctly inside named parents.

## acceptance criteria

Runtime.create accepts ?auto_instrument:bool (default false). A test with auto_instrument:true and a 3-leaf effect (sync 'a' f1; sync 'b' f2; sync 'c' f3) produces 3 spans named 'a','b','c' in the in-memory tracer dump. A test with auto_instrument:false (the default) produces 0 spans for the same effect (current behavior preserved). A test verifies auto-instrumented leaves nest under an outer Effect.named: parent 'outer' has 3 children 'a','b','c'. Failure status: a leaf raising an exn produces a span with status Error. Existing 56+ tests continue to pass with default off.
