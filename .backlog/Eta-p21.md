---
id: Eta-p21
title: "P1: h2 request path writes entire body before reading response — needs
  owner-loop"
status: open
priority: 1
issue_type: bug
created_at: 2026-05-24T12:51:57.656Z
created_by: backlog
updated_at: 2026-05-24T12:52:02.651Z
dependencies:
  - issue_id: Eta-p21
    depends_on_id: Eta-0xe
    type: parent-child
    created_at: 2026-05-24T12:52:02.651Z
    created_by: backlog
---

# P1: h2 request path writes entire body before reading response — needs owner-loop

## description

Bug: request_h2_on_flow (client/client.ml:166-248) writes/flushes all request body chunks, closes the request writer, flushes again, and only then enters the response wait/read loop. This serial write-before-read pattern:

1. Breaks HTTP/2 full-duplex semantics — WINDOW_UPDATE, RST_STREAM, GOAWAY, and early responses cannot be observed until the entire request body is sent.
2. Large streaming uploads deadlock if the peer needs window updates.
3. The ALPN auto client (make ~protocol:Auto at client/client.ml:324-356) creates a new TCP+TLS connection per request and never reuses h2 connections.

Location: packages/eta-http/client/client.ml:166-248, 324-356; packages/eta-http/h2/writer.ml

## design

Introduce H2_connection resource with dedicated reader fiber + writer fiber owning the Eio flow + wakeup channel + stream admission + per-stream response/body state + GOAWAY/close state. Request API opens a stream and returns response when headers arrive. Caller fibers communicate through Channel/buffers, never touching the socket directly. Also: an origin-scoped h2 connection pool whose resource is the owner-loop multiplexer, not a raw flow.

## acceptance criteria

h2 owner-loop exists with dedicated reader/writer fibers. Callers communicate via Channel, not direct socket I/O. Concurrent streams over shared connection work. H-D1 multiplexer stress fixtures still pass. Existing h2 tests pass.
