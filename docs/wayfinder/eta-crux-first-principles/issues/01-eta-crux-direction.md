# Eta Crux first-principles direction

Type: grilling
Status: resolved

## Question

What are we trying to write, what makes it worth writing, and which existing
assets or references constrain the direction?

## Answer

The package remains named `eta_crux`, but its existing requirements, ADR ideas,
and design map are not fixed. Rust Crux is reference material, not a model to
rewrite faithfully.

Eta Crux is a hobby project. The design optimizes for elegance, depth, and the
parts that are interesting to write. It does not need a market justification.

Eta Crux will provide a Bonsai-like computation layer, not a renderer. Its
primary value is composable local state, dynamic structure, keyed composition,
scoped lifetimes, typed actions, and Eta effects. A typed computation yields a
changing value and can allocate state, injection, lifecycle, and child
computations.

`eta_signal` will be Eta Crux's private incremental engine. Eta Crux will expose
its own computation API and will not expose raw signals as its programming
model. The `eta_signal` contract can change where Eta Crux needs a narrow engine
capability. Current evidence shows that `map`, `bind`, scopes, observer demand,
and stabilization fit. Stable keyed `assoc` is the main missing engine feature.

A state transition is synchronous. It receives a restricted context for staging
ordinary Eta effects and injecting later actions. Eta Crux runs staged effects
only after it commits the model.

One deterministic advancement primitive defines runtime semantics. A hosted Eta
loop and an explicit test or adapter driver both use that primitive.

The root computation yields one typed result. That result is the canonical
semantic output. Host adapters own rendering and host reconciliation. A
prototype will test an adapter-owned typed observation plan for granular
incremental delivery. The public contract must not add fragments, paths, type
witnesses, `Obj`, or raw `eta_signal` types.

Sliml is the first concrete validation target and the only current host example.
It proves the need for a unidirectional host boundary, but it does not define the
Eta Crux architecture.
