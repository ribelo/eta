---
id: Effet-runtime-owned-lifecycle
title: "Research: runtime-owned daemon / subscription / resource lifecycle surface"
status: open
priority: 2
issue_type: task
created_at: 2026-05-20T00:00:00.000Z
created_by: codex
dependencies:
  - issue_id: Effet-runtime-owned-lifecycle
    depends_on_id: Effet-0jv
    type: parent-child
    created_by: codex
  - issue_id: Effet-runtime-owned-lifecycle
    depends_on_id: Effet-j40
    type: related
    created_by: codex
  - issue_id: Effet-runtime-owned-lifecycle
    depends_on_id: Effet-6yf
    type: related
    created_by: codex
---

# Research: runtime-owned daemon / subscription / resource lifecycle surface

## description

The Resource survival lab did **not** reopen public `Effect.detach`. It added
new evidence for a different category: values returned from an effect that own
long-lived background work after the constructor effect has completed.

Current state:

- Public fire-and-forget `Effect.detach` was removed by the detach survival work.
- Public child lifecycles go through `Supervisor.scoped`, `par`, `all`,
  `all_settled`, `race`, and bounded traversal.
- Runtime-owned background work exists only as `Effect.Private.daemon`.
- `Resource.auto` uses that private daemon and exposes typed refresh failures
  through `Resource.failures`.
- The Effet-6yf Resource lab showed that replacing `Resource.auto` with an
  ordinary `Atomic.t` recipe only works by calling `Effect.Private.daemon`
  or by dropping into raw Eio fibers/switches outside the public Effect surface.

This task asks whether Effet needs a **general public abstraction for
runtime-owned returned resources**. It must not start from "bring back detach."
A naked public `detach` remains the negative control: unowned fire-and-forget
with no structured failure sink is the shape previous research rejected.

The design pressure is future abstractions that may share `Resource.auto`'s
lifecycle pattern:

- stream subscriptions or hot streams;
- file watchers / config reloaders;
- connection pools with background health checks;
- periodic metrics/exporter daemons;
- cache warmers or refresh loops;
- runtime-owned handles that must expose failure history and explicit close.

If those call sites converge on the same lifecycle protocol, Effet should expose
that protocol directly. If they do not, keep `Effect.Private.daemon` private and
ship narrow modules such as `Resource`.

## design

Lab-first per V-R10. Build `scratch/runtime_lifecycle_research/` with concrete
candidate shapes and identical fixtures.

### Hypotheses

- **D0 — Status quo.** Keep `Effect.Private.daemon` private. Public modules
  such as `Resource` own their own daemon protocol. Apps use ordinary Eio or
  module-specific APIs.
- **D1 — Public Runtime_resource.** A public handle type owns a daemon loop,
  exposes `get` / `close` / `failures`, and is bounded by the runtime switch.
  Resource becomes one specialization.
- **D2 — Public Subscription.** A stream/watch-style abstraction owns a daemon
  that pushes updates to a bounded queue, exposes pull/close/failures, and can
  model config reloaders and hot streams.
- **D3 — Supervisor-owned service handle.** Extend `Supervisor.scoped` or add a
  related nursery builder for handles that can outlive the constructor body but
  still have explicit ownership and close semantics.
- **D4 — Public detach resurrected.** Negative control. Reintroduce public
  fire-and-forget and test whether the previous failure modes are actually solved.
  Expected result: reject unless it gains ownership, close, and failure history,
  at which point it is no longer detach.
- **D5 — Raw Eio recipe.** Apps create their own `Eio.Switch`, fibers, queues,
  and failure cells outside Effet. Compare clarity and failure behavior against
  library-owned shapes.

### Required fixtures

Each surviving candidate must express at least three of these without private API
access:

1. **Resource.auto equivalent**
   - seed initial value;
   - refresh on schedule;
   - failed refresh keeps last-good;
   - typed failure history is observable;
   - close cancels refresh and runs finalizers.

2. **Subscription / watcher**
   - background producer emits updates to a bounded queue;
   - consumer can pull updates through `Effect.t`;
   - producer failure is observable without crashing the parent;
   - close stops producer and unblocks waiting consumers.

3. **Periodic metrics/exporter daemon**
   - periodically flushes buffered values;
   - collector failure records a diagnostic;
   - retry/backoff policy can be represented or explicitly rejected;
   - shutdown drains or drops according to documented policy.

4. **Connection-pool health loop**
   - handle exposes current health;
   - background checks update health;
   - failures do not poison the last known state unless policy says so;
   - close releases all owned resources exactly once.

### Negative fixtures

Write negative tests where the candidate claims type-system enforcement:

- returned child handle cannot escape without an owner;
- closed handle cannot be used if the design claims static close safety;
- public API cannot start unowned fire-and-forget work;
- typed failure channel is not erased silently;
- runtime-owned daemons cannot be constructed by application code through
  `Effect.Private`.

If a property cannot be negative-tested, mark it as runtime/documentation-only.

### Measurements

Compare candidates on:

- public API surface area;
- need for private APIs;
- failure observability and typed error preservation;
- cancellation and finalizer behavior;
- backpressure / bounded queue story;
- lifecycle clarity at call sites;
- runtime resource cost: fibers, queues, atomics, switches per handle;
- whether the abstraction generalizes beyond `Resource.auto` without becoming
  a generic application framework.

## acceptance criteria

- `scratch/runtime_lifecycle_research/` contains at least D0, D1, D2, and D4
  as compiling candidates, plus D5 if the raw Eio recipe is small enough to be
  honest.
- The lab runs the Resource.auto-equivalent fixture for every candidate.
- At least two non-Resource fixtures are tested, preferably subscription/watcher
  and periodic exporter.
- Negative tests are present for every claimed static guarantee, or the journal
  explicitly states that the guarantee is runtime-only.
- `journal.md` gains a V-RL decision diary covering:
  - whether the new evidence changes the detach decision;
  - whether `Effect.Private.daemon` should remain private;
  - whether a general runtime-owned resource/subscription surface earns its
    place;
  - what happens to `Resource.auto`;
  - what is deliberately deferred.
- Recommendation is one of:
  - **keep status quo**: no general public surface; keep `Resource` as the
    only public runtime-owned cached-loader;
  - **add a public runtime-owned resource/subscription abstraction** and capture
    implementation tasks;
  - **move specific modules only**: add narrow `Subscription`, `Watcher`, or
    exporter hardening without a general daemon API;
  - **reopen detach** only if the lab proves a public shape with ownership,
    failure history, and cancellation that is not just the rejected fire-and-
    forget primitive under a new name.

## non-goals

- Do not restore public `Effect.detach` as a starting assumption.
- Do not expose raw `Fiber.t`.
- Do not turn Effet into an application framework or service container.
- Do not change live `packages/` code until the lab produces a recommendation.
- Do not use churn or migration cost as an argument. Pick the shape that is
  correct before the API hardens.

## notes

This task exists because Effet-6yf increased confidence in two facts at once:

1. public `detach` is still the wrong abstraction;
2. runtime-owned long-lived work is real and may need a better public shape if
   more call sites converge on the same lifecycle protocol.

The question is therefore not "detach or no detach." The question is whether
Effet needs a first-class lifecycle abstraction for runtime-owned returned
resources, or whether narrow modules plus private daemon support remain the
optimal design.

