---
kind: requirement
status: draft
tags: [eta_crux, lifecycle, runtime, startup, shutdown, driver]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/tick]]", "[[docs/requirements/eta-crux/errors]]"]
traces_to: []
---
# Lifecycle and driver integration

## Intent

An Eta Crux application instance has an internal graph, a root computation,
action admission, output observation, command/subscription ownership, and a
shutdown path. Hosts integrate the instance through explicit driver operations:
submit actions, advance ready work, observe outputs, advance test time, and
request shutdown.

Construction and activation are distinct. Construction creates the internal graph
engine, builds the root computation, constructs cells, and installs each cell's
initial model. Activation is lifecycle work performed during a tick after graph
stabilization determines which scopes are live. Activation acquires managed
resources and stages init commands for the current tick's command-spawn phase.

The first driver advancement stabilizes the initialized graph and exposes the
first observable output before any init-command result action can be processed.

Eta Runtime hosts an Eta Crux driver as an Eta effect. A foreign UI runtime
hosts a driver through adapter operations and cross-domain action admission.
Both integration styles use the same tick semantics.

Shutdown is ordered. Eta Crux closes action admission, disposes the root scope,
interrupts in-flight command and subscription work, releases managed resources,
stops observers, and returns from the hosted driver. Crash teardown uses the same
shutdown path after the crash report is captured.

## Requirements

- **life-h6m2** (event-driven): When an Eta Crux application instance is
  created, eta_crux shall return a handle representing that live application
  instance.
- **life-r9k4** (event-driven): When eta_crux creates an application instance,
  eta_crux shall create the internal graph engine, build the root computation,
  construct cells, install each constructed cell's initial model, and make
  dispatch and output observation available through the application handle.
- **driver-r5c1** (ubiquitous): When a host integrates Eta Crux, eta_crux shall
  expose explicit driver operations for submitting actions, advancing ready
  work, observing outputs, advancing test time, and requesting shutdown.
- **driver-c2k7** (event-driven): When a driver advances Eta Crux, eta_crux
  shall process ready actions, due timers, lifecycle work, subscriptions, and
  commands according to the tick ordering requirements.
- **driver-m8p5** (event-driven): When an Eta effect hosts an Eta Crux driver,
  the driver shall use Eta Runtime scheduling, interruption, and resource-scope
  semantics.
- **driver-h4n8** (event-driven): When a foreign runtime hosts an Eta Crux
  driver, the driver shall preserve Eta Crux action admission, wake, shutdown,
  and owner-domain semantics.
- **cell-2b6x** (event-driven): When a cell is constructed, eta_crux shall store
  the cell's initial model before the cell can process any action.
- **life-8w2n** (event-driven): When a cell scope is newly live during a tick,
  eta_crux shall activate that scope during the lifecycle phase of the tick.
- **life-a7q4** (event-driven): When eta_crux activates a cell scope, eta_crux
  shall acquire the scope's managed resources and add the scope's init commands
  to the current tick's pending command list.
- **life-f3k8** (event-driven): When eta_crux performs the first driver
  advancement for an application instance, eta_crux shall expose the first
  output from initialized cell models before processing any result action from an
  init command.
- **life-c1m6** (event-driven): When an Eta effect hosts an Eta Crux driver,
  eta_crux shall bracket the hosted driver so teardown runs on normal stop,
  interruption, and defect.
- **life-m8p3** (event-driven): When shutdown is requested on an application
  handle, eta_crux shall begin the ordered shutdown path.
- **life-6h8t** (event-driven): When eta_crux runs the shutdown path, eta_crux
  shall close action admission, dispose the root scope bottom-up, interrupt
  in-flight commands and subscriptions, release managed resources, and stop
  observers.
- **life-9k3w** (event-driven): When eta_crux stops an application instance,
  eta_crux shall drop queued actions that have not started processing.
- **life-e5v2** (event-driven): When a fatal defect stops an application
  instance, eta_crux shall use the same ordered shutdown path as normal stop
  after capturing the crash report.

## Open questions

- Exact public shape of the application handle and driver operations.
- Whether Eta Crux offers an explicit drain-before-stop operation distinct from
  ordinary shutdown.
