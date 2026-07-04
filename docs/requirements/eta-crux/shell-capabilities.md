---
kind: requirement
status: draft
tags: [eta_crux, shell, capabilities, platform, messages]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/boundary-contract]]", "[[docs/requirements/eta-crux/commands-and-effects]]"]
traces_to: []
---
# Shell / platform capabilities

## Intent

Most effects run inside the OCaml core as Eta effects. Shell capability messages
cover work that belongs to an external shell or platform host, such as native
device APIs, platform pickers, share sheets, or sandboxed resources unavailable
to the OCaml core.

Declarative platform state is output state. Application code exposes it through
fragments, and the shell renders it. User responses return as inbound actions.

Imperative platform work is a typed outbound capability message. A command whose
work needs shell-owned behavior sends the outbound capability message through an
injected sender. The shell performs the work and reports completion, failure, or
user response by dispatching an ordinary inbound action.

Correlation tokens belong to the application payload. If the application needs
to match a shell response to a specific request, the outbound capability message
carries a token and the inbound action carries the corresponding token.

Stopping shell-owned work is another outbound capability message in the same
application protocol.

## Requirements

- **shell-4k8t** (ubiquitous): When application code represents declarative
  platform state, eta_crux shall expose that state through output fragments.
- **shell-9m3x** (event-driven): When command work needs shell-owned behavior,
  eta_crux shall send a typed outbound capability message through an injected
  sender.
- **shell-2p9n** (event-driven): When the shell reports completion, failure, or
  user response for shell-owned work, eta_crux shall accept that report as an
  ordinary inbound action.
- **shell-e1c6** (ubiquitous): When a shell integrates with Eta Crux, eta_crux
  shall expose no shell operation for mutating application state other than
  inbound action dispatch.
- **shell-n7v3** (ubiquitous): When application code needs correlation for
  shell-owned work, eta_crux shall require the correlation token to be part of
  the application-defined outbound and inbound payloads.
- **shell-c4h8** (event-driven): When shell-owned work must stop, eta_crux shall
  express the stop request as an outbound capability message.
- **shell-6h4q** (state-driven): While an application declares no shell-owned
  capabilities, eta_crux shall produce no outbound capability messages.

## Open questions

- Exact type and lifetime of the injected outbound capability-message sender.
- Whether the first Slint adapter needs any shell capability channel beyond
  ordinary fragments and inbound actions.
