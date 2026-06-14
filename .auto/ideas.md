# Deferred / higher-effort ideas (H2 tail latency)

## GC / allocation (prime tail driver)
- **Tune OCaml GC for low pause**: larger minor heap (Gc.set minor_heap_size) to
  reduce minor-collection *frequency*, and/or set space_overhead to trade memory
  for fewer major slices. p99 spikes are likely minor/major GC. Measure RSS guard.
  Set once at probe startup (or per-connection runtime init) — but the real fix
  is allocating less, not collecting less often.
- **HPACK decode string pooling / interning**: decoder allocates fresh name+value
  strings per header per request (main string allocator). Pool a per-connection
  decode buffer or intern static-table names. Use memtrace to confirm attribution.
- **Eta.Runtime sync-handler fast path**: handler runs through the effect
  interpreter (eval/perform/resume; Effect.effc, caml_resume, caml_perform per
  request). A path where a handler returning a plain value skips the interpreter
  could cut allocation + latency.

## Scheduler / jitter
- **Handler-timeout watchdog poll jitter**: the watchdog daemon sleeps on a timer
  (Eio_utils.Zzz heap, ~1.2% CPU). Its wakeups may add tail jitter. Try making it
  sleep until the earliest deadline (adaptive) instead of fixed-interval polling.
- **response_write_timeout still uses with_timeout** — replace with the same
  deadline+watchdog approach as handler_timeout (one sleeper fiber per write
  removed; may smooth the tail).
- **Move owner loop under handler switch** so await_owner uses plain
  Eio.Promise.await (close via cancellation) — removes a per-command Fiber.first.

## Per-stream work spikes
- **Consolidate the stream Hashtbls** into stream_state so retire_stream does 1
  remove instead of ~8 (each remove hashes id/ordinal; ~3.4% CPU in caml_hash_exn
  + find_opt). Fewer hash ops per stream teardown = smaller per-stream spike.
- **stream_ids_by_ordinal cleanup is load-bearing** (removing it caused unbounded
  table growth) — keep it, but the consolidation above can fold it in.

## Measurement / diagnosis
- Profile specifically for tail: capture p99-request stacks (perf with timestamps,
  or memtrace allocation spikes correlated with latency). Steady-state perf record
  shows the mean hot path, not the tail; need to localize what spikes.
- Consider a higher-concurrency or bursty load shape variant to amplify the tail
  signal IF the 16-stream shape proves too quiet for stable p99 — but keep the
  primary shape comparable to the throughput session.

## Tried and rejected (throughput session — may differ for latency)
- Reuse H1 read_scratch (kept, small).
- H2 response header rev_map (inlining regression).
- Writer-timeout watchdog alone (net flat on throughput; UNTESTED for tail).
