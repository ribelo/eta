---
kind: requirement
tags: [eta_crux, composition, cells, messages]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/commands-and-effects]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Composition and action representation

## Intent

Cells compose into a graph whose live structure is derived from application
state. Each cell owns its action type and inject function. Application code
dispatches to a cell by calling that cell's typed inject function; routing to the
owning cell is internal to Eta Crux.

Static composition constructs cells directly. Constructing the same cell
definition more than once creates independent cell instances. Dynamic
composition selects branches and keyed collections from computation values.

`assoc` is the keyed dynamic collection combinator. It maintains one scoped
sub-computation per live key and preserves that sub-computation while the key
remains live.

Child-to-parent notification is expressed as ordinary command construction: a
parent passes a constructor to a child, and the child schedules the constructed
command as part of its transition result.

## Requirements

- When application code defines a cell action type, eta_crux shall treat that
  action type as opaque to the core. ^compose-4k2t
- When application code dispatches to a cell, eta_crux shall use the cell's typed
  inject function and shall require no user-facing cell address. ^compose-d7m3
- When application code constructs the same cell definition more than once in one
  live graph, eta_crux shall create independent cell instances. ^compose-b1t8
- When state selects a branch of dynamic structure, eta_crux shall
  activate the selected branch's cells and dispose the deselected
  branch's cells. ^compose-9k4n
- While a keyed dynamic collection is live, eta_crux shall maintain one scoped
  sub-computation per live key. ^compose-7d2v
- While a key remains present in a keyed dynamic collection, eta_crux shall
  preserve that key's associated cell state and lifecycle scope. ^compose-k8hp
- When a key enters a keyed dynamic collection, eta_crux shall create and activate
  that key's associated scope. ^compose-dz9r
- When a key leaves a keyed dynamic collection, eta_crux shall deactivate and
  dispose that key's associated scope. ^compose-ckn3
- When data changes for an existing key in a keyed dynamic collection,
  eta_crux shall update that key's computation input without
  recreating the key's scope. ^compose-jync
- When a parent passes a command constructor to a child, eta_crux
  shall let the child return the constructed command among the
  child's scheduled commands. ^compose-3j6k

## Open questions

- Whether Eta Crux also exposes a dedicated upward-output channel in addition to
  command constructors passed down by parents.
- Recommended API for threading a parent's command constructor through nested
  child components.
