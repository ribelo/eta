---
id: Eta-2ap
title: "H-Q4a: Scripted fixture interop (curl, nghttp2, production-like local
  server) replaces public-server scope"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-22T15:25:54.321Z
created_by: backlog
updated_at: 2026-05-24T15:19:28Z
closed_at: 2026-05-24T15:19:28Z
close_reason: Proven — h_q4a_interop_matrix contains curl/nghttp2/nginx/Caddy
  scripted fixtures; run_matrix.sh passes 25/25 rows.
dependencies:
  - issue_id: Eta-2ap
    depends_on_id: Eta-adr
    type: parent-child
    created_at: 2026-05-22T19:03:57.573Z
    created_by: backlog
---

# H-Q4a: Scripted fixture interop (curl, nghttp2, production-like local server) replaces public-server scope

## description

HYPOTHESIS (per Review #2 + Review #3 SSE/server-push additions). eta-http interop is provable via scripted fixture servers (NOT a public eta-http server stub) plus curl, nghttp2, and at least one production-like local server (e.g., nginx, Caddy, or h2o) covering: HTTPS ALPN h2 negotiation, h2c prior-knowledge (test only, h2c is not v1 scope for production), HTTP/1.1 keep-alive, redirect chain, trailers, HEAD, early responses, large body, cancellation, chunked transfer, AND: SSE long-lived streaming response with heartbeat, server-push attempt by a misbehaving peer (must be rejected), and WebSocket upgrade attempt (must be rejected with a typed error and not crash the connection). The matrix is a coverage table not a request count. REPLACES H-Q4 (closed). H-Q4 leaked public eta-http server scope by requiring eta-http server stub for bidirectional testing. eta-http v1 is client-only; scripted fixtures (e.g., ocaml-h2 server mode for tests, Python aiohttp test server for h1) are fine, but a public eta-http server is not. Also curl --http2-prior-knowledge tests h2c which bypasses the normal HTTPS ALPN path; we need both. WHY IT MATTERS. Self-consistency is not enough. Interop bugs surface only against real implementations and protocol-level edge cases (100-Continue, trailers, zero-byte DATA without END_STREAM, mid-body RST, flow-control exhaustion, ALPN downgrade). SSE is in-scope-by-implication if streaming bodies are in-scope; testing it here keeps it from becoming an accidental regression. WebSocket upgrade is OUT of scope for v1 but must be rejected gracefully (RFC 8441 reserves the extension point; eta-http v1 must not foreclose it but must also not pretend to support it). BLAST RADIUS. Medium. Interop bugs are fixable but block real-world use. FAST FALSIFIER. scratch/eta_http_research/h_q4a_interop_matrix/. Build a coverage matrix with rows = scenarios and columns = peers (curl --http1.1, curl --http2 over TLS+ALPN, curl --http2-prior-knowledge h2c, nghttp curl client, nginx h1+h2 server, Caddy h2 server). Scenarios: GET/POST/HEAD happy path, 100-Continue header, chunked + Trailer, h2 trailers via HEADERS+CONTINUATION+END_STREAM, zero-byte DATA without END_STREAM, mid-body RST_STREAM, server-side flow-control exhaustion (server WINDOW=8KB), ALPN downgrade (server prefers h1 even when client offers h2), early 413 during upload, chunked upload, large body 100MB, request cancellation mid-body, NEW: SSE long-lived response with text/event-stream content-type, periodic heartbeat comments, client cancel after N events (response_body_idle_timeout from H-D6 must NOT fire while heartbeats arrive), NEW: server-push attempt by a misbehaving peer that ignored SETTINGS_ENABLE_PUSH=0 (eta-http closes the connection per RFC 9113 sect 8.4), NEW: server replies 101 Switching Protocols / Upgrade: websocket (eta-http rejects with a typed error, does not attempt the upgrade).

## design

DISPROOF SIGNATURES. Coverage cells fail with non-trivial frequency (more than 1-2 cells per peer is a real bug, not a spec ambiguity). Or scenarios cannot be expressed as fixture (we'd have to write a full server to test something). Or peers disagree on behavior in ways the spec does not arbitrate. POSITIVE EVIDENCE NEEDED. Coverage matrix populated; pass rate documented. Failures (if any) shrink to scenarios that become regression tests in eta-http's main suite. No public eta-http server is filed as a result of this hypothesis. ARTIFACTS. scratch/eta_http_research/h_q4a_interop_matrix/{matrix.md, scenarios/, peer_runners/{curl.sh, nghttp.sh, nginx.conf, caddy.conf}, dune, README.md, results.md, failure_cases/}. Journal entry V-Http-Q4a.

## acceptance criteria

scratch/eta_http_research/h_q4a_interop_matrix/ exists with coverage matrix. results.md documents pass/fail per cell. Failure cases (if any) are shrunk to regression fixtures. Verdict explicit. Journal entry V-Http-Q4a added.
