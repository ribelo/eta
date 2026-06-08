# P0-T6 Portable Queue Probe

Status: final for Effet-OxCaml-5uz.

Question: should Phase 6 / Phase 8 use an installed OxCaml portable queue primitive, or should Effet own a small portable queue wrapper?

## Artifacts

- ws_deque_steal_positive.ml: installed Portable_ws_deque cross-domain steal smoke.
- ws_deque_push_capture_negative.ml: owner-local push cannot be captured into a shareable parallel closure.
- ws_deque_payload_negative.ml: nonportable closure payload is rejected when the deque payload must be portable.
- atomic_queue_parallel_positive.ml: small Effet-owned Portable.Atomic list wrapper with two parallel producers and parent drain.
- atomic_queue_payload_ref_negative.ml: mutable ref payload rejection for the wrapper.
- atomic_queue_payload_closure_negative.ml: closure-with-ref payload rejection for the wrapper.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/portable_queue_probe/run.sh

Last result:

    summary: pass=6 fail=0

## Evidence

The installed primitive exists: ocamlfind exposes package module path `portable_ws_deque` / module `Portable_ws_deque`. Its interface declares `@@ portable` and `type 'a t : mutable_data with 'a @@ contended portable`.

Candidate A passes for work stealing. A deque created with portable integer payloads can be stolen from two Parallel workers, and the runtime smoke consumes each item exactly once.

Candidate A is not a general producer-consumer queue. Capturing the deque into a parallel closure and calling `Portable_ws_deque.push` is rejected because the queue is shared where `push` expects uncontended owner-local access.

Candidate A rejects nonportable payload capture. A payload closure reading `int ref` fails while constructing the portable list passed to `Portable_ws_deque.of_list`.

Candidate B passes as a minimal general producer handoff. The wrapper is one `Portable.Atomic.t` containing an immutable list; two Parallel workers push 500 integers total, then the parent drains and verifies count and sum.

Candidate B rejects both tested nonportable payload classes. `int ref` fails the wrapper's `immutable_data` bound, and closure-with-ref capture fails as nonportable at the parallel boundary.

## Comparison

| Criterion | Portable_ws_deque | Effet Portable_queue over Portable.Atomic |
| --- | --- | --- |
| Existing shipped primitive | Yes, `Portable_ws_deque` | No, small Effet-owned wrapper |
| Cross-domain consumer | Yes, `steal_opt` accepts contended queue | Yes, producers mutate one portable atomic |
| Cross-domain producer | Owner-local only; push rejects shared capture | Yes, positive stress fixture |
| Ordering/fairness | Work-stealing LIFO/FIFO mix, no fairness guarantee | Snapshot bag/stack unless Effet adds a protocol |
| Static payload rejection | Yes for nonportable closures | Yes for refs and nonportable closures |
| Phase 6 fit | Good for per-domain work stealing | Useful for aggregation, less scheduler-shaped |
| Phase 8 fit | Poor for arbitrary exporters/producers | Good as thin internal handoff primitive, wake/backpressure still separate |

## Decision diary

- V-P0T6-1 - Use `Portable_ws_deque` for Phase 6 work stealing.
  Decision: Phase 6 domain-parallel runtime should use the installed `Portable_ws_deque` primitive for scheduler/work queues.
  Rationale: it is shipped, explicitly portable, and the positive fixture proves concurrent cross-domain stealing with portable payloads.

- V-P0T6-2 - Do not use `Portable_ws_deque` as the general Phase 8 producer queue.
  Decision: Phase 8 stream / OTel exporter handoff should use a small Effet-owned wrapper over `Portable.Atomic.t` for arbitrary parallel producers.
  Rationale: `Portable_ws_deque.push` is owner-local and rejects shared capture. That is correct for work stealing but not for multi-producer stream/exporter handoff.

- V-P0T6-3 - Keep the wrapper minimal.
  Decision: the Phase 8 wrapper starts as `Portable.Atomic.t` over immutable payload lists, with wake/backpressure handled by the surrounding Eio-local wrapper task.
  Rationale: the positive stress fixture proves portable multi-producer handoff. The current evidence does not justify a larger public queue API, fairness policy, or blocking protocol.

## Deferred

- P0-T2 still decides how Eio-local wakeups and cancellation wrap portable handoff state.
- Phase 8 should add focused tests for exporter batching semantics once the real wrapper is promoted from scratch.
- If Phase 8 requires fairness or bounded backpressure, add a new probe before extending the wrapper.

