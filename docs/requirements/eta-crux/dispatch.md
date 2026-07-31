---
kind: requirement
tags: [eta_crux, dispatch, backpressure, portable_queue, cross-domain]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/adapter]]", "[[docs/requirements/eta-crux/lifecycle]]", "[[docs/requirements/eta-crux/concurrency]]"]
traces_to: []
---
# Dispatch semantics

## Intent

Dispatch admits actions into Eta Crux. Calling a cell's inject function never
applies the action inline. It enqueues an action addressed to the cell that
created the inject function, and a later driver advancement processes the action.

Eta Crux routes all inbound actions through a bounded action queue. Admission
from a non-owner domain is non-blocking and reports failure to the adapter when
the queue cannot accept the action. Admission from owner-domain work suspends the
producer fiber when the queue is full, and resumes it when capacity is available
or the producing scope is interrupted.

Action ordering is per target cell. Eta Crux preserves first-in-first-out order
for actions addressed to the same cell. Eta Crux does not define ordering between
actions addressed to different cells.

An action whose target cell has already been disposed does not run a transition;
the disposed-cell processing rule is defined in
[[docs/requirements/eta-crux/core-loop]].

## Requirements

- When application code calls a cell inject function with an action, eta_crux
  shall enqueue that action addressed to the cell that created the inject
  function. ^dispatch-9c3r
- When eta_crux accepts an action, eta_crux shall process the action during a
  later driver advancement rather than inline in the caller. ^dispatch-8w2n
- eta_crux shall route all inbound actions through a bounded application action
  queue. ^dispatch-q8m2
- When non-owner-domain action admission finds the bounded action queue full or
  closed, eta_crux shall report admission failure to the adapter. ^dispatch-c1v9
- When owner-domain work emits an action while the bounded action queue is full,
  eta_crux shall suspend the producer until queue capacity is available or the
  producer's scope is interrupted. ^dispatch-a6p4
- When eta_crux processes queued actions for one target cell, eta_crux shall
  preserve that cell's first-in-first-out action order. ^dispatch-e5v2
- When eta_crux processes queued actions for different target cells, eta_crux
  shall make no cross-target ordering guarantee. ^dispatch-n4k7
- If action admission occurs after shutdown has closed admission, then eta_crux
  shall reject the action without processing it. ^dispatch-m6p8

## Open questions

- Exact adapter-facing admission-failure type.
- Whether default adapter policies such as coalescing high-frequency pointer
  input belong in eta_crux adapters or in application code.
