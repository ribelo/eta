# HTTP Server Production Readiness Audit

Date: 2026-06-11

Audited commit: `7367a63a2`

Scope: Eta's HTTP server substrate in `lib/http/` and `lib/http_eio/`. Client
features are mentioned only when they expose server asymmetry. This audit treats
"production-ready" as suitable for an internet-facing origin server or a
reverse-proxy upstream that accepts ordinary HTTP clients, bounds resources,
survives malformed traffic, shuts down safely, and exposes enough operational
signals to run under load.

Eta's HTTP server is not production-ready today.

The current server surface is an h2c prior-knowledge Eio adapter. The shared
`Eta_http.Server` handler/request/response model exists, and the h2c path has a
reasonable first set of lifecycle, request-body, streaming-response, trailer,
shutdown, and stats tests. The production blockers are still structural:
HTTP/1.1 server support is missing, server-side TLS is missing, HTTPS ALPN
dispatch is missing, HTTP/2 graceful drain does not send GOAWAY, and adversarial
server-side coverage is incomplete.

A reverse proxy does not fully solve the gap. Most proxies speak HTTP/1.1 to
upstreams by default, and Eta currently has no HTTP/1.1 server. A proxy that can
talk h2c prior knowledge upstream can make a controlled internal deployment
possible, but TLS, HTTP/1.1, and ALPN correctness would belong to the proxy, not
Eta.

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
| Public Eio server adapter | h2c only. Public entry points are `start_h2c`, `start_h2c_on_socket`, `run_h2c`, and `run_h2c_on_socket`. | `lib/http_eio/server.mli` |
| HTTP/2 cleartext | Present as h2c prior knowledge. Requests are handled through `H2.Server_connection`, with streaming bodies and response trailers. | `lib/http_eio/h2_server_connection.ml`, `test/http/test_eta_http_h2_server.ml` |
| HTTP/1.1 server | Missing. Existing h1 code is client-oriented parser/writer/pool code; there is no `run_h1`, `start_h1`, or h1 server connection owner. | `lib/http/h1/`, `lib/http_eio/h1/`, `rg run_h1` |
| TLS server | Missing. OpenSSL/Eio TLS adapter exposes `client_of_flow`; there is no `server_of_flow`, certificate/key configuration, SNI callback, or server handshake path. | `lib/http_eio/tls/tls_eio.mli`, `lib/http/tls/` |
| HTTPS ALPN server dispatch | Missing. Backend-neutral ALPN helpers and client dispatch exist, but no server listener negotiates `h2` vs `http/1.1`. | `lib/http/transport/dispatch.mli`, `lib/http_eio/client.ml`, no server TLS entry point |
| HTTP/2 graceful shutdown | Partial. Eta drains active streams before closing, but does not send a graceful HTTP/2 GOAWAY admission signal. | `lib/http_eio/h2_server_connection.ml` |
| Observability | Partial. Request tracing helpers exist and server stats count active/opened/closed connections. Listener errors are currently ignored by `on_error:(fun _exn -> ())`, and there is no access log or exported metrics surface. | `lib/http_eio/server.ml`, `lib/http_eio/server_types.mli` |
| Adversarial coverage | Incomplete. h2 adversarial/CVE fixtures are placeholders because TLS server bindings are not implemented. | `http-testsuite/lib/adversarial.ml` |
| WebSocket server | Missing. WebSocket client transport and frame codec exist, but there is no server-side upgrade path. | `lib/http_eio/ws/ws_client.mli`, `lib/http/ws/codec.mli` |

## P0 Production Blockers

These must be fixed before Eta can honestly claim production HTTP server
readiness.

| Gap | Production impact | Required work |
| --- | --- | --- |
| HTTP/1.1 server transport | HTTP/1.1 remains the common baseline for clients, load balancers, health checks, and proxy upstreams. Without it, Eta is not a general HTTP server. | Add an h1 server connection owner, public `start_h1`/`run_h1` APIs or a unified protocol API, strict request parsing, keep-alive, connection close handling, chunked bodies, fixed-length bodies, `Expect: 100-continue`, request trailers policy, and response serialization from `Eta_http.Server.Response`. |
| Server-side TLS | No HTTPS listener can be run by Eta. This blocks direct internet exposure, h2 over TLS, ALPN, certificate identity, and most realistic interop/adversarial h2 testing. | Add OpenSSL server context bindings and Eio flow wrapper: certificate chain, private key, trust store for optional mTLS, TLS versions/cipher policy, ALPN selection, SNI selection, handshake errors, close-notify behavior, and reloadable certificate material. |
| HTTPS ALPN dispatch | HTTP/2 over TLS is negotiated by ALPN, and HTTP/1.1 must remain the fallback when ALPN is absent or selects `http/1.1`. | Add a server dispatch layer that maps negotiated ALPN to h2 or h1, rejects unknown protocols clearly, records the negotiated protocol in `Server.Request`, and shares lifecycle/error/accounting code across h1 and h2. |
| True HTTP/2 graceful shutdown | Closing after active streams drain is useful, but clients are not warned to stop creating new streams. During deploys this can cause avoidable resets and tail failures. | Send GOAWAY with a valid last stream id, reject new streams after graceful shutdown starts, allow covered streams to complete, and close after the configured deadline. If the upstream h2 API cannot expose this cleanly, wrap or patch that layer rather than silently approximating graceful shutdown. |
| Resource limits and timeouts | Slowloris, oversized headers, huge bodies, stalled uploads, stalled response writes, and excessive stream churn can consume memory, fibers, file descriptors, or scheduler time. | Add explicit server config for header byte limits, header count limits, request body size limits, per-request total timeout, header read timeout, body read idle timeout, response write timeout, connection idle timeout, and h2 stream idle timeout. Defaults should be finite and documented. |
| Server error reporting | Listener and connection failures currently have paths that are swallowed or only observable by local stats. Operators cannot distinguish normal closes from parser errors, TLS failures, overload, or handler failures. | Replace ignored `on_error` callbacks with typed error hooks, structured log events, counters, and request/connection ids. Handler exceptions should be contained and mapped to explicit 500/stream reset behavior according to protocol state. |
| Server-side security test matrix | The existing adversarial suite cannot exercise h2 TLS cases, and there is no h1 server to fuzz or attack. | Add h1 parser fuzzing, h1 malformed-request fixtures, h2 rapid-reset/CONTINUATION/HPACK/PING/SETTINGS tests against Eta's server, TLS handshake failure tests, resource-bound assertions, and deadline assertions. |

## HTTP/1.1 Missing Detail

The HTTP/1.1 server should be treated as a first-class protocol engine, not as a
thin line reader. Required behavior includes:

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

Implementation should reuse a mature HTTP/1.1 parser/engine if it fits Eta's
ownership model. If Eta promotes the current h1 parser/writer into a server
engine, add conformance and fuzz tests before exposing it publicly.

## TLS Missing Detail

The TLS server layer needs its own production contract:

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

## HTTP/2 Missing Detail

The h2c server is useful, but production HTTP/2 needs more than the current
cleartext path:

- HTTPS h2 through ALPN.
- GOAWAY-driven graceful drain.
- Explicit defaults for h2 settings, including max concurrent streams, initial
  window sizes, header list size, and frame size policy.
- Admission control for stream churn and reset storms.
- Defense tests for rapid reset, CONTINUATION floods, HPACK bombs, PING floods,
  SETTINGS floods, empty-frame floods, and WINDOW_UPDATE accounting.
- Per-stream idle timeout and request body timeout.
- Wire stream id exposure or correlation in request metadata. The current shared
  request shape can carry `stream_id`, but the h2 server path does not expose
  the h2 stream id to handlers.
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
- Reverse proxy upstream over h1: requires HTTP/1.1 server.
- Reverse proxy upstream over h2c: possible only with proxies that support h2c
  upstream prior knowledge.
- Internal cleartext h2c: acceptable for controlled service meshes, not a public
  internet story.

Missing deployment features to consider after the P0s:

- IPv4/IPv6 examples and dual-stack behavior.
- `SO_REUSEPORT` or multi-process accept strategy if needed.
- Systemd socket activation or documented externally-owned socket startup.
- Trusted proxy header policy for `Forwarded` and `X-Forwarded-*`.
- PROXY protocol support only if Eta needs to sit behind L4 load balancers that
  rely on it.
- Graceful reload pattern for TLS certificates and process restarts.

## API Recommendation

Because API breakage is allowed, avoid compatibility shims around the h2c-only
surface. Keep h2c explicit, but add a protocol-oriented server API that makes the
production modes obvious.

Recommended shape:

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

1. Build HTTP/1.1 server support.
   - Deliver `H1.Server_connection`, `start_h1`/`run_h1`, strict parser limits,
     keep-alive, chunked/fixed bodies, response writer semantics, and focused
     tests.

2. Build TLS server support.
   - Deliver `Tls_eio.server_of_flow`, TLS server config, certificate/SNI/ALPN
     handling, handshake timeout, typed handshake errors, and TLS tests.

3. Add HTTPS ALPN dispatch.
   - Route `h2` to the existing h2 server engine and `http/1.1` or no ALPN to
     the h1 engine. Reject unknown ALPN. Share stats, tracing, and shutdown.

4. Finish HTTP/2 production semantics.
   - Add GOAWAY graceful drain, h2 limits, stream-id metadata, and adversarial
     defenses.

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

