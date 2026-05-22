# Concurrency Model Rejections

Status: final for Effet-OxCaml-rp2 T1.

Question: which concurrency models are already ruled out by existing OxCaml
evidence?

## H1 - Shared-substrate work stealing

Model definition: one shared runtime substrate owns all runnable work; worker
domains push and steal work from shared queues in the ZIO/Tokio shape.

Rejection criterion: reject H1 if either the IO substrate cannot be shared
across domains, or the candidate work-stealing queue cannot accept shared
cross-domain producers.

Evidence:

- V-P0T2 says Eio remains same-domain and lexical. Raw Eio switches, promises,
  streams, and fibers are not made portable. Parallel is the domain boundary;
  Eio remains the local IO substrate inside a domain.
- V-P0T6 says Portable_ws_deque can be stolen from across domains, but
  Portable_ws_deque.push is owner-local. Capturing a shared deque in a Parallel
  closure and pushing fails at compile time.

Decision: H1 is rejected. Effet cannot honestly claim a single shared
ZIO/Tokio-style runtime substrate on top of current Eio and
Portable_ws_deque.

Revisit only if upstream Eio exposes mode-aware portable runtime handles and a
portable work queue supports safe shared multi-producer push.

## H6 - Actor model

Model definition: concurrency is expressed as actors/mailboxes with receiver
identity, message queues, and mailbox-driven supervision.

Rejection criterion: reject H6 if Effet's existing supervisor evidence keeps a
lexical nursery shape rather than a mailbox-receiver shape.

Evidence:

- V-P3-Partial keeps rank-2 supervisor_body and confirms that child handles
  remain scope-bound.
- The shipped Supervisor API is a lexical nursery: children are started,
  awaited, cancelled, and checked inside Supervisor.scoped. It does not expose
  actor identity, mailbox receive loops, or message protocols.

Decision: H6 is rejected. Building actors would replace Effet's supervisor
model instead of refining the OxCaml runtime beneath it.

Revisit only if Effet deliberately changes from lexical structured
concurrency to actor/mailbox ownership.

## Reduced Hypothesis Space

The remaining candidates for Effet-OxCaml-rp2 are:

- H7 single-domain only.
- H2 per-domain work stealing.
- H3 per-domain explicit push.
- H4 per-domain hybrid, only if H3 shows a load-balance pathology.
- H5 centralized orchestrator plus pure fan-out, only if H3 shows
  failure/observability ordering pathology.

