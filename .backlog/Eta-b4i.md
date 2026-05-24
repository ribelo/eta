---
id: Eta-b4i
title: "P1: add_attr/add_link use global latest-open span, corrupting concurrent
  trace attributes"
status: closed
priority: 1
issue_type: bug
created_at: 2026-05-24T12:53:30.085Z
created_by: backlog
updated_at: 2026-05-24T15:19:28Z
closed_at: 2026-05-24T15:19:28Z
close_reason: Fixed — runtime passes the active span id to explicit
  add_attr_to/add_link_to tracer methods; eta-otel concurrency regression added.
dependencies:
  - issue_id: Eta-b4i
    depends_on_id: Eta-cjz
    type: parent-child
    created_at: 2026-05-24T12:53:35.827Z
    created_by: backlog
---

# P1: add_attr/add_link use global latest-open span, corrupting concurrent trace attributes

## description

Bug: eta-otel's add_attr (eta_otel.ml:450-455) and add_link (eta_otel.ml:464) call pick_latest_open, which iterates a global Hashtbl of all active spans and selects the one with the highest numeric handle. In a concurrent application, if Fiber A opens span (handle=1), then Fiber B opens span (handle=2), Fiber A calling add_attr attaches its attributes to Fiber B's span. Traces corrupted.

The tracer capability's add_event correctly takes an explicit span_id (eta_otel.ml:457-462); add_attr and add_link do not.

Location: packages/eta-otel/eta_otel.ml:377-386, 390-464

## design

Update Capabilities.tracer so add_attr and add_link take span_id:int explicitly, matching add_event. Update Runtime to pass Eio.Fiber.get RObs.active_span_key into these methods. If capability API must remain source-compatible, eta-otel should maintain fiber-local active-span stack and update it in begin_span/end_span wrappers.

RED test: two concurrent spans in separate fibers; Fiber A adds attribute, Fiber B adds different attribute; assert each attribute lands on the correct span.

## acceptance criteria

add_attr/add_link take explicit span_id. Concurrent spans do not corrupt each other's attributes. Existing eta-otel tests pass.
