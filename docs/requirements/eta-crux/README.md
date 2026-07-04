---
kind: requirement
status: draft
tags: [eta_crux, architecture, overview]
refines: []
depends_on: []
traces_to: []
---
# eta_crux

## Intent

`eta_crux` is an optional Eta package for graph-native, driver-integrated
application state machines.

An Eta Crux application is a root computation built from state-machine cells.
Each cell owns local model storage, a local action type, a transition function,
a lifecycle scope, a result value, and an inject function. Application structure
is computed by the graph: a single-state-machine application is one root cell,
and a composed application is a graph of cells under the root computation.

Eta Crux uses Eta effects for command work, Eta streams for subscriptions, and
Eta Runtime semantics when hosted as an Eta effect. UI adapters and output
fragments are optional. A headless application still runs actions, transitions,
commands, subscriptions, lifecycle, and shutdown through the same computation
model.

Hosts integrate with an Eta Crux application instance through explicit driver
operations: submit actions, advance ready work, observe outputs, advance test
time, and request shutdown. Foreign runtimes integrate through adapters that
admit inbound actions, observe outbound fragments, and forward outbound
capability messages.

Eta Crux is not part of the root `eta` package. Eta core owns effect description
and interpretation. Eta Crux owns application state for applications that choose
to depend on it.

## Requirements

- **pkg-a1c7** (ubiquitous): When Eta Crux is published, it shall be published as
  an optional `eta_crux` package with public library `Eta_crux`.
- **pkg-9f3d** (ubiquitous): When the root `eta` package is built, it shall not
  depend on `eta_crux`.
- **pkg-4k8e** (ubiquitous): When an application depends on `eta_crux`,
  eta_crux shall own that application's computation graph and cell state.
- **arch-2m6p** (ubiquitous): When an Eta Crux application is created without a
  UI adapter, eta_crux shall still provide action processing, command execution,
  subscription execution, lifecycle handling, and shutdown.
- **arch-g9m4** (ubiquitous): When application code defines an Eta Crux
  application, eta_crux shall require the application to be a root computation.
- **arch-r7p2** (ubiquitous): When a host integrates with an Eta Crux
  application instance, eta_crux shall expose explicit driver operations rather
  than requiring direct host access to cell model storage.

## Requirement Notes

- [[docs/requirements/eta-crux/concepts]] — vocabulary and mental model.
- [[docs/requirements/eta-crux/core-loop]] — root computation and
  state-machine cell contract.
- [[docs/requirements/eta-crux/composition]] — graph composition, dynamic
  structure, and keyed cells.
- [[docs/requirements/eta-crux/tick]] — action processing, stabilization,
  lifecycle order, observation, and command spawning.
- [[docs/requirements/eta-crux/lifecycle]] — application handles, driver
  operations, startup, activation, shutdown, and hosted drivers.
- [[docs/requirements/eta-crux/dispatch]] — action admission, inject functions,
  bounded queues, backpressure, and ordering.
- [[docs/requirements/eta-crux/commands-and-effects]] — scheduled commands,
  force-total command work, slots, cancellation, and diagnostics.
- [[docs/requirements/eta-crux/subscriptions]] — state-derived Eta stream
  sources and reconciliation.
- [[docs/requirements/eta-crux/fragments]] — optional output fragments,
  fragment equality, addressing, pull observation, and push observation.
- [[docs/requirements/eta-crux/boundary-contract]] — adapter boundary payloads:
  inbound actions, outbound fragments, and outbound capability messages.
- [[docs/requirements/eta-crux/shell-capabilities]] — shell-owned work and typed
  outbound capability messages.
- [[docs/requirements/eta-crux/concurrency]] — owner-domain rules and driver
  wake behavior.
- [[docs/requirements/eta-crux/adapter]] — host adapter responsibilities.
- [[docs/requirements/eta-crux/errors]] — typed errors as actions, fatal
  defects, crash reports, and teardown.
- [[docs/requirements/eta-crux/testing]] — synchronous transition harness,
  real-driver harness, command handles, and scoped exhaustivity.
- [[docs/requirements/eta-crux/engine-strategy]] — `eta_signal` and
  `eta_signal_map` engine prerequisites.
