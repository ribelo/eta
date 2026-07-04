---
kind: requirement
status: draft
tags: [eta_crux, boundary, contract]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: []
traces_to: []
---
# Cross-boundary public contract

## Intent

Eta Crux adapters connect an application instance to an external host, UI
toolkit, or shell. The boundary is value-oriented: external hosts submit inbound
actions, Eta Crux exposes outbound fragments, and applications with shell-owned
work emit outbound capability messages.

The boundary does not carry Eta effect values, direct model mutation, direct cell
storage access, or arbitrary application callbacks. An adapter that needs a
single aggregate value derives it from fragments at the adapter boundary.

Serialization is required only for deployments that cross a process or language
boundary. In-process adapters carry typed OCaml values directly when the
target toolkit can accept them.

## Requirements

- **boundary-7t2q** (ubiquitous): When an external host supplies input to Eta
  Crux, eta_crux shall accept that input as inbound actions.
- **boundary-3n9x** (ubiquitous): When an external host affects application
  state, eta_crux shall expose action dispatch as the host's only application
  state mutation verb.
- **boundary-k5r8** (ubiquitous): When an external host integrates with Eta
  Crux, eta_crux shall provide no boundary operation that triggers Eta effect
  work directly.
- **boundary-b6t3** (ubiquitous): When application code exposes outbound state,
  eta_crux shall expose that state as per-cell output fragments.
- **boundary-p1n7** (event-driven): When an exposed output fragment changes,
  eta_crux shall make the updated fragment available to the adapter.
- **boundary-6y2v** (ubiquitous): When values cross an Eta Crux adapter
  boundary, eta_crux shall confine those values to inbound actions, outbound
  fragments, and outbound capability messages.
- **boundary-d1h5** (ubiquitous): When Eta effect values are used by application
  code, eta_crux shall keep those effect values inside the OCaml core.
- **boundary-9q7c** (ubiquitous): When an adapter crosses a process or language
  boundary, eta_crux shall require serialization only for the boundary payload
  types: actions, fragments, and capability messages.
- **boundary-a3f9** (event-driven): When an adapter targets a retained UI
  toolkit, eta_crux shall deliver outbound fragments as immutable adapter
  payloads expressible by that toolkit.

## Open questions

- Whether Eta schemas are required for out-of-process action, fragment, and
  capability-message transport.
