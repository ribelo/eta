---
kind: requirement
status: draft
tags: [eta_crux, concurrency, driver, eio, domains]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/fragments]]", "[[docs/requirements/eta-crux/dispatch]]"]
traces_to: []
---
# Concurrency and driver wake behavior

## Intent

Eta Crux has one owner domain for an application instance. The owner domain owns
the computation graph, cell model storage, action processing, command fibers,
subscriptions, timers, stabilization, lifecycle, and shutdown. Other domains
interact with the application instance only through action admission and output
delivery mechanisms.

A foreign UI runtime can own the main thread. In that integration, UI events are
admitted from a non-owner domain through the adapter, and outputs return to the
UI runtime as immutable adapter payloads.

The owner-domain driver does not poll while no work is ready. New admitted
actions, due timers, and shutdown requests make the owner-domain driver eligible
to advance.

Dispatch across a domain boundary is asynchronous. A caller on a foreign domain
cannot dispatch an action and synchronously read the resulting output from the
same call path.

## Requirements

- **conc-2h7n** (ubiquitous): When eta_crux creates an application instance,
  eta_crux shall assign that instance one owner domain for graph mutation,
  action processing, command fibers, subscriptions, timers, stabilization,
  lifecycle, and shutdown.
- **conc-b8w3** (state-driven): While a non-owner domain integrates with an Eta
  Crux application instance, eta_crux shall require inbound actions to enter
  through the action admission path rather than through direct access to cell
  model storage.
- **conc-p6w3** (event-driven): When eta_crux admits an action from a non-owner
  domain into the inbound queue, eta_crux shall make the owner-domain driver
  eligible to advance.
- **conc-t8m4** (state-driven): While a foreign-runtime driver is running and no
  queued action or due timer exists, eta_crux shall keep the owner-domain driver
  idle without polling.
- **conc-k9r2** (event-driven): When a timer deadline becomes due, eta_crux
  shall make the owner-domain driver eligible to advance.
- **conc-v4h7** (event-driven): When the owner-domain driver advances, eta_crux
  shall process the pending action burst and due timers through the normal tick
  order.
- **conc-h2s5** (event-driven): When shutdown is requested while the
  owner-domain driver is idle, eta_crux shall wake the owner-domain driver so
  shutdown can complete.
- **conc-6m4q** (event-driven): When eta_crux delivers outputs to a foreign UI
  runtime, eta_crux shall deliver immutable adapter payloads.
- **conc-w2k7** (state-driven): While an adapter dispatches from a non-owner
  domain, eta_crux shall not provide a synchronous dispatch-then-read-output
  operation for that adapter call path.

## Open questions

- Whether Eta Crux exposes a same-domain `drain` operation for immediate-mode
  OCaml UIs, and which driver operation name it uses.
- Whether more than one owner domain is ever allowed for one application
  instance.
