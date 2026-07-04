---
kind: requirement
status: draft
tags: [eta_crux, adapter, boundary, dispatch, sliml]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/boundary-contract]]", "[[docs/requirements/eta-crux/fragments]]", "[[docs/requirements/eta-crux/tick]]"]
traces_to: []
---
# Adapter interface and connection mechanism

## Intent

An adapter connects an Eta Crux application instance to a concrete host or UI
toolkit. Eta Crux provides type-agnostic driver and transport behavior:
admission, driver advancement, fragment observation, batched output delivery,
capability-message delivery, and cross-domain handoff. Application or toolkit
code provides type-aware binding between typed fragments, typed inject
functions, and host-specific mutation points.

Inbound binding captures cell inject functions and connects them to host events.
Outbound binding maps fragments to host-specific properties, records, row
models, or equivalent immutable payloads. A retained toolkit receives changed
fragment payloads and subtree changes at stable fragment addresses.

Toolkit adapters depend on a host surface, not on Eta Crux's internal graph
engine. A UI toolkit binding needs operations for property mutation, callback
binding, scheduling work onto the UI runtime, and incremental collection row
notifications when the toolkit supports retained row models.

## Requirements

- **adpt-3k7m** (ubiquitous): When an adapter is implemented, eta_crux shall
  provide type-agnostic driver and transport behavior and shall require
  application-specific code to bind typed actions and typed fragments to the
  host surface.
- **adpt-9d2r** (ubiquitous): When an adapter binds an inbound host event,
  eta_crux shall let the adapter capture a typed cell inject function directly.
- **adpt-5t8w** (event-driven): When an adapter invokes a cell inject function
  from a non-owner domain, eta_crux shall admit the action through the
  cross-domain action admission path.
- **adpt-b4h1** (event-driven): When an adapter binds an outbound scalar
  fragment, eta_crux shall let the adapter map that fragment to a host-specific
  mutation point.
- **adpt-2n6q** (event-driven): When an adapter binds an outbound keyed
  collection fragment, eta_crux shall let the adapter map keyed subtree changes
  to host-specific row add, row change, and row remove operations.
- **adpt-7c3j** (ubiquitous): When an adapter runs in the same OCaml process,
  eta_crux shall allow the adapter to carry typed actions, fragments, and
  capability messages as direct values.
- **adpt-e1v9** (ubiquitous): When an adapter targets a UI toolkit, eta_crux
  shall require no dependency from the toolkit binding to Eta Crux's internal
  graph engine.

## Open questions

- Whether the first Slint binding is hand-written or generated from `.slint`
  interface metadata.
- Which package owns generic Slint transport glue: `eta_crux` or
  `eta_crux_sliml`.
- Exact value conversion API from typed fragments to host-specific property and
  row payloads.
