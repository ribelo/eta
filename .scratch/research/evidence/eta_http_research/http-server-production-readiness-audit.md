# HTTP Server Production Readiness Audit

Original date: 2026-06-11

Original audited commit: `7367a63a2`

Current-state update: 2026-06-16, checked against `master` at `1214cb407`.
The original audit is historical. H1, h2c, server-side TLS, HTTPS ALPN
dispatch, and H2 GOAWAY-driven graceful shutdown have since landed. The
remaining production-readiness work is narrower: server-side WebSocket upgrade
support, broader adversarial/soak coverage, operator-facing examples, and
advanced TLS/deployment features such as mTLS, certificate reload, and proxy
header policy.

Scope: Eta's HTTP server substrate in `lib/http/` and `lib/http_eio/`. Client
features are mentioned only when they expose server asymmetry. This audit treats
"production-ready" as suitable for an internet-facing origin server or a
reverse-proxy upstream that accepts ordinary HTTP clients, bounds resources,
survives malformed traffic, shuts down safely, and exposes enough operational
signals to run under load.

Eta's HTTP server is pre-1.0. It now has production-relevant protocol coverage,
but the project should still avoid a blanket "production-ready" claim until the
remaining gates in this document are refreshed and rerun.

The current server surface includes explicit H1, h2c, and HTTPS Eio adapters.
The shared `Eta_http.Server` handler/request/response model exists, and the
server paths have lifecycle, body, streaming-response, trailer, shutdown, TLS,
ALPN, and stats coverage. Server-side adversarial and long-run operational
coverage is still incomplete.

A reverse proxy remains a useful deployment option, but it is no longer required
just to provide HTTP/1.1 or TLS termination. Eta now exposes H1 and HTTPS entry
points directly; proxy policy, trusted forwarded headers, and operational
hardening still belong in application/deployment documentation.

## References

- RFC 9110, HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110
- RFC 9112, HTTP/1.1: https://www.rfc-editor.org/rfc/rfc9112
- RFC 9113, HTTP/2: https://www.rfc-editor.org/rfc/rfc9113
- RFC 7301, TLS Application-Layer Protocol Negotiation: https://www.rfc-editor.org/rfc/rfc7301
- RFC 8446, TLS 1.3: https://www.rfc-editor.org/rfc/rfc8446
- RFC 6455, WebSocket: https://www.rfc-editor.org/rfc/rfc6455

## Current Server Inventory

| Area | Current state | Evidence |
| --- | --- | --- |
| Shared server API | Present. `Eta_http.Server` defines backend-neutral request, response, body, handler, error, tracing, and semantic-convention helpers. | `lib/http/server*.ml`, `lib/http/server*.mli`, `test/http_common/server_common_suites.ml` |
| Public Eio server adapter | Present for plaintext H1, h2c prior knowledge, and HTTPS ALPN dispatch. Public entry points include `start_h1`, `run_h1`, `start_h2c`, `run_h2c`, `start_https`, and `run_https`, plus `_on_socket` variants. | `lib/http_eio/server.mli` |
| HTTP/2 cleartext | Present as h2c prior knowledge. Requests are handled through `H2.Server_connection`, with streaming bodies and response trailers. | `lib/http_eio/h2_server_connection.ml`, `test/http/test_eta_http_h2_server.ml` |
| HTTP/1.1 server | Present. Public `start_h1` / `run_h1` APIs and an H1 server connection owner exist. | `lib/http_eio/server.mli`, `lib/http_eio/h1_server_connection.ml`, `test/http/test_eta_http_h1_server.ml` |
| TLS server | Present. The OpenSSL/Eio TLS adapter exposes `server_context`, `server_of_flow`, `server_of_flow_with_context`, SNI certificate selection, ALPN policy, and strict-SNI mode. | `lib/http_eio/tls/tls_eio.mli`, `lib/http/tls/config.mli`, `test/http/test_eta_http_tls.ml` |
| HTTPS ALPN server dispatch | Present. HTTPS listeners dispatch negotiated ALPN to H2 or H1 and count H1/H2/rejected ALPN outcomes. | `lib/http_eio/server.mli`, `lib/http_eio/alpn_server.mli`, `lib/http_eio/server_stats.mli`, `test/http/test_eta_http_tls.ml` |
| HTTP/2 graceful shutdown | Present for server shutdown: Eta emits GOAWAY, rejects new streams beyond the cutoff, and closes after the configured deadline. | `lib/http_eio/h2_server_connection.ml`, `test/http/test_eta_http_h2_server.ml` |
| Observability | Partial. Request tracing helpers, server metrics, listener stats, ALPN counters, and connection/request metadata exist. A full access-log recipe and operator-facing metrics guide are still missing. | `lib/http_eio/server.ml`, `lib/http_eio/server_types.mli`, `lib/http/server_meter.ml`, `lib/http/server_tracer.ml` |
| Adversarial coverage | Incomplete. H1/H2/TLS adversarial fixtures exist, but long-run soak coverage and full internet-facing hardening coverage are not yet documented as a release gate. | `http-testsuite/test/cve_regress/`, `http-testsuite/test/red_probes/` |
| WebSocket server | Missing. WebSocket client transport and frame codec exist, but there is no server-side upgrade path. | `lib/http_eio/ws/ws_client.mli`, `lib/http/ws/codec.mli` |

## Remaining Production Work

These must be refreshed before Eta can honestly make a broad production HTTP
server readiness claim.

| Gap | Production impact | Required work |
| --- | --- | --- |
| WebSocket server upgrade | The client and codec surfaces exist, but applications cannot accept WebSocket upgrades through Eta's server. | Add HTTP/1.1 upgrade validation, `Sec-WebSocket-Accept`, subprotocol negotiation, bidirectional frame ownership, close handshake, ping/pong, masking enforcement, and frame-size limits. |
| Operator-facing readiness docs | Operators need exact deployment recipes, limits, stats, logs, metrics, and shutdown behavior before exposing a server directly. | Document direct HTTPS, H1 reverse-proxy upstream, h2c reverse-proxy upstream, graceful shutdown, stats/metrics, timeout tuning, and error hooks. |
| Advanced TLS/deployment features | Direct internet deployment often needs mTLS, certificate reload, trusted proxy policy, and clear SNI/certificate rotation guidance. | Add or explicitly document mTLS, certificate reload strategy, trusted `Forwarded` / `X-Forwarded-*` policy, and process/socket activation patterns. |
| Server-side security and soak matrix | Feature tests exist, but production claims need adversarial, resource-bound, and long-run evidence tied to release gates. | Keep H1/H2/TLS malformed-input tests current; add soak tests for bounded memory, file descriptors, deadline-respecting shutdown, no fiber leaks, and stable metrics. |

## HTTP/1.1 Server Detail

The HTTP/1.1 server is now present. Keep treating it as a first-class protocol
engine, not as a thin line reader. The behavior to keep covered includes:

- Request line parsing for origin-form, absolute-form where accepted, authority-form for `CONNECT`, and asterisk-form for `OPTIONS *`.
- Mandatory `Host` handling for HTTP/1.1 and clear rejection of invalid or duplicated authority state.
- Strict `Content-Length` and `Transfer-Encoding` handling, including rejection of ambiguous or conflicting framing.
- Chunked request body decoding, chunk extensions policy, body trailers policy, and maximum trailer limits.
- Keep-alive by default for HTTP/1.1, close semantics for HTTP/1.0 if supported, and deterministic connection shutdown after unrecoverable parse errors.
- `Expect: 100-continue` support or explicit rejection before reading large bodies.
- Pipelining policy. Either implement ordered pipelined responses or explicitly disable pipelining by reading one request at a time and closing on unsupported overlap. Do not silently allow unbounded queued requests.
- Response framing for fixed, streaming, empty, and trailer-bearing responses.
- Mandatory no-body handling for `HEAD`, `1xx`, `204`, and `304` responses.
- Header validation that prevents response splitting and rejects invalid request field names or unsafe control characters.
- Upgrade handling policy for WebSocket and h2c. If not implemented initially, return clear protocol responses instead of passing malformed state to handlers.

Eta currently owns the H1 server connection path. Keep conformance and fuzz
tests current before widening production claims.

## TLS Server Detail

The TLS server layer now exists. The remaining production contract should cover:

- Certificate chain and private key loading with clear startup errors.
- SNI-based certificate selection.
- ALPN selection for `h2` and `http/1.1`.
- Configurable minimum TLS version. TLS 1.3 should be supported; TLS 1.2 should
  only be allowed with a documented modern cipher policy if retained.
- Optional mutual TLS with client certificate verification and a typed way to
  surface peer identity to the handler.
- Handshake timeout and handshake failure metrics.
- Correct TLS close behavior and handling of peers that close without
  close-notify.
- Certificate reload strategy for long-running processes.
- Tests for certificate mismatch, expired/self-signed test roots, missing SNI,
  unsupported ALPN, and handshake timeout.

The package boundary should stay clear: server TLS belongs in `eta_http_eio` or
a similarly optional HTTP transport package, not in the core `eta` runtime.

## HTTP/2 Remaining Detail

The h2c and HTTPS/H2 paths are useful, but production HTTP/2 still needs
current evidence for:

- Explicit defaults for h2 settings, including max concurrent streams, initial
  window sizes, header list size, and frame size policy.
- Admission control for stream churn and reset storms.
- Defense tests for rapid reset, CONTINUATION floods, HPACK bombs, PING floods,
  SETTINGS floods, empty-frame floods, and WINDOW_UPDATE accounting.
- Per-stream idle timeout and request body timeout.
- Wire stream id exposure and correlation in request metadata should remain
  covered by tests and docs.
- Clear behavior for h2 request trailers and unsupported extended CONNECT.

## Observability And Operations

Production operation needs more than in-memory counters:

- Structured access logs with request id, connection id, peer, scheme, authority,
  method, target, status, bytes in/out, duration, protocol, ALPN, TLS state, and
  error kind.
- Metrics for accepts, active connections, active streams, opened/completed/reset
  streams, request bytes, response bytes, protocol errors, TLS handshakes,
  handshake failures, parser failures, handler failures, overload rejections,
  timeouts, and shutdown state.
- Configurable logging/error hooks instead of swallowed listener exceptions.
- Readiness/draining state so deploy systems can stop routing before shutdown.
- A documented stats API that distinguishes cumulative counters from gauges.
- OpenTelemetry spans that cover connection accept, request handling, response
  write, and error paths without leaking full URLs unless configured.

## Backpressure And Overload

Current config includes max connections, max h2 concurrent streams, read buffer
size, and command queue capacity. That is a start, but production overload
behavior needs to be explicit:

- Listener admission must return deterministic overload behavior instead of only
  relying on backlog and scheduler pressure.
- Per-connection command queues need documented behavior when full: block reader,
  reset stream, close connection, or reject request.
- Request bodies need memory accounting across all active connections.
- Streaming responses need backpressure from socket writes through handler
  effects.
- Large fixed responses should not require unbounded materialization before
  writing; document the limit or require streaming for large payloads.
- Add per-route or per-handler concurrency limits as composable server middleware
  only if Eta can keep the application-state boundary intact.

## Protocol Semantics To Enforce

The server should enforce protocol invariants before the handler sees a request:

- Valid method token and target form.
- Valid header field names and values.
- Host and `:authority` consistency.
- Scheme and authority reconstruction under direct TLS and trusted reverse proxy
  modes.
- Correct request body availability for methods that usually have no body
  without forbidding legal HTTP semantics.
- Correct response body suppression for `HEAD`, informational responses, `204`,
  and `304`.
- Trailer restrictions and explicit unsupported-trailer errors where necessary.
- Clear behavior for `CONNECT`, extended `CONNECT`, `TRACE`, and `OPTIONS *`.

## WebSocket, SSE, And Upgrades

Server-side WebSocket is missing. This does not have to block a basic HTTP
server claim, but it blocks a common production feature once Eta presents itself
as an HTTP server library.

Required WebSocket server work:

- HTTP/1.1 upgrade detection and validation.
- `Sec-WebSocket-Accept` response generation.
- Subprotocol negotiation.
- Transition from HTTP request handling to bidirectional frame ownership.
- Close handshake, ping/pong handling, frame size limits, masking enforcement,
  and typed errors.

Server-sent events can already be modeled as streaming responses, but Eta should
document the recipe and include heartbeat/backpressure examples.

## Deployment Surface

Eta should document and test the intended deployment shapes:

- Direct HTTPS origin: Eta terminates TLS, negotiates ALPN, and serves h1/h2.
- Reverse proxy upstream over h1: supported by the HTTP/1.1 server.
- Reverse proxy upstream over h2c: possible only with proxies that support h2c
  upstream prior knowledge.
- Internal cleartext h2c: acceptable for controlled service meshes, not a public
  internet story.

Deployment features still to consider:

- IPv4/IPv6 examples and dual-stack behavior.
- `SO_REUSEPORT` or multi-process accept strategy if needed.
- Systemd socket activation or documented externally-owned socket startup.
- Trusted proxy header policy for `Forwarded` and `X-Forwarded-*`.
- PROXY protocol support only if Eta needs to sit behind L4 load balancers that
  rely on it.
- Graceful reload pattern for TLS certificates and process restarts.

## API Recommendation

The protocol-oriented server API now exists. Keep the explicit entry points
instead of adding compatibility shims around older h2c-only assumptions.

Current shape:

- `Eta_http_eio.Server.start_h1` and `run_h1` for explicit plaintext HTTP/1.1.
- `Eta_http_eio.Server.start_h2c` and `run_h2c` for explicit h2c prior
  knowledge.
- `Eta_http_eio.Server.start_https` and `run_https` for TLS plus ALPN dispatch.
- A shared `Server.Config.t` that contains protocol-independent limits,
  protocol-specific h1/h2/tls sub-configs, observability hooks, and shutdown
  policy.
- A single internal connection lifecycle abstraction used by h1, h2c, and https
  dispatch so stats, logging, shutdown, and error handling do not drift.

Do not provide silent fallback behavior. Unknown ALPN, invalid TLS config,
unsupported upgrades, invalid framing, and impossible server states should fail
early and loudly.

## Test And Acceptance Gates

Eta should not mark the HTTP server production-ready until all of these pass:

- `nix develop -c dune runtest --force`
- h1 server unit tests for parsing, bodies, keep-alive, close, chunked,
  `Expect: 100-continue`, invalid framing, header limits, response no-body
  cases, and pipelining policy.
- h1 fuzz tests for request parsing and header parsing.
- TLS server tests for handshake success, certificate errors, SNI, ALPN h2,
  ALPN h1, missing ALPN fallback, unknown ALPN rejection, and handshake timeout.
- h2 server tests for GOAWAY graceful drain, stream admission after drain starts,
  rapid reset, CONTINUATION flood, HPACK limits, PING/SETTINGS floods, stalled
  body, stalled response write, and oversized headers.
- Interop tests against at least curl, nghttp2, h2spec where feasible, Caddy or
  nginx as reverse proxy, and common health-check clients.
- Load and soak tests that assert bounded memory, bounded file descriptors,
  deadline-respecting shutdown, no fiber leaks, and stable metrics.
- Documentation examples for direct HTTPS, h1 reverse-proxy upstream, h2c
  reverse-proxy upstream, graceful shutdown, and observability hooks.

## Suggested Roadmap

1. Maintain HTTP/1.1 server support.
   - Keep `H1.Server_connection`, `start_h1`/`run_h1`, strict parser limits,
     keep-alive, chunked/fixed bodies, response writer semantics, and focused
     tests current.

2. Maintain TLS server support.
   - Keep `Tls_eio.server_of_flow`, TLS server config, certificate/SNI/ALPN
     handling, handshake timeout, typed handshake errors, and TLS tests current.

3. Maintain HTTPS ALPN dispatch.
   - Keep routing `h2` to the h2 server engine and `http/1.1` or no ALPN to
     the h1 engine. Keep unknown ALPN rejection, stats, tracing, and shutdown
     coverage current.

4. Finish HTTP/2 production semantics.
   - Keep GOAWAY graceful drain covered, document h2 limits, and expand
     adversarial defenses.

5. Add operational hardening.
   - Add structured logs, metrics hooks, readiness/draining state, finite
     timeout defaults, overload behavior, and docs.

6. Add optional production features.
   - Server WebSocket, compression, proxy header policy, PROXY protocol, mTLS,
     HTTP/3/QUIC, and advanced reload/socket activation support as separate
     explicit packages or config surfaces.

## Non-Goals

Eta should not become an application framework while making the server
production-ready. Routing tables, authentication, sessions, persistence,
business-state management, and application-specific middleware remain
application-owned. Eta should own protocol interpretation, resource safety,
typed failure preservation, cancellation cleanup, scoped lifecycle, close
fences, backpressure, and runtime observability.
