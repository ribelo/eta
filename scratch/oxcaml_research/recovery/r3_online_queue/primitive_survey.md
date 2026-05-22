# R3 Primitive Survey

Stage A checked the local OxCaml/Nix environment for an existing portable
linearizable bounded FIFO queue before choosing an Effet-owned queue.

Observed packages:

- portable exposes Atomic and Atomic_array, but no queue.
- portable_ws_deque exposes a work-stealing deque. Its own interface says
  push/pop are owner functions and steal is the contended operation, so it is
  not a many-producer online transport queue.
- await.sync.stack is a portable MPMC blocking stack, but it is LIFO,
  unbounded, and has no close semantics.
- await.sync.mvar is a portable single-slot handoff cell. It can model
  capacity one, but not a bounded FIFO queue without a surrounding queue
  protocol.
- await.sync.semaphore and await.sync.awaitable can support blocking and
  wakeups, but they are synchronization building blocks rather than a queue.
- concurrent/parallel provide schedulers and structured concurrency, not a
  Phase 8 data transport.

Conclusion: no existing package in the pinned environment provides the exact
Phase 8 primitive: online MPSC FIFO, bounded capacity, close, and backpressure.
Stage A promoted an Effet-owned MPSC bounded queue as Effet.Portable_queue,
using Portable.Atomic and Portable.Atomic_array. Stage B may add Await.Sync or
Eio wakeups around the same contract if blocking transport needs them.
