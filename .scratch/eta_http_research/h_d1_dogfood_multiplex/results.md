# H-D1 Dogfood Multiplex Results

## Verdict

Eta primitives can model the HTTP/2 single-connection, many-stream
multiplexer shape without using Eta.Pool and without waking stream fibers with
raw Eio promises.

Status: shipped lab proof for Eta-cxs.

## Scope

This lab is intentionally not a real HTTP/2 stack. It models deterministic
frames over a fake connection:

- one writer fiber owns outbound socket writes;
- stream fibers enqueue HEADERS, DATA, RST_STREAM, and PING through
  `Eta.Channel.try_send`;
- the read loop wakes per-stream fibers with `Eta.Channel.try_send`;
- stream DATA sending uses `Eta.Channel.send` against a bounded per-stream
  window channel;
- stream lifetime uses `Effect.acquire_release`;
- writer/read children are hosted by `Supervisor.scoped`;
- timeout and teardown fixtures use `Effect.timeout_as` and `Effect.race`.

The original zero-allocation/OxCaml-portable target is not the accepted v1
scope. Same-domain Eio fibers use ordinary mutable state, matching Channel and
Pool. Allocation is recorded honestly at realistic concurrency.

## Commands

~~~sh
nix develop -c dune build scratch/eta_http_research/h_d1_dogfood_multiplex/stress.exe scratch/eta_http_research/h_d1_dogfood_multiplex/alloc_sample.exe
nix develop -c _build/default/scratch/eta_http_research/h_d1_dogfood_multiplex/stress.exe
nix develop -c _build/default/scratch/eta_http_research/h_d1_dogfood_multiplex/alloc_sample.exe
~~~

## Stress Result

~~~text
PASS flow-control blocks at 8KB window
PASS flow-control resumes after WINDOW_UPDATE
PASS rst cleanup returns to baseline
PASS mid-flight cancellation queues RST and cleans streams
PASS deadlock teardown is not extended by blocked writer
PASS rapid reset admission counts active and cancelled
h_d1_dogfood_multiplex stress passed
~~~

Fixture mapping:

- Flow control: a 16 KiB request body blocks after the 8 KiB stream window, then
  resumes after WINDOW_UPDATE.
- RST_STREAM cleanup: 50 reset streams return state to active=0, cancelled=0,
  live=0.
- Mid-flight cancellation: half of 20 requests time out; cancellation queues
  RST_STREAM through the writer channel and all stream state is removed.
- Deadlock avoidance: a fake socket write blocks forever; scope teardown
  completes under the 1s `Effect.race` guard through Supervisor scope teardown.
- Rapid reset: 1000 reset-after-HEADERS attempts are capped by admission
  counting ACTIVE + CANCELLED streams against the same limit.

## Allocation Sample

~~~text
h_d1_alloc streams=12800 concurrent=128 elapsed_ms=45 minor_words=14459006 promoted_words=1815712 major_words=1815712 words_per_stream=1129.6 max_inflight=128 opened=12800 completed=12800 local_resets=0 remote_resets=0 admission_rejected=0
~~~

Interpretation:

- The primitive stack is not zero allocation, and should not be described that
  way.
- At 128 concurrent streams, the fake multiplex path allocates about 1129.6
  minor words per stream.
- Max inflight equals the configured 128 stream limit and reuse/leak counters
  return to baseline.

## LOC

~~~text
   25 frame.ml
  121 fake_multiplex_connection.ml
  152 stream_state.ml
   10 writer_fiber.ml
  161 multiplexer.ml
  169 stress.ml
   52 alloc_sample.ml
  690 total
~~~

## Eta Fix

Eta-9sd was fixed during this dogfood pass. `Supervisor.scoped` now cancels
unresolved children when the scope body settles, so the multiplexer can rely on
Supervisor teardown for its long-lived writer/read children.
