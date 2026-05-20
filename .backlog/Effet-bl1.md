---
id: Effet-bl1
title: "Research: thin Effect-shaped wrappers for Queue / Deferred / PubSub / Latch"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:44:14.794Z
created_by: backlog
updated_at: 2026-05-19T18:48:09.962Z
dependencies:
  - issue_id: Effet-bl1
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:48:09.962Z
    created_by: backlog
---

# Research: thin Effect-shaped wrappers for Queue / Deferred / PubSub / Latch

## description

Review 1 omission #5. The journal earlier said 'use Eio.Queue / Eio.Stream / Eio.Promise / Eio.Semaphore directly'. Apps that want typed errors, env requirements, tracing, and cancellation propagation through these primitives must wrap them by hand at every call site.

Hypothesis to lab: a thin Effect-shaped wrapper layer for the most-used Eio concurrency primitives:
- Effect.Queue: bounded async queue with backpressure
- Effect.Deferred: one-shot signal (over Eio.Promise)
- Effect.PubSub: fan-out (broadcast queue)
- Effect.Latch: countdown for 'wait until N events happen'

Each wrapper integrates: typed-error channel for closed/failed states, env requirements via row, tracing via active-span, cancellation via Eio.Cancel.

Decision question: do these wrappers earn their place by reducing per-call-site boilerplate, or do apps reach for Eio directly anyway? If apps prefer Eio's surface, the wrappers are unearned.

## design

scratch/concurrent_data_research/ with a fixture-driven lab.

Build minimal wrappers (~50 LOC each) for Queue and Deferred. Write three real-app fixtures using each:
1. Queue: producer/consumer with bounded size, backpressure, graceful shutdown.
2. Deferred: a service that waits for first-config-load before processing requests; multiple readers race for the same config.
3. PubSub (if Queue/Deferred prove valuable): event broadcast to N subscribers with slow-consumer drop policy.

For each fixture, write the version using the Effect-shaped wrapper and the version using Eio directly. Compare:
- LOC and readability
- whether typed errors flow naturally vs requiring boilerplate to wrap Eio exceptions
- whether tracing automatically picks up queue operations as spans
- whether cancellation semantics behave the same

If wrappers consistently reduce 5+ LOC per use site and improve typed-error/tracing integration, they earn a place. Otherwise close as 'use Eio directly'.

## acceptance criteria

scratch/concurrent_data_research/ contains Queue and Deferred wrappers and three pairs of fixtures. journal.md gains a V-CDv1..V-CDvN decision diary. Recommendation: (a) skip wrappers — document Eio primitives directly in README; (b) ship Effect.Queue / Effect.Deferred as a small effet-extra module — capture as implementation task; (c) ship a wider primitives package (effet-concurrent) — capture as research-then-implement epic. 2h time budget.
