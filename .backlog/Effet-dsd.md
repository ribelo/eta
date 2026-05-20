---
id: Effet-dsd
title: Real OTel-shaped span semantics in effet core
status: closed
priority: 2
issue_type: epic
created_at: 2026-05-19T11:51:12.333Z
created_by: backlog
updated_at: 2026-05-19T12:33:02.001Z
closed_at: 2026-05-19T12:33:02.001Z
close_reason: "Completed Epic A: core tracer abstraction, Effect.fn/here_attr,
  runtime span emission, Eio fiber-local propagation, V-O6 journal decision, and
  observability suite. Verified nix develop -c dune build and runtest --force
  (56 tests)."
dependencies:
  - issue_id: Effet-dsd
    depends_on_id: Effet-ev6
    type: blocks
    created_at: 2026-05-19T11:53:39.363Z
    created_by: backlog
---

# Real OTel-shaped span semantics in effet core

## description

Effect.named and Effect.annotate are AST decorations that the interpreter currently unwraps and discards. Effet should emit real spans during interpretation, with parent/child topology, attributes, and status-from-cause, so users get observability quality comparable to Effect-TS without leaving the core library and without depending on the OpenTelemetry SDK. Research V-O1..V-O5 in journal.md defines the surface and the lab in scratch/observability_research/ proves the approach compiles and runs. This epic delivers the in-core tracer abstraction and the interpreter changes that make spans real.

## design

Keep Named and Annotate as the public AST atoms (V-O1). Add Effect.here_attr and Effect.fn smart constructors over the existing AST (V-O2). Introduce a Tracer module exposing an in-memory tracer (for tests and dump) and a noop tracer (default), plus a Capabilities.tracer class type for the canonical trait. Tracer carries a pending-attrs buffer so pipe-order does not change span semantics. The runtime rewrites Named and Annotate cases to call the tracer; cause-to-status mapping is Ok / Error msg / Cancelled. Cross-fiber span propagation goes through Eio.Fiber.create_key so detach, par, all, and for_each_par children inherit the parent's active span. __FUNCTION__ and __POS__ are documented as the convention for span name and location, no ppx required.nnDESIGN FORK left open for the implementer: V-O3 specifies tracer-via-env-row, which matches the V-R10 R-channel decision. An alternative is tracer-as-runtime-parameter, which keeps every program's env type free of tracer noise at the cost of departing from Effect-TS's R model. Plan as written (env-row); the implementing agent may revisit if env-row produces unacceptable type-signature pollution across the existing test suite. Decision must be recorded in journal.md before A3 lands.

## acceptance criteria

An effect built with Effect.fn __POS__ __FUNCTION__ body produces an in-memory span whose name equals the binding's full module path and whose attributes include the source location. An effect with multiple annotate decorators in any pipe order produces a span carrying all attributes, regardless of whether annotate sits inside or outside named in the AST. An outer named effect that binds inner named effects produces a parent/child span tree where each child's parent_id is the outer span's id. A failing effect produces span status Error with the failure message. A cancelled effect produces status Cancelled. A succeeding effect produces status Ok. Detached fibers and parallel children inherit the active span context from their parent at fork time. The full test suite passes; the new observability tests cover all the cases above. Capabilities.tracer is a documented public class type that effet-otel can implement against.
