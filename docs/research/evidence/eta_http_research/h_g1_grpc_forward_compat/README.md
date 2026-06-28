# H-G1 gRPC Forward Compatibility

Status: Closed by fixture evidence.

Question: can eta-http's HTTP/2 response shape represent gRPC-style
trailers-as-status without buffering the response body?

Proof obligations:

- Initial HTTP/2 response headers expose HTTP status and content-type.
- The response body stream exposes raw gRPC message bytes, including the
  five-byte gRPC message prefix.
- Trailers expose grpc-status and grpc-message.
- Reading trailers before consuming the body does not block once the h2 peer has
  sent trailing headers.
- A non-OK gRPC status such as 14 remains observable in trailers while the raw
  body bytes stay unchanged.

Fixture:

- fixture_grpc_server.ml builds an in-process ocaml-h2 server that replies:
  HEADERS (:status 200, content-type: application/grpc+proto) -> DATA ->
  HEADERS (END_STREAM, grpc-status, grpc-message).
- response_consumer.ml opens the response through eta-http's h2 multiplexer,
  builds an Http.Response.t, reads response.trailers () before body
  consumption, then drains response.body.

Run:

    nix develop -c dune exec .scratch/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe

Verdict: PASS.

The eta-http response model can represent gRPC unary responses without buffering
the body. Trailers resolve through the existing unit -> Header.t Effect.t field,
and the body stream preserves raw bytes for the application-level gRPC decoder.
