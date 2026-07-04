---
kind: requirement
status: draft
tags: [eta_crux, core, cells, graph]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/boundary-contract]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Cell graph core

## Intent

Eta Crux applications are root computations built from composable
state-machine cells. A cell is a graph-native computation node with local model
storage, a local action type, a transition function, a lifecycle scope, a result
value, and an inject function for its action type. An application with one state
machine is represented as a root computation with one state-machine cell. An
application with many state machines is represented as a root computation that
composes many cells.

Application code defines cells through Eta Crux combinators. Eta Crux owns cell
model storage inside the computation graph; application code receives read-only
computation values and inject functions, not direct mutable access to a cell's
stored model. The engine strategy defines the `eta_signal` substrate; the
state-machine API is an Eta Crux API.

The application-facing API is value- and function-based. An application is
constructed by passing a graph value to a root-construction function; application
dependencies and capability senders are ordinary values captured by that
construction closure. Eta Crux creates the internal graph engine for the
application instance.

State-machine transitions are pure. A transition computes a new model and a
list of scheduled commands. The command work itself runs later through the
command executor.

Cells are either independent of graph input or dependent on another computation
value. Input-dependent cells receive an explicit input status when their
transition runs, so inactive input is handled by application code rather than by
implicit framework behavior.

View fragments and UI adapters are optional outputs. A graph with no UI adapter
still runs actions, transitions, commands, subscriptions, lifecycle, and
shutdown through the root computation.

## Requirements

- **core-g9m2** (ubiquitous): When an Eta Crux application is created, eta_crux
  shall represent it as a root computation.
- **core-v4p7** (ubiquitous): When a computation defines local state, eta_crux
  shall treat it as a state-machine cell with local model storage, local action
  type, transition function, lifecycle scope, result value, and inject function.
- **core-b6x4** (ubiquitous): When an application has one state machine,
  eta_crux shall represent it as a root computation containing one
  state-machine cell.
- **core-m2c9** (ubiquitous): When an application has multiple state machines,
  eta_crux shall compose them as computation cells under the root computation.
- **core-h7q5** (ubiquitous): When an Eta Crux application runs without a UI
  adapter, eta_crux shall still execute actions, transitions, commands,
  subscriptions, lifecycle, and shutdown through the root computation.
- **cell-2p7q** (ubiquitous): When application code defines a state-machine
  cell, eta_crux shall require an initial model value and an action transition
  function for that cell.
- **cell-3n6k** (ubiquitous): When application code defines a state-machine cell
  without input, eta_crux shall require a transition function from current model
  and action to new model plus scheduled commands.
- **cell-5r2v** (ubiquitous): When application code defines a state-machine cell
  with input, eta_crux shall require an input computation value and a transition
  function from input status, current model, and action to new model plus
  scheduled commands.
- **cell-8k4n** (event-driven): When eta_crux constructs a state-machine cell,
  eta_crux shall create model storage owned by that cell inside the computation
  graph.
- **cell-6v1m** (ubiquitous): When application code receives the result of a
  state-machine cell, the result shall contain a read-only computation value for
  the cell's current model and an inject function for the cell's action type.
- **cell-7q9b** (ubiquitous): When application code uses the read-only model
  value returned by a state-machine cell, eta_crux shall provide no operation on
  that value that mutates the cell's model storage directly.
- **cell-9m4p** (event-driven): When eta_crux processes an action for an active
  input-dependent cell, eta_crux shall pass the current input value to the
  cell's transition function.
- **cell-1h8x** (event-driven): When eta_crux processes an action for an
  inactive input-dependent cell, eta_crux shall pass inactive input status to
  the cell's transition function.
- **cell-6t3c** (event-driven): When eta_crux processes an action for a cell
  that has been disposed, eta_crux shall discard the action without calling the
  cell's transition function.
- **api-7f3k** (ubiquitous): When application code defines an Eta Crux
  application, eta_crux shall expose a value- and function-based API over a
  threaded graph value.
- **api-2v9m** (ubiquitous): When eta_crux constructs an application, eta_crux
  shall accept the application as a function from the graph value to a root
  computation.
- **api-b4t8** (event-driven): When eta_crux constructs an application instance,
  eta_crux shall create one internal graph engine instance and pass the
  corresponding graph value to the root-construction function.
- **core-b7q4** (ubiquitous): When an application needs dependencies or
  capability senders, eta_crux shall receive them as values captured by the
  root-construction closure.

## Open questions

- Exact public OCaml types for computation values, input status, cell results,
  and inject functions.
- Whether Eta Crux exposes a separate external input variable API for tests and
  host-owned inputs.
