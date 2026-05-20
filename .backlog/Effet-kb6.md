---
id: Effet-kb6
title: "B2: OpenTelemetry tracer adapter"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T11:52:27.051Z
created_by: backlog
updated_at: 2026-05-19T13:55:21.294Z
closed_at: 2026-05-19T13:55:21.294Z
close_reason: "Hand-rolled OTLP/JSON exporter: random trace_id/span_id, JSON
  encoder, HTTP/1.1 over Eio TCP, batching daemon. Implements
  Effet.Capabilities.tracer. Verified end-to-end against motel: 3-span trace
  with par children correctly parented, durations, status mapping, resource
  attrs."
dependencies:
  - issue_id: Effet-kb6
    depends_on_id: Effet-9w1
    type: parent-child
    created_at: 2026-05-19T11:53:15.575Z
    created_by: backlog
  - issue_id: Effet-kb6
    depends_on_id: Effet-dsd
    type: blocks
    created_at: 2026-05-19T11:53:39.062Z
    created_by: backlog
  - issue_id: Effet-kb6
    depends_on_id: Effet-7zc
    type: blocks
    created_at: 2026-05-19T11:53:39.162Z
    created_by: backlog
---

# B2: OpenTelemetry tracer adapter

## description

Implement Effet_otel.tracer: a value satisfying Effet.Capabilities.tracer that emits to the OpenTelemetry SDK. This is the core of the package and the only nontrivial code in epic B.

## design

packages/effet-otel/tracer.ml exports Effet_otel.tracer : ?service_name:string -> ?service_version:string -> ?resource_attrs:(string * string) list -> unit -> Effet.Capabilities.tracer. Internally holds an OTel Tracer reference and a per-fiber active-span context (read from the Eio.Fiber.create_key set up in A4). begin_span creates a new OTel span with the current active span as parent, pushes it on the context stack, returns a span_token wrapping the OTel span ref. add_attr looks up the active OTel span from the token and calls Span.set_attribute. end_span maps Effet's status -> OTel StatusCode (Ok | Error msg | Cancelled = Error 'cancelled') and finishes the span. Resource attributes are configured at tracer creation time, not per-span.

## acceptance criteria

Effet_otel.tracer ?service_name:'demo' () constructs and satisfies Effet.Capabilities.tracer. Calling Effect.fn / Effect.named through this tracer with an effet runtime emits real OTel spans observable via an OTel test exporter (in-memory collector or stdout). Span names, attributes, parent IDs, and status codes all round-trip correctly.
