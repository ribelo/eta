# R3 Phase 8 Online Queue Results

Question: what queue primitive should Phase 8 use for live cross-domain
producer/consumer transport?

## Caller Shape

| Caller | Shape | Queue requirement |
| --- | --- | --- |
| merge | many sources to one coordinator consumer | MPSC |
| flat_map_par | many workers publish mapped outputs to one downstream consumer | MPSC on the output side |
| OTel exporter handoff | many instrumentation producers to one exporter actor | MPSC |

MPSC is sufficient for the known Phase 8 callers. MPMC is not justified by the
current evidence.

## Primitive Survey

See primitive_survey.md. The local OxCaml environment has good building blocks
but no exact online bounded FIFO with push, take, close, and backpressure:
portable_ws_deque is owner-local for push/pop, Await.Sync.Stack is LIFO and
unbounded, Mvar is a single-slot cell, and Awaitable/Semaphore are wakeup
building blocks rather than a queue.

## Evidence

The accepted primitive is Effet.Portable_queue, an Effet-owned bounded MPSC FIFO
over Portable.Atomic and Portable.Atomic_array.

mpsc_queue_positive exercised the shipped module across Parallel_scheduler with
three producers, one consumer, capacity 32, total=1500, sum=300374250,
close_rejects_push=true, and fifo_single_consumer=true.

h3_batch_inbox_online_negative proved the H3 batch inbox does not satisfy the
same contract: online_push_take=false, drain_requires_close=true, and
push_after_close_rejected=true.

## Verdict

Phase 8 must use an online bounded MPSC queue. The H3 close-before-drain inbox
remains batch-only and must not be reused for streams/exporter handoff.

Effet.Portable_queue is the Stage A queue contract. Stage B S10 may add blocking
wakeups around it with Eio or Await.Sync, but it must preserve the same
push/take/close/backpressure semantics.

## Commands

nix develop -c bash scratch/oxcaml_research/recovery/r3_online_queue/run.sh

Result: summary pass=2 fail=0.

