# Deferred / remaining ideas (H2 tail latency)

## Tried this session (all kept)
- [x] Single-chunk fixed-body fast path (#2) — kept, small win
- [x] Share-on-unchanged header normalization (#3) — kept, moderate win
- [x] Body-read timeout sync-skip (#4) — kept, big echo win
- [x] Response-write timeout watchdog (#5) — kept, broad win (all endpoints)
- [x] OTEL span-attr lazy (#7) — kept, rps/p50 win
- [x] OTEL metric-attr gate (#8) — kept, rps/p50 win
- [x] Span wrapper skip when tracing off (#9) — kept, rps/p50 win
- [x] Decimal content-length writer (#11) — kept, small p99/p50 win

## Discarded (within noise or probe tuning)
- [~] OTEL-off diagnostic (#6) — quantified cost, intentionally discarded
- [~] Content-length 0-9 precompute (#10) — below p99 noise
- [~] Content-length 0-9999 precompute (#12) — below p99 noise
- [~] Larger minor GC heap (#13) — neutral, probe tuning

## High-value, higher-effort (not yet tried)

### Stream Hashtbl consolidation
Consolidate remote_end_streams, remote_reset_streams, graceful_rejected_streams,
remote_reset_ordinals, pending_request_trailers Hashtbls into stream_state
mutable fields. retire_stream does 8 Hashtbl.remove calls per stream retirement
(each involving hash_exn + compare). Consolidation reduces this to 3 removes
(stream_ordinals, stream_ids_by_ordinal, streams). The stream_id-keyed boolean
Hashtbls have pre-stream/post-stream uses that make consolidation tricky;
ordinal-keyed ones (remote_reset_ordinals, pending_request_trailers) are safe.
caml_hash_exn 2.6% + caml_compare 2.2% in profile.

### await_owner promise+command roundtrip
Every response (all endpoints) goes through `await_owner t (fun resolver ->
Response_start (ordinal, prepared, resolver))`: creates Eio.Promise + enqueues
command + handler fiber suspends/resumes. This is a fiber context switch +
allocation per response. For small fixed responses (all benchmark endpoints),
the handler doesn't need to wait — the full response is already prepared.
A fire-and-forget `enqueue_response` variant could skip the promise + await.
Risk: loses error feedback (connection write failures not reported to handler).

### HPACK decode string pooling
Decoder allocates fresh name/value strings per header per request (main string
allocator, caml_alloc_string 2.4% in profile). Static-table indexed headers
already reuse shared strings (#2); only literal headers pay. Could pool a
per-connection decode buffer or intern common literals.

### Eta.Runtime sync-handler fast path
Handler runs through Eta.Runtime.run effect interpreter (eval/perform/resume).
For handlers that return plain values (Eta.Effect.pure) — which is the common
case for root/user_id — the interpreter overhead is a single `match Pure -> Ok`.
But for effectful handlers (echo reads body), the interpreter processes
multiple Effect nodes. A "sync handler detection" that bypasses unnecessary
interpreter wrapping could help. Requires understanding of which Effect ops
the handler uses.

### Response body copy elimination
`respond` in connection.ml copies the body string into a Bigstringaf
(`Bigstringaf.of_string`) before queuing DATA frames. For 1KB bodies (static_1k,
echo), this is a per-response memory copy. Could be avoided if the H2 write
path accepted strings directly instead of Bigstringaf.

### response_write_timeout on streaming path
Streaming response handlers still pay per-write with_timeout (#5 only fixed
the writer-loop's per-write timeout). For benchmark (fixed responses), not on
the hot path, but streaming servers benefit from the same watchdog approach.

### HPACK encode response header caching
`encode_response_headers` runs per response. For common responses (e.g., root
empty 200), the encoded header block is always identical. A simple
(status, headers) → encoded_block cache could skip encoding for repeated
responses. The HPACK dynamic table changes between connections, but within a
connection, common responses repeat.

## Noise limitations
p99 geomean is now limited to ~150-250µs noise from body-endpoint tail variance.
Micro-optimizations below ~3-5% p99 improvement may be undetectable. Increasing
ETA_H2_REPS in measure.sh from 3 to 5-7 would reduce noise and make smaller wins
detectable, at the cost of doubling experiment duration.
