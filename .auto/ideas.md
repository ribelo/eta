# H2 TLS steady-state latency — ideas backlog

The gap is the shared H2+TLS request path (~2ms p99 at c=16 p=16 vs Go 0.74ms).
Per-request cost lives in: TLS record read/decrypt, h2 frame parse + HPACK,
stream demux, handler, h2 frame encode + HPACK, TLS record encrypt/write. Pick
the per-request CPU/alloc/scheduling hops that don't scale.

## 1. TLS record write coalescing / batching across streams
Many concurrent streams each issue a TLS record write (encrypt + writev) for
their HEADERS/DATA. Under p=16, that's many small TLS records per event-loop
turn. tls_eio `single_write` is per-call. Batching/coalescing pending stream
writes into fewer, larger TLS records (and fewer writev syscalls) could cut
both per-record encrypt cost and syscalls — likely the biggest lever for
multi-stream tail. Look at how h2_server_connection schedules writes and
whether tls_eio has a write queue.

## 2. HPACK encode/decode allocation reuse
HPACK per-frame alloc (dynamic table indexing, header string allocs). Check
lib/http/h2 hpack for per-request buffers; reuse across requests on a connection.

## 3. H2 response write path: HEADERS+DATA single writev
Mirror the H1 plain win (write head+body in one writev). For a fixed echo
response, HEADERS + DATA could be one write through the TLS record path (one
encrypt + one writev), not two. Watch flow-control (DATA must respect window).

## 4. Per-connection bookkeeping contention (server.ml global mutex)
Many concurrent streams register/deregister; under p=16 that's more per-conn
lock ops. If the h2 path takes the global mutex per stream, contention could
add tail. Make stats/registry per-domain or skip under no-otel.

## 5. Eio scheduling hops per frame
Each frame read/write is a fiber scheduling round. Under many streams, the
event-loop churn adds tail. Look for unnecessary Fiber.yield / forks per frame
in the h2 read/write loops.

## 6. Steady-state TLS single_read/single_write overhead
tls_eio single_read does feed_bio (under read_mutex) + SSL_read (under ssl_mutex)
per call. Per-request this is several mutex ops. Mostly uncontended (per-conn)
so likely small, but verify under stream burst.

## Off the table (don't chase)
- static_1k handler file-I/O (off-limits).
- Handshake cost (amortized away in keep-alive steady-state).
- oha/client ceiling (oha on 8 cores, server multi-domain; steady-state, not
  handshake-bound, so the env ceiling is much higher than the H1 TLS session).
