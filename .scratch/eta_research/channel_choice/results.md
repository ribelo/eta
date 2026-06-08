# Eta Bounded Channel Choice Results

## Verdict

Eta needs a public bounded channel or permit primitive for eta-http backpressure.
Neither existing candidate is enough:

- Stream.Mailbox is useful for nonblocking wakeups, but it drops on full and
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
| Stream.Mailbox | Already exists; nonblocking offer is good for cancellation wakeups and writer-intent queues. | Drops on full by design: capacity 1 gives first=enqueued, second=dropped. Not a WAIT/backpressure primitive. | Keep for nonblocking wakeups, not flow-control channel. |
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

Keep Stream.Mailbox for nonblocking notification paths such as best-effort
stream wakeups or outbound RST intent queues where dropping or closed reporting
is the right behavior. Do not use it for HTTP/2 flow-control backpressure.

## Shipped Eta.Channel Probe

Command:

~~~sh
nix develop -c dune build scratch/eta_research/channel_choice/channel_impl_probe.exe
nix develop -c _build/default/scratch/eta_research/channel_choice/channel_impl_probe.exe
~~~

Result:

~~~text
try_send_recv iterations=10000 minor_words=3145725 promoted_words=284 major_words=203 sent=10000 received=10000 depth=0
blocking_contention producers=4 total=4000 minor_words=1048576 promoted_words=509 major_words=0 sent=4000 received=4000 depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
~~~

This is a smoke allocation signal for the shipped generic Channel, not a
zero-allocation claim. The behavior counters are the acceptance evidence:
contention drains to depth 0 and leaves no waiting or cancelled waiter residue.

## Channel v2 Wake-One Probe

Question: should the shipped Channel keep Eio.Condition.broadcast or replace it
with explicit waiter queues resolved one-at-a-time?

Command:

~~~sh
nix develop -c dune build scratch/eta_research/channel_choice/channel_v2_probe.exe
nix develop -c _build/default/scratch/eta_research/channel_choice/channel_v2_probe.exe
~~~

Result:

~~~text
v1 behavior_smoke ok
v2 behavior_smoke ok
v1 try_send_recv iterations=100000 elapsed_ms=44.461 minor_words=34078690 promoted_words=2840 major_words=2754 sent=100000 received=100000 depth=0
v2 try_send_recv iterations=100000 elapsed_ms=40.606 minor_words=34602862 promoted_words=948 major_words=928 sent=100000 received=100000 depth=0
v1 blocking_contention capacity=16 producers=4 total=40000 elapsed_ms=21.678 minor_words=15204308 promoted_words=141750 major_words=137198 sent=40000 received=40000 depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
v2 blocking_contention capacity=16 producers=4 total=40000 elapsed_ms=21.135 minor_words=14680016 promoted_words=125713 major_words=125713 sent=40000 received=40000 depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
v1 broadcast_stress capacity=1 producers=16 total=80000 elapsed_ms=256.138 minor_words=131595912 promoted_words=7895864 major_words=7857443 sent=80000 received=80000 depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
v2 broadcast_stress capacity=1 producers=16 total=80000 elapsed_ms=56.139 minor_words=38797180 promoted_words=1407801 major_words=1407801 sent=80000 received=80000 depth=0 waiting_senders=0 waiting_receivers=0 cancelled_senders=0
~~~

Verdict: replace the implementation. The ordinary contention workload is a
small but consistent v2 win; the capacity-1 producer stress case is the
decisive evidence because it targets broadcast amplification directly.

Residual cost: the capacity-16 contention probe still reports about 367 minor
words per delivered item pair. This is mostly waiter/promise/fiber overhead in
the blocking path, not a zero-allocation routing claim. H-D1 should remeasure
per-frame allocation at realistic HTTP/2 capacities (16-64, hundreds of streams)
before claiming a low-allocation frame-routing path.
