# eta-http

Clean-room HTTP/1.1 and HTTP/2 client package for Eta.

eta-http v1 provides a production-shape client for Eta applications. The
package owns client lifecycle, typed errors, pooling, streaming request and
response bodies, retries, trailers, and observability. It handles TLS through
the local OpenSSL binding and delegates HTTP/2 frame + HPACK handling to `h2`.

## Status

The implementation lives under `lib/http/`. Current implemented
surface:

- typed error taxonomy, redaction, and JSON-style projection;
- request/response model with streaming byte bodies;
- ADR 0002 TLS 1.2 + ECDHE-AEAD config chokepoint;
- RFC 3986 client-subset URL parser for absolute `http`/`https` URLs;
- DNS, TCP, TLS, ALPN, and protocol dispatch;
- HTTP/1.1 request serialization, response parsing, chunked trailers, gzip, and
  origin-scoped pooling through `Eta.Pool`;
- HTTP/2 ALPN client path through `ocaml-h2`, including an owned reader/writer
  loop, origin-scoped h2 connection reuse, response-body streaming, trailer
  delivery, push disabled by default, and PUSH_PROMISE rejection;
- retry/idempotency policy helpers;
- OpenTelemetry semantic-convention observability helpers;
- negative TLS compile fixtures and live audit catalogs.

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
nix develop -c dune runtest lib/http --force
nix develop -c dune exec scratch/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe
nix develop -c bash scratch/eta_http_research/h_q4a_interop_matrix/scripts/run_matrix.sh
```

## Public API TOC

| Module | Purpose |
| --- | --- |
| `Http.Client` | Top-level client API. |
| `Http.Request` | Request model. |
| `Http.Response` | Response model. |
| `Http.Error` | Typed eta-http failures and projections. |
| `Http.Core` | URL, method, version, header, status, and span helpers. |
| `Http.Body` | Request and response body surfaces. |
| `Http.Tls` | TLS policy chokepoint. |
| `Http.Transport` | DNS, TCP, TLS, ALPN, and protocol dispatch. |
| `Http.H1` | HTTP/1.1 parser, writer, and client loop. |
| `Http.H2` | HTTP/2 connection owner, frame helpers, multiplexer, writer, and admission state. |

## Constraints

- Source is written clean-room against RFCs, Eta primitives, and the v1
  objective. Reference libraries are design input only.
- Dependencies stay inside the allow-list in the objective. Adding another
  dependency is a planner decision.
- Applications own state. eta-http owns effect description, client protocol
  interpretation, and resource lifecycle.
- `cstruct` is a direct dependency because `Eio.Flow.single_read` exposes
  flow reads through `Cstruct.t`; it is already in the Eta dependency closure
  through `eta-stream`/Eio.
- `digestif`, `tls-eio`, `x509`, `ca-certs`, and Mirage Crypto are not
  eta-http dependencies. TLS is owned by the local OpenSSL binding.

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
nix develop -c dune build lib/http
nix develop -c dune runtest lib/http --force
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
- Public h2c prior-knowledge is not exposed; plain HTTP routes to HTTP/1.1.
- TLS certificate revocation checking through OCSP, CRL, or stapling is not
  performed by eta-http v1. Deployments that require revocation enforcement must
  provide it outside eta-http or through a future TLS policy surface.
- HTTP/1.1 skips interim `100 Continue` and returns the final response, but
  upload-drain recovery is not a product guarantee.
- HTTP/2 request I/O is owned by a dedicated reader/writer loop. The client
  filters interim 1xx response HEADERS, except `101 Switching Protocols`,
  before handing bytes to `ocaml-h2`; callers receive the final non-1xx
  response.
- HTTP/2 GOAWAY handling remains conservative drop-and-disconnect. The pinned
  `ocaml-h2` line does not expose received `last_stream_id`, so eta-http does
  not selectively retry streams above the GOAWAY cutoff in v1.
- The real-server interop matrix is broad but not exhaustive; exact h2c support,
  handcrafted TCP RST behavior, and pathological h2 stalled-window behavior
  remain caveats in `h_q4a_interop_matrix/coverage_matrix.md`.
- The pinned `tls.0.17.5` posture has known OSEC advisories documented in
  `h_ops1_dependency_posture/cve_monitoring.md`.
