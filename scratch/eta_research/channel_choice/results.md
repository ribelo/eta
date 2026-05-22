# Eta Bounded Channel Choice Results

## Verdict

Eta needs a public bounded channel or permit primitive for eta-http backpressure.
Neither existing candidate is enough:

- Eta_stream.Mailbox is useful for nonblocking wakeups, but it drops on full and
  cannot model HTTP/2 flow-control WAIT semantics.
- Eio.Stream blocks on full, but has no close protocol. A sender blocked in
  Eio.Stream.add can still enqueue after an external close flag is set.

For v1 eta-http dogfooding, the best implementation direction is a same-domain
Eta.Channel built from Eio.Mutex + Eio.Condition with a preallocated ring
buffer. The ring variant keeps the same semantics as mutex + Queue and allocates
less in the hot-path probe.

Do not promise cross-domain portability for this primitive in v1. The
Eio.Mutex/Condition implementation is nonportable under Domain.Safe.spawn, and
eta-http I/O handles are already same-domain Eio values.

## Commands

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/channel_choice/channel_choice.exe
nix develop .#oxcaml -c ocamlfind ocamlc -package eio -thread -c scratch/eta_research/channel_choice/domain_safe_eio_mutex_channel_negative.ml
~~~

## Results

~~~text
stress candidate=mutex_queue elapsed_ms=2 sum=44160 sent=3840 received=3840 max_depth=16 final_depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
stress candidate=mutex_ring_int elapsed_ms=1 sum=44160 sent=3840 received=3840 max_depth=16 final_depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
cancel_blocked_sender candidate=mutex_queue outcome=cancelled received=1 sent=1 stats_received=1 final_depth=0 waiting_senders=0 cancelled_senders=1
cancel_blocked_sender candidate=mutex_ring_int outcome=cancelled received=1 sent=1 stats_received=1 final_depth=0 waiting_senders=0 cancelled_senders=1
close_blocked_sender candidate=mutex_queue outcomes=closed,close_called drained=1 sent=1 received=1 closed=true final_depth=0 waiting_senders=0 cancelled_senders=0
close_blocked_sender candidate=mutex_ring_int outcomes=closed,close_called drained=1 sent=1 received=1 closed=true final_depth=0 waiting_senders=0 cancelled_senders=0
allocation_probe candidate=mutex_queue minor_words=280024 promoted_words=24 major_words=24
allocation_probe candidate=mutex_ring_int minor_words=220024 promoted_words=24 major_words=24
mailbox_drop_smoke first=enqueued second=dropped dropped=1
eio_stream_close_gap closed=true first=1 second=2 blocked_finished=true
~~~

Mode negative:

~~~text
domain_safe_eio_mutex_channel_negative.ml:
Error: This value is "nonportable"
because it closes over the value "Eio.Mutex.lock" ... expected to be "portable".
~~~

## Candidate Ledger

| Candidate | Strongest case | Evidence against | Status |
| --- | --- | --- | --- |
| Eta_stream.Mailbox | Already exists; nonblocking offer is good for cancellation wakeups and writer-intent queues. | Drops on full by design: capacity 1 gives first=enqueued, second=dropped. Not a WAIT/backpressure primitive. | Keep for nonblocking wakeups, not flow-control channel. |
| Eio.Stream | Existing bounded blocking queue. | No close/error propagation. The close-gap smoke shows a blocked sender enqueues value 2 after close=true. | Reject as public Eta.Channel core. |
| Mutex + Queue | Correct semantics: blocking send, cancellation cleanup, close propagation. Simple and generic. | Allocates more than ring in hot-path probe; not portable under Domain.Safe if implemented with Eio.Mutex. | Viable fallback. |
| Mutex + fixed ring | Correct semantics; lower hot-path allocation than Queue; preallocated capacity matches bounded channel semantics. | Int-specialized lab; generic implementation needs a careful representation for payload storage. Same-domain only. | Preferred v1 direction. |
| Portable.Atomic MPMC | Could be cross-domain and portable-payload friendly. | Not needed for same-domain eta-http I/O; much more complex; would still not carry arbitrary Eio handles. | Deferred until a portable-payload use case exists. |

## Recommendation

File Eta.Channel as a same-domain Eta primitive with:

- blocking send/recv;
- try_send/try_recv;
- close propagation to blocked senders and receivers;
- cancellation-safe waiter accounting;
- bounded preallocated storage;
- stats for depth, sent, received, closed, waiting_senders, waiting_receivers,
  cancelled_senders;
- no cross-domain promise in v1.

Keep Eta_stream.Mailbox for nonblocking notification paths such as best-effort
stream wakeups or outbound RST intent queues where dropping or closed reporting
is the right behavior. Do not use it for HTTP/2 flow-control backpressure.
