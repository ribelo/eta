---
id: Effet-tzj
title: Backtraces / source locations on Cause.Die
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T18:43:46.379Z
created_by: backlog
updated_at: 2026-05-20T14:18:17.030Z
closed_at: 2026-05-20T14:18:17.030Z
close_reason: "Completed. Cause.Die now carries a diagnostic record with exn,
  optional raw backtrace, active span name, and active annotations. Runtime
  captures diagnostics at thunk/named/annotate/finalizer defect boundaries,
  Runtime.create exposes ?capture_backtrace, Cause.pp renders diagnostics, and
  exception events exported through effet-otel include exception.stacktrace."
dependencies:
  - issue_id: Effet-tzj
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:59.113Z
    created_by: backlog
  - issue_id: Effet-tzj
    depends_on_id: Effet-6s5
    type: blocks
    created_at: 2026-05-19T18:48:04.557Z
    created_by: backlog
---

# Backtraces / source locations on Cause.Die

## description

Review 1 omission #2. Current Cause.t carries Die of exn. When a defect surfaces (uncaught exn in Sync/Async leaf, panic in user callback), the cause has no backtrace, no source location, and no annotation chain. Debugging shipping code becomes painfully hard.

OCaml has Printexc.raw_backtrace; the runtime can capture it at Die time and stash it on the cause. Effect.t already carries Annotate / Named decoration; the runtime can preserve the surrounding span name and AST annotation on the cause when a Die surfaces.

Scope: extend Cause to carry diagnostic context. Coupled with Effet-6s5 (structured Cause algebra) — if that lands, Die's payload extends naturally.

Risk: runtime cost. Capturing backtraces is not free. Consider a runtime flag ?capture_backtrace : bool (default true in dev, configurable in production).

## design

Extend Cause.t:
type 'e Cause.t =
  | Fail of 'e
  | Die of {
      exn : exn;
      backtrace : Printexc.raw_backtrace option;
      span_name : string option;
      annotations : (string * string) list;
    }
  | Interrupt
  | Both of ...

Runtime captures backtrace at the boundary that catches user-raised exn (the Sync/Async interpreter case, plus unprotected user code in acquire_release). Span_name and annotations come from the active span/annotate stack at the time of capture. ?capture_backtrace flag on Runtime.create, default true.

Cause.pp is updated to format the backtrace and annotations. effet-otel maps backtrace to OTLP exception.stacktrace attribute and annotations to span attributes.

## acceptance criteria

Cause.Die carries optional backtrace, span_name, and annotations. Runtime captures these at all defect-raising sites (Sync, Async, acquire/release closures, scoped finalizers). Cause.pp renders them. A test shows that a deliberately-raised exception inside an Effect.named span produces a Die cause carrying that span's name and any annotations. effet-otel exception events include stacktrace when present. Existing tests continue to pass. 2h time budget.
