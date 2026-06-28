# ADR: gRPC-Style Trailers-As-Status Compatibility

Status: Accepted for eta-http v1 forward compatibility.

## Context

gRPC over HTTP/2 reports application success or failure in trailing headers, not
in the HTTP status. A unary response commonly arrives as:

    HEADERS  :status 200, content-type: application/grpc+proto
    DATA     five-byte gRPC message prefix plus message bytes
    HEADERS  END_STREAM, grpc-status, grpc-message

eta-http should not parse protobuf or gRPC frames, but its response API must not
make this pattern impossible for a future gRPC layer.

## Decision

Keep Http.Response.t as status, headers, body, and a deferred trailers
thunk. HTTP/2 trailing headers are delivered through the trailers thunk. Body
bytes remain raw and unbuffered at eta-http's layer.

## Evidence

response_consumer.ml proves that:

- response.trailers () can observe grpc-status: 0;
- response.trailers () can observe grpc-status: 14;
- body bytes are still available as the raw gRPC message envelope;
- trailers can resolve independently of body consumption once the HTTP/2 peer
  has sent END_STREAM trailing headers.

Run:

    nix develop -c dune exec .scratch/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe

## Consequences

- eta-http remains an HTTP client, not a gRPC client.
- A future gRPC package can decode the body stream and interpret trailers
  without requiring an eta-http response API change.
- Applications that ignore trailers still see the HTTP response normally.
