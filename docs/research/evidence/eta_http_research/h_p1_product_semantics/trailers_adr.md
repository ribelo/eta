# ADR: Trailer Semantics

Status: Accepted for eta-http v1.

## Decision

eta-http v1 surfaces response trailers through Response.trailers:

    trailers : unit -> (Header.t, Error.t) Eta.Effect.t

Trailers are not auto-stripped. Callers choose whether to ignore, inspect, or
interpret them.

## Evidence

HTTP/1.1 chunked trailers are decoded by packages/eta-http/body/chunked.ml and
exposed by packages/eta-http/h1/client.ml. HTTP/2 trailing headers are delivered
through the multiplexer trailers_handler and wired into the public response by
packages/eta-http/client/client.ml.

The focused tests include HTTP/1.1 chunked trailer coverage and HTTP/2 response
trailer coverage. H-G1 also proves the gRPC trailers-as-status pattern under
.scratch/eta_http_research/h_g1_grpc_forward_compat.

## Consequences

Protocol layers above HTTP, including gRPC, can observe trailer status without
requiring eta-http to parse those application protocols.
