---
kind: requirement
status: draft
tags: [eta_crux, testing, teststore, runnertester]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/commands-and-effects]]", "[[docs/requirements/eta-crux/tick]]", "[[docs/requirements/eta-crux/errors]]"]
traces_to: []
---
# Testing contract

## Intent

Eta Crux provides a synchronous transition harness and a real-driver harness.
The synchronous harness applies actions without running command effects. It
exposes model changes and opaque pending-command handles for assertion. The
real-driver harness runs commands, subscriptions, timers, dynamic structure, and
crash handling under explicit test control.

Pending-command handles identify scheduled commands before their effects run.
They are identified by owning cell, emission order, and slot when a slot is
present. Tests resolve handles by providing result actions; the effect is not
executed by the synchronous harness.

Exhaustive assertions are scoped to observed cells because a graph has dynamic
structure. A test can require every observed model change and pending-command
change to be asserted, or can opt out of exhaustivity.

## Requirements

- **test-4k2m** (ubiquitous): When application code is tested, eta_crux shall
  provide a synchronous transition harness and a real-driver harness.
- **test-7d9w** (event-driven): When a test dispatches an action to a cell in
  the synchronous harness, eta_crux shall apply the transition without running a
  real driver.
- **test-h5w3** (event-driven): When a transition emits commands under the
  synchronous harness, eta_crux shall expose opaque pending-command handles for
  those commands.
- **test-r8k2** (event-driven): When eta_crux creates a pending-command handle,
  eta_crux shall identify the handle by owning cell, emission order, and slot
  when a slot is present.
- **test-3h6t** (event-driven): When a test resolves a pending-command handle
  with an action, eta_crux shall feed that action through dispatch without
  running the command effect.
- **test-s7p2** (ubiquitous): When tests assert pending commands, eta_crux shall
  support assertions for pending-command presence, absence, cancellation, and
  resolution without exposing framework command names or argument payloads.
- **test-b5r8** (event-driven): When a branch is disposed or a command slot is
  replaced in a test, eta_crux shall let the test assert that the affected
  pending-command handles were cancelled.
- **test-9x1n** (state-driven): While exhaustive mode is enabled, eta_crux shall
  require every model change and pending-command change among the test's
  observed cells to be asserted.
- **test-m4d6** (state-driven): While non-exhaustive mode is enabled, eta_crux
  shall allow unasserted model changes and pending-command changes among the
  test's observed cells.
- **test-c2v7** (event-driven): When a defect occurs under test, eta_crux shall
  let the test assert the crash boundary fired with the expected cause and
  context.
- **test-e8k3** (event-driven): When a real-driver test advances ready work or
  test time, eta_crux shall run real commands, subscriptions, timers, dynamic
  structure, and lifecycle work through the driver semantics.
- **test-a7n4** (event-driven): When a real-driver test observes output,
  eta_crux shall expose stabilized fragments and batched output changes for
  assertion.
- **test-6m4q** (ubiquitous): When an adapter is tested, eta_crux shall let the
  adapter be tested against a recording fake of the toolkit surface.
- **test-n1w9** (ubiquitous): When tests supply command results, eta_crux shall
  require no mocking library; tests shall provide result actions through
  pending-command handles.
- **test-p4k8** (ubiquitous): When eta_crux ships test harnesses, eta_crux shall
  publish them in an `eta_crux_test` package separate from the core `eta_crux`
  package.

## Open questions

- Exact API for selecting the observed cell set used by exhaustive assertions.
- Whether the synchronous harness can stabilize the graph for fragment
  assertions, or whether fragment assertions belong only to the real-driver
  harness.
