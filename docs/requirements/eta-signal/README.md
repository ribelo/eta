---
kind: requirement
tags: [eta_signal, architecture, overview]
refines: []
depends_on: []
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# eta_signal

## Intent

`eta_signal` provides a generative reactive graph with explicit stabilization.
The package owns graph state, transactions, scopes, observers, and diagnostics.

Keyed collections are an optional sibling capability. The public Eta Signal
interface stays small when applications do not install that capability.

## Requirement Notes

- [[docs/requirements/eta-signal/keyed-extension]] — the private kernel and the
  graph protocol required by `eta_signal_map`.
