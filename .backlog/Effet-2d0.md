---
id: Effet-2d0
title: "Research: full OTel context propagation (V-O6/V-O7 reopened —
  extract/inject, baggage, sampling flags, trace-state)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:39:29.431Z
created_by: backlog
updated_at: 2026-05-20T00:55:53.546Z
closed_at: 2026-05-20T00:55:53.546Z
close_reason: "Completed. OTel propagation lab in scratch/otel_propagation/
  tested three candidates (P-A pair-only, P-B full core context, P-C
  exporter-only). Decision diary V-P1–V-P7 recorded in journal.md lines 6224+.
  Implementation shipped: Effet.Trace_context (W3C
  traceparent/tracestate/baggage), Effect.with_context, Effect.current_context,
  parent-based sampling from trace_flags, baggage propagation through
  par/all/daemons, traceState in OTLP export. 83 effet tests + 19 effet-otel
  tests passing."
dependencies:
  - issue_id: Effet-2d0
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:30.928Z
    created_by: backlog
---

# Research: full OTel context propagation (V-O6/V-O7 reopened — extract/inject, baggage, sampling flags, trace-state)

## description

Review 1 finding #10. V-O6 settled tracer-as-runtime-parameter for span emission, but never tested distributed propagation. OpenTelemetry context is not just an active span handle: it's a SpanContext (trace ID, span ID, trace flags, trace state) plus baggage, propagated across services via W3C TraceContext headers. Current Effet has none of:
- traceparent / tracestate header extract / inject
- baggage carriage
- sampling flags propagating with the context
- external parent links (Effet-9w1 closed but the propagation surface is thin)

Without these, Effet traces correlate within a process but break at every service boundary, which defeats most production OTel use cases.

Hypothesis to lab:
type trace_context = {
  trace_id : string;
  span_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}
val current_context : ('env, 'err, trace_context option) Effect.t
val with_context : trace_context -> ('env, 'err, 'a) Effect.t -> ('env, 'err, 'a) Effect.t
val inject : trace_context -> (string * string) list  (* W3C headers *)
val extract : (string * string) list -> trace_context option

## design

scratch/otel_propagation/ with positive + negative fixtures.

Fixtures:
1. Inbound request with traceparent header → extract → child span correlates → log records carry traceId/spanId → outbound HTTP-style header set captures injected context.
2. Sampling decision: parent-based sampler with traceflags=01 propagates to children; traceflags=00 unsamples children.
3. Baggage: set on parent, read on child, carried through par children, injected on outbound.
4. Trace-state mutation: vendor-specific trace_state survives extract → emit → inject round trip.
5. Cross-fiber propagation: par children inherit context; detach children inherit context at fork time.

Negative tests: malformed traceparent rejected; clock-skewed parent does not corrupt child sampling decision.

Compare against ocaml-opentelemetry's existing propagation surface to see whether the existing library can be wrapped or whether Effet/effet-otel needs its own implementation.

## acceptance criteria

scratch/otel_propagation/ runs the five fixtures above with passing positive tests and rejecting negative tests. journal.md gains a V-Pv1..V-PvN decision diary recording: which propagation primitives Effet should expose, where they live (effet core / effet-otel / both), and whether existing ocaml-opentelemetry can substitute. If implementation is recommended, capture as a follow-up backlog epic with the propagation API as first slice. 3h time budget.
