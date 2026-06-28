# eta_http

Backend-neutral HTTP protocol and client contract for Eta.

eta_http owns the request/response model, typed errors, body streams, retry
policy handling, trace-context propagation, TLS policy data, and pure protocol
helpers. Backend-specific I/O lives in adapter packages such as
`eta_http_eio`.

## Package boundary

- `eta_http` is backend-neutral: request/response model, typed errors, body
  streams, retry policy, TLS policy data, and protocol helpers.
- Protocol helpers live in sibling packages: `eta_http_h1`, `eta_http_h2`,
  `eta_http_ws`, and `eta_http_tls_openssl`.
- Backend-specific I/O lives in adapter packages such as `eta_http_eio`
  (native Eio) and `eta_http_js` (js_of_ocaml Fetch).
- `eta_http` does not depend on `eio`, `eta_eio`, `eta_blocking`,
  `eta_http_eio`, `eta_http_js`, OpenSSL stubs, WebSocket host randomness, or
  concrete HTTP/1/HTTP/2 helper packages.

## Status

The shared implementation lives under `lib/http/`. Current implemented
surface:

- typed error taxonomy, redaction, and JSON-style projection;
- request/response model with streaming byte bodies;
- backend-neutral TLS policy/config data;
- RFC 3986 client-subset URL parser for absolute `http`/`https` URLs;
- backend-neutral client service contract for runtime-provided HTTP clients;
- gzip body transducers and core header/method/status/version helpers;
- retry/idempotency policy helpers;
- OpenTelemetry semantic-convention observability helpers.

HTTP/1 helpers live under `lib/http/h1/` as `eta_http_h1`; HTTP/2 helpers live
under `lib/http/h2/` as `eta_http_h2`; WebSocket codec helpers live under
`lib/http/ws/` as `eta_http_ws`; native OpenSSL state-machine bindings live
under `lib/http_tls_openssl/` as `eta_http_tls_openssl`.

The Eio transport adapter lives under `lib/http_eio/` and owns DNS, TCP, TLS,
ALPN dispatch, HTTP/1.1 client pooling, HTTP/1.1/h2c/HTTPS server loops,
HTTP/2 connection ownership, and WebSocket client I/O. The JavaScript Fetch
adapter lives under `lib/http_js/` and is client-only.

## Edge Server Readiness

`eta_http_eio.Server` is intended for edge service. The evidence below shows
which gates currently pass, but Eta is still pre-1.0 and not universally
production-ready. See `docs/http-server-production-readiness-audit.md` for the
current readiness caveats (server WebSocket upgrade support, operational
recipes, advanced TLS/deployment features, and broader adversarial/soak
coverage) before exposing a server directly on the public Internet.

Default HTTP limits are deliberately bounded:

| Setting | Default |
| --- | --- |
| Request line | 8 KiB |
| Request headers | 32 KiB / 256 headers |
| Request body | 1 MiB |
| Response headers | 32 KiB / 256 headers |
| Trailers | 8 KiB / 64 trailers |
| Unread request body policy | `Reset` |

Default HTTP timeouts:

| Timeout | Default |
| --- | --- |
| Request headers | 30 s |
| Request body | 30 s |
| Response socket/write progress | 30 s |
| Response body producer | 30 s |
| Idle keep-alive | 60 s |
| Handler runtime | 30 s |

Default Eio transport limits:

| Setting | Default |
| --- | --- |
| Listener backlog | 128 |
| Max accepted connections | 1024 |
| Read buffer | 64 KiB |
| Command queue capacity | 1024 |
| TLS handshake timeout | 10 s |
| HTTP/2 max concurrent streams | 128 |

The server rejects malformed H1 framing and smuggling vectors, enforces H2
connection-specific header rules and content lengths, owns H2 response framing,
resets flow-control-stalled H2 response streams, bounds pending TLS handshakes,
and applies `TCP_NODELAY` to accepted TCP flows before handing them to H1, h2c,
or HTTPS handlers.

## Evidence

Current green gates:

```sh
nix develop -c dune runtest test/http --force
nix develop -c dune runtest test/http_eio --force
timeout 600s nix develop -c dune exec http-testsuite/test/interop/run.exe
timeout 180s nix develop -c dune exec http-testsuite/test/cve_regress/run.exe
timeout 300s nix develop -c dune exec http-testsuite/test/bench/run.exe
nix develop -c dune build @http-bench --force
nix develop -c dune build eta_http.install eta_http_eio.install
nix develop -c bash bench/run.sh --quick
```

`test/http` is the low-level protocol gate. Its TLS negative-compile fixtures
are expected to print `PASS expected compile failure`.

Current counts from the latest edge-readiness pass:

| Gate | Result |
| --- | --- |
| `test/http` | 340 tests passing |
| `test/http_eio` | 145 tests passing |
| `http-testsuite` interop | PASS 314, DIVERGENT 0, FAIL 0, SKIP 176 |
| `http-testsuite` CVE/adversarial | PASS 27, FAIL 0, SKIP 0 |
| `http-testsuite` HTTP bench | 30 iterations across 6 scenario/client groups |

Durable HTTP research evidence lives under `.scratch/research/evidence/eta_http_research/`:

- `h_q4a_interop_matrix/`: scripted curl/nghttp2/nghttpd/nginx/Caddy interop
  matrix.
- `h_g1_grpc_forward_compat/`: gRPC-style HTTP/2 trailers-as-status fixture.
- `h_p1_product_semantics/`: product semantics ADR set.
- `h_ops1_dependency_posture/`: dependency closure, build timing, CVE process,
  version pin policy, and LTS risk register.

## Public API TOC

| Module | Purpose |
| --- | --- |
| `Eta_http.Client` | Backend-neutral client API and runtime-service contract. |
| `Eta_http.Request` | Request model. |
| `Eta_http.Response` | Response model. |
| `Eta_http.Error` | Typed eta_http failures and projections. |
| `Eta_http.Core` | URL, method, version, header, status, and span helpers. |
| `Eta_http.Body` | Request and response body surfaces. |
| `Eta_http.Tls` | TLS policy chokepoint. |
| `Eta_http_h1` | HTTP/1.1 parser and serializer modules. |
| `Eta_http_h2` | HTTP/2 frame, HPACK, admission, security, scheduler, stream, and connection helpers. |
| `Eta_http_ws` | RFC 6455 codec. |
| `Eta_http_eio` | Eio-backed HTTP/1.1, HTTP/2, TLS, and WebSocket transport adapter. |
| `Eta_http_js` | js_of_ocaml Fetch client adapter. |

## Constraints

- Source is written clean-room against RFCs, Eta primitives, and the v1
  objective. Reference libraries are design input only.
- The shared package must not depend on `eta_eio`, `eio`, `eio.unix`,
  `js_of_ocaml`, OpenSSL stubs, concrete protocol helper packages, or backend
  adapter libraries.
- Applications own state. eta_http owns effect description, client protocol
  interpretation, and resource lifecycle.
- `digestif`, `tls-eio`, `x509`, `ca-certs`, Mirage Crypto, OpenSSL stubs,
  `cstruct`, `faraday`, `angstrom`, and `base64` are not `eta_http`
  dependencies. Concrete protocol, TLS, and WebSocket substrate belongs in the
  sibling packages that use it.

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

Focused eta_http checks:

```sh
nix develop -c dune build eta_http.install eta_http_eio.install
nix develop .#mainline -c dune runtest test/http_js --force
nix develop -c dune runtest test/http_eio --force
nix develop -c bash lib/http/audit/run.sh
```

`test/http` is currently not part of the green gate (see Evidence above).

Edge-readiness checks:

```sh
timeout 600s nix develop -c dune exec http-testsuite/test/interop/run.exe
timeout 180s nix develop -c dune exec http-testsuite/test/cve_regress/run.exe
timeout 300s nix develop -c dune exec http-testsuite/test/bench/run.exe
nix develop -c dune build @http-bench --force
nix develop -c bash bench/run.sh --quick
```

Full shipped Eta gate:

```sh
nix develop -c eta-oxcaml-test-shipped
```

This helper builds and tests the shipped subset defined in `flake.nix`; keep
its package list in sync with real directory names or it will fail.

## Limits

- Redirects are returned to callers; eta_http does not auto-follow or rewrite
  methods.
- Cookies are header-explicit; eta_http has no cookie jar.
- HTTP/1.1 server keep-alive and already-buffered pipelined request bytes are
  covered. General client-side pipelining is outside the public client API.
- Public client h2c prior-knowledge is not exposed by the Eio adapter; plain
  client HTTP routes to HTTP/1.1. Server-side h2c is available through
  `Eta_http_eio.Server.start_h2c` / `run_h2c`.
- TLS certificate revocation checking through OCSP, CRL, or stapling is not
  performed by eta_http v1. Deployments that require revocation enforcement must
  provide it outside eta_http or through a future TLS policy surface.
- HTTP/1.1 clients skip interim `100 Continue` and return the final response.
- HTTP/2 request I/O in `eta_http_eio` is owned by a dedicated reader/writer
  loop over the in-house state machine. Interim 1xx response HEADERS, except
  `101 Switching Protocols`, are handled before callers receive the final
  non-1xx response.
- HTTP/2 GOAWAY handling in `eta_http_eio` remains conservative
  drop-and-disconnect. Selective retry above a received `last_stream_id` is not
  exposed in v1.
- The interop matrix is broad but not exhaustive. Explicit v1 skips are recorded
  in `http-testsuite/lib/interop.ml`; field-level response subtractions are in
  `http-testsuite/expected_divergences.md`.
