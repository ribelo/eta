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
The package owns graph state, transactions, scopes, observers, time, and
diagnostics.

Keyed collections and stream bridges are optional sibling capabilities. The
public Eta Signal interface stays small when applications do not install them.

## Requirement Notes

- [[docs/requirements/eta-signal/keyed-extension]] — the sealed stable-family
  protocol required by `eta_signal_map`.
