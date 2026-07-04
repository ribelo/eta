---
kind: requirement
status: draft
tags: [eta_crux, eta_signal, engine, layering, eta_signal_map, timer]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/composition]]", "[[docs/requirements/eta-crux/tick]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Engine strategy

## Intent

Eta Crux uses an incremental graph engine for computation values, dynamic
structure, stabilization, observers, and timers. Keyed dynamic collections are
provided through an `eta_signal_map` companion package rather than as primitive
operations in `eta_signal`.

`eta_signal_map` provides keyed diffing, stable per-key scopes, and update of
existing key data without recreating the key scope. Eta Crux consumes that
capability through its `assoc` combinator.

The graph engine must also provide timer wake information. Time nodes become
observable only when the driver advances and stabilizes the graph, so a due time
must make the application driver eligible to advance.

## Requirements

- **eng-3p7k** (ubiquitous): When `eta_signal` is used as the Eta Crux graph
  engine, `eta_signal` shall keep keyed collection operations outside the
  `eta_signal` core API.
- **eng-8w2n** (ubiquitous): When eta_crux supports keyed dynamic collections,
  eta_crux shall consume a sibling `eta_signal_map` keyed collection substrate.
- **eng-b4r9** (ubiquitous): When eta_crux exposes `assoc`, eta_crux shall
  implement `assoc` over `eta_signal_map`.
- **eng-m5k7** (state-driven): While a key remains present in an
  `eta_signal_map` collection, `eta_signal_map` shall preserve that key's
  associated scope.
- **eng-r9p2** (event-driven): When a key enters an `eta_signal_map` collection,
  `eta_signal_map` shall create a scope for that key.
- **eng-c6v1** (event-driven): When a key leaves an `eta_signal_map` collection,
  `eta_signal_map` shall dispose that key's scope.
- **eng-n3d8** (event-driven): When existing key data changes in an
  `eta_signal_map` collection, `eta_signal_map` shall update the key's
  associated computation without recreating the key's scope.
- **eng-c1m6** (ubiquitous): When `eta_signal_map` requires graph-engine support
  for keyed diffing and stable per-key scopes, `eta_signal` shall expose the
  minimal hook needed for that support.
- **eng-6h8t** (event-driven): When an engine time node reaches its due time,
  the graph engine shall provide wake information that makes the Eta Crux driver
  eligible to advance.

## Open questions

- Exact `eta_signal` hook required by `eta_signal_map`.
- Exact comparator and key module discipline for `eta_signal_map`.
- Whether timer wake is exposed as a next deadline, a condition signal, or both.
