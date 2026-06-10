# eta-http

Backend-neutral HTTP protocol and client contract for Eta.

eta-http owns the request/response model, typed errors, body streams, retry
policy handling, trace-context propagation, TLS policy data, and pure protocol
helpers. Backend-specific I/O lives in adapter packages such as
`eta_http_eio`.

## Status

The shared implementation lives under `lib/http/`. Current implemented
surface:

- typed error taxonomy, redaction, and JSON-style projection;
- request/response model with streaming byte bodies;
- ADR 0002 TLS 1.2 + ECDHE-AEAD config chokepoint;
- RFC 3986 client-subset URL parser for absolute `http`/`https` URLs;
- backend-neutral client service contract for runtime-provided HTTP clients;
- HTTP/1.1 request serialization, response parsing, chunked trailers, and gzip;
- HTTP/2 frame, admission, security, informational-response, and stream-state
  helpers that do not own sockets or scheduler state;
- retry/idempotency policy helpers;
- OpenTelemetry semantic-convention observability helpers.

The Eio transport adapter lives under `lib/http_eio/` and owns DNS, TCP, TLS,
ALPN dispatch, HTTP/1.1 pooling, HTTP/2 connection ownership, and WebSocket
client I/O.

## Evidence

Rerunnable research evidence lives under `scratch/eta_http_research/`:

- `h_q4a_interop_matrix/`: scripted curl/nghttp2/nghttpd/nginx/Caddy interop
  matrix.
- `h_g1_grpc_forward_compat/`: gRPC-style HTTP/2 trailers-as-status fixture.
- `h_p1_product_semantics/`: product semantics ADR set.
- `h_ops1_dependency_posture/`: dependency closure, build timing, CVE process,
  version pin policy, and LTS risk register.

Current local checks:

```sh
nix develop .#mainline -c dune runtest test/http test/http_eio --force
nix develop -c dune exec scratch/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe
nix develop -c bash scratch/eta_http_research/h_q4a_interop_matrix/scripts/run_matrix.sh
```

## Public API TOC

| Module | Purpose |
| --- | --- |
| `Eta_http.Client` | Backend-neutral client API and runtime-service contract. |
| `Eta_http.Request` | Request model. |
| `Eta_http.Response` | Response model. |
| `Eta_http.Error` | Typed eta-http failures and projections. |
| `Eta_http.Core` | URL, method, version, header, status, and span helpers. |
| `Eta_http.Body` | Request and response body surfaces. |
| `Eta_http.Tls` | TLS policy chokepoint. |
| `Eta_http.Transport` | Backend-neutral ALPN and protocol dispatch helpers. |
| `Eta_http.H1` | HTTP/1.1 parser and serializer modules. |
| `Eta_http.H2` | HTTP/2 frame, admission, security, informational-response, and stream-state helpers. |
| `Eta_http.Ws` | RFC 6455 codec. |
| `Eta_http_eio` | Eio-backed HTTP/1.1, HTTP/2, TLS, and WebSocket transport adapter. |

## Constraints

- Source is written clean-room against RFCs, Eta primitives, and the v1
  objective. Reference libraries are design input only.
- The shared package must not depend on `eta_eio`, `eio`, `eio.unix`, or
  backend adapter libraries.
- Applications own state. eta-http owns effect description, client protocol
  interpretation, and resource lifecycle.
- `cstruct`, `h2`, `hpack`, `faraday`, and `bigstringaf` remain shared
  protocol dependencies where the shared HTTP/2 helpers expose those substrate
  shapes.
- `digestif`, `tls-eio`, `x509`, `ca-certs`, and Mirage Crypto are not
  eta-http dependencies. TLS policy data and the protocol-required WebSocket
  SHA-1 digest are owned by the local OpenSSL binding; backend TLS I/O belongs
  in adapter packages.

## Audit Catalogs

Run:

```sh
nix develop -c bash lib/http/audit/run.sh
```

Catalogs:

- [`audit/dep_usage.md`](audit/dep_usage.md)
- [`audit/eta_escapes.md`](audit/eta_escapes.md)

The audit script owns the current raw match counts in each header. The tables
are curated classification ledgers; reconcile them when the raw counts change
before making call-site-specific claims.

## Development

Focused eta-http checks:

```sh
nix develop .#mainline -c dune build @install
nix develop .#mainline -c dune runtest test/http test/http_eio --force
nix develop -c bash lib/http/audit/run.sh
```

Research evidence checks:

```sh
nix develop -c dune exec scratch/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe
nix develop -c bash scratch/eta_http_research/h_q4a_interop_matrix/scripts/run_matrix.sh
```

Full shipped Eta gate:

```sh
nix develop -c eta-oxcaml-test-shipped
```

## Limits

- Redirects are returned to callers; eta-http does not auto-follow or rewrite
  methods.
- Cookies are header-explicit; eta-http has no cookie jar.
- HTTP/1.1 pipelining is out of scope.
- Public h2c prior-knowledge is not exposed by the Eio adapter; plain HTTP
  routes to HTTP/1.1.
- TLS certificate revocation checking through OCSP, CRL, or stapling is not
  performed by eta-http v1. Deployments that require revocation enforcement must
  provide it outside eta-http or through a future TLS policy surface.
- HTTP/1.1 skips interim `100 Continue` and returns the final response, but
  upload-drain recovery is not a product guarantee.
- HTTP/2 request I/O in `eta_http_eio` is owned by a dedicated reader/writer
  loop. The adapter filters interim 1xx response HEADERS, except
  `101 Switching Protocols`, before handing bytes to `ocaml-h2`; callers
  receive the final non-1xx response.
- HTTP/2 GOAWAY handling in `eta_http_eio` remains conservative
  drop-and-disconnect. The pinned `ocaml-h2` line does not expose received
  `last_stream_id`, so the adapter does not selectively retry streams above
  the GOAWAY cutoff in v1.
- The real-server interop matrix is broad but not exhaustive; exact h2c support,
  handcrafted TCP RST behavior, and pathological h2 stalled-window behavior
  remain caveats in `h_q4a_interop_matrix/coverage_matrix.md`.
- The pinned `tls.0.17.5` posture has known OSEC advisories documented in
  `h_ops1_dependency_posture/cve_monitoring.md`.
