---
id: Eta-m8h
title: "H-G1: eta-http h2 response/trailer model is forward-compatible with gRPC"
status: open
priority: 2
issue_type: task
created_at: 2026-05-22T15:25:54.422Z
created_by: backlog
updated_at: 2026-05-22T19:03:57.674Z
dependencies:
  - issue_id: Eta-m8h
    depends_on_id: Eta-adr
    type: parent-child
    created_at: 2026-05-22T19:03:57.674Z
    created_by: backlog
---

# H-G1: eta-http h2 response/trailer model is forward-compatible with gRPC

## description

HYPOTHESIS (per Review #2). eta-http's h2 response API can represent a response whose meaningful status arrives in trailers AFTER a streamed body (the gRPC unary and server-streaming model: body chunks contain length-prefixed messages, then a final HEADERS frame with grpc-status and grpc-message arrives as trailers). The body Stream.t is exposed without buffering the whole response; trailers are exposed via a Future-shaped value resolved after body END_STREAM. WHY IT MATTERS (per Review #2). If future eta-grpc is the strategic reason for HTTP/2, the h2 response model must support trailers-as-status. Adding this later is painful because every consumer expects status from initial HEADERS. We are not building gRPC here — we are testing that the response API does not foreclose it. BLAST RADIUS. Medium. Failure means eta-grpc cannot be built on eta-http v1 without API changes. FAST FALSIFIER. scratch/eta_http_research/h_g1_grpc_forward_compat/. Build a local h2 fixture that responds with: (a) HEADERS with :status 200, content-type application/grpc+proto, (b) DATA frames containing length-prefixed message bytes, (c) HEADERS with END_STREAM containing grpc-status: 0 and grpc-message: ''. eta-http stub consumes this through the response API; verify body Stream.t exposes the message bytes (without parsing them — that's eta-grpc's job), trailers Future resolves to a grpc-status/grpc-message map. Then variant (d): server returns body but final trailers contain grpc-status: 14 (UNAVAILABLE) — verify trailers Future resolves to error status without breaking the body Stream.t consumption.

## design

DISPROOF SIGNATURES. The response API forces status into the initial HEADERS only — trailers are not first-class. Or the body Stream.t cannot be consumed in parallel with awaiting trailers (the trailers Future blocks body reading or vice versa). Or trailers arrive but are not exposed in the response type (we'd have to add fields later). Or buffering whole response is the only way to expose trailers. POSITIVE EVIDENCE NEEDED. Both fixtures produce expected behavior. Body Stream.t exposes raw bytes; trailers Future resolves independently. The response API design supports gRPC without modification. ARTIFACTS. scratch/eta_http_research/h_g1_grpc_forward_compat/{fixture_grpc_server.ml, response_consumer.ml, trailers_future.ml, dune, README.md, results.md, grpc_compat_adr.md}. Journal entry V-Http-G1.

## acceptance criteria

scratch/eta_http_research/h_g1_grpc_forward_compat/ exists with both fixtures. results.md confirms trailers-as-status works without buffering. grpc_compat_adr.md documents the response API shape that supports gRPC. Verdict explicit. Journal entry V-Http-G1 added.
