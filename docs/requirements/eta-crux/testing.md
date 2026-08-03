---
kind: requirement
tags: [eta_crux, testing, teststore, runnertester]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/commands-and-effects]]", "[[docs/requirements/eta-crux/tick]]", "[[docs/requirements/eta-crux/errors]]"]
traces_to: []
---
# Testing contract

## Intent

Eta Crux provides a synchronous transition harness and a real-driver harness.
The synchronous harness applies actions without running command work. It
exposes model changes and opaque pending-command handles for assertion. The
real-driver harness runs command work, subscriptions, timers, dynamic structure,
and crash handling under explicit test control.

Pending-command handles identify scheduled commands before their command work
runs. They are identified by owning cell, emission order, and slot when a slot
is present. Tests resolve handles by providing result actions. The synchronous
harness does not run the command work.

Exhaustive assertions are scoped to observed cells because a graph has dynamic
structure. A test can require every observed model change and pending-command
change to be asserted, or can opt out of exhaustivity.

## Requirements

- When application code is tested, eta_crux shall provide a synchronous transition
  harness and a real-driver harness. ^test-4k2m
- When a test dispatches an action to a cell in the synchronous harness, eta_crux
  shall apply the transition without running a real driver. ^test-7d9w
- When a transition emits scheduled commands under the synchronous harness,
  eta_crux shall expose an opaque pending-command handle for each scheduled
  command. ^test-h5w3
- When eta_crux creates a pending-command handle, eta_crux shall
  identify the handle by owning cell, emission order, and slot when a
  slot is present. ^test-r8k2
- When a test resolves a pending-command handle with an action,
  eta_crux shall feed that action through dispatch without running
  the command work. ^test-3h6t
- When tests assert pending-command handles, eta_crux shall support assertions for
  pending-command presence, absence, cancellation, and resolution without
  exposing names or argument payloads for scheduled commands. ^test-s7p2
- When a branch is disposed or a command slot is replaced in a test, eta_crux
  shall let the test assert that the affected pending-command handles were
  cancelled. ^test-b5r8
- While exhaustive mode is enabled, eta_crux shall require every model
  change and pending-command change among the test's observed cells
  to be asserted. ^test-9x1n
- While non-exhaustive mode is enabled, eta_crux shall allow unasserted
  model changes and pending-command changes among the test's observed
  cells. ^test-m4d6
- If a defect occurs under test, then eta_crux shall let the test assert the
  crash boundary fired with the expected cause and context. ^test-c2v7
- When a real-driver test advances ready work or test time, eta_crux shall run
  command work, subscriptions, timers, dynamic structure, and lifecycle work
  through the driver semantics. ^test-e8k3
- When a real-driver test observes output, eta_crux shall expose stabilized
  fragments and batched output changes for assertion. ^test-a7n4
- When an adapter is tested, eta_crux shall let the adapter be tested against a
  recording fake of the toolkit surface. ^test-6m4q
- When tests supply results for scheduled commands, eta_crux shall require no
  mocking library and shall accept result actions through pending-command
  handles. ^test-n1w9
- eta_crux shall publish its test harnesses in an `eta_crux_test` package
  separate from the core `eta_crux` package. ^test-p4k8

## Open questions

- Exact API for selecting the observed cell set used by exhaustive assertions.
- Whether the synchronous harness can stabilize the graph for fragment
  assertions, or whether fragment assertions belong only to the real-driver
  harness.
