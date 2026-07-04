---
kind: doc
status: draft
tags: [eta_crux, overview, concepts, mental-model]
---
# Concepts overview

This note defines the vocabulary used by the eta_crux requirement notes.

## Core Shape

Eta Crux applications are root computations made from state-machine cells.

```
inbound action
    |
    v
bounded action queue
    |
    v
driver advancement
    |
    +--> cell transition: input status -> model -> action -> model * scheduled_command list
    |
    +--> graph stabilization
    |
    +--> lifecycle work
    |
    +--> fragment observation
    |
    +--> command spawn
             |
             v
        Eta effect resolves to action
             |
             v
        bounded action queue
```

## Definitions

- **Application instance** — a live Eta Crux root computation with an internal
  graph, action admission, driver operations, output observation, command and
  subscription ownership, and shutdown.
- **Root computation** — the top-level computation returned by the application's
  graph-construction function.
- **Cell** — a graph-native state-machine computation node with local model
  storage, a local action type, a transition function, lifecycle scope, result
  value, and inject function.
- **Model** — cell-owned state stored inside the computation graph.
- **Read-only model value** — the computation value through which application
  code observes a cell model.
- **Action** — a typed event addressed to the cell that created the inject
  function used to emit it.
- **Inject function** — the cell-local function that admits actions for that
  cell.
- **Input status** — the value supplied to an input-dependent cell transition:
  either current input or inactive input status.
- **Scheduled command** — command work plus Eta Crux execution metadata.
- **Command work** — a force-total Eta effect that resolves to one action.
- **Command slot** — a per-cell replacement key for command work where a new
  command interrupts the previous current command in that slot.
- **Subscription** — a state-derived long-lived Eta stream source whose items are
  mapped to actions.
- **Fragment** — optional typed output derived from cell state or computation
  values and exposed at an address in the output tree.
- **Adapter** — host-specific code that submits inbound actions, observes
  fragments, and forwards outbound capability messages.
- **Capability message** — a typed outbound message asking an external shell to
  perform shell-owned work or stop shell-owned work.
- **Driver operation** — an explicit operation used by a host or test to submit
  actions, advance ready work, observe outputs, advance test time, or request
  shutdown.
