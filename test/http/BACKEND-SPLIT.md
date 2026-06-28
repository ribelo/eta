# HTTP Test Backend Split

`test/http_common` owns HTTP behavior that is independent of the concrete
runtime backend and is instantiated by `test/http_eio`.

Current shared coverage:

- Core smoke, header/method/error/trace-context helpers.
- URL parser client-subset and unsupported-form checks.
- Retry idempotency, retry classification, and retry execution through Eta.
- Body stream ownership/release, concurrent-use rejection, chunked codec, and
  gzip transducers.
- HTTP/1 response parser.
- HTTP/1 request writer string/byte-buffer serialization and validation.
- WebSocket frame codec and source-level security invariants.
- HTTP/2 admission/stream-state logic, frame helpers, writer iovec slicing,
  and security observer/header-validation invariants including SETTINGS churn.
- ALPN state/dispatch decisions and TLS configuration policy.
- HTTP observability tracer, semantic convention, retry-span, recursion, and
  meter behavior over custom Eta clients.
- HTTP/2 multiplexer body-stream/lifecycle behavior that uses Eta effects and
  in-memory H2 state-machine pumping, without raw Eio flows.

`test/http` remains the Eio-specific HTTP suite. Its remaining tests depend on
one or more of:

- Raw `Eio.Flow`, `Eio.Promise`, `Eio.Stream`, `Eio.Switch`, or
  `Eio_mock.Flow`.
- HTTP/1 writer behavior tied to raw Eio flow writes, flow write failures,
  cancellation propagation, and no-output guarantees on flow validation errors.
- WebSocket client behavior tied to `connect_on_flow`, scripted Eio flows,
  Eta streams fed by the Eio-backed client, or real TCP sockets.
- HTTP/2 reader/writer, connection, and multiplexer scenarios tied to raw
  Eio flows, blocked writes, cancellation, or live client/server transport
  ownership.
- HTTP/2 multiplexer reader cases using `Eio.Flow`, `Eio_mock.Flow`, or an
  Eio fiber to pump the async body-stream recursion fixture.
- TLS/OpenSSL ownership and source-invariant checks tied to `tls_eio.ml` or
  C stubs.
- TCP, DNS, TLS, ALPN, OpenSSL, or real socket behavior.
- HTTP/1 and HTTP/2 connection pools and multiplexers whose implementation
  currently owns Eio flows or Eio cancellation behavior.
- Observability scenarios tied to the Eio-backed HTTP client and transport.

Do not move or delete these Eio-specific tests unless Eta grows a
backend-neutral transport API that gives the same ownership, cancellation,
socket, TLS, and flow-failure contracts.
