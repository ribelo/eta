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

Eta Crux is a hobby project. The design optimizes for elegance, taste, depth,
and the parts that are interesting to write. It does not need a market
justification.

Eta Crux will provide a Bonsai-like computation layer. Its
primary value is composable local state, dynamic structure, keyed composition,
scoped lifetimes, typed actions, and Eta effects. A typed computation yields a
changing value and can allocate state, injection, lifecycle, and child
computations.

`eta_signal` is usable but unfinished. It will be Eta Crux's private incremental
engine. Eta Crux will expose its own computation API and will not expose raw
signals as its programming model.

There is no `eta_signal_map` today. Keyed incremental-map support is a known
gap, comparable to Jane Street's `Incr_map`. Current evidence shows that `map`,
`bind`, scopes, observer demand, and stabilization fit.

Any gap in `eta_signal` or Eta that blocks the correct design is in scope to
fix. Eta Crux will not preserve an incomplete contract or add a workaround for
such a gap.

A state transition is synchronous. It receives its own typed endpoint and
returns an immutable model plus one typed-infallible Eta effect. Eta Crux starts
the effect only after the complete advancement commits.

One deterministic advancement primitive defines runtime semantics. A hosted Eta
loop and an explicit test or adapter driver both use that primitive.

The root computation yields one typed result. That result is the canonical
semantic output. Host adapters own rendering and host reconciliation. A
host adapter retains and reconciles complete root snapshots. V1 exposes no
typed observation plan, fragments, paths, type witnesses, `Obj`, or raw
`eta_signal` types. [Ticket 09](09-typed-observation-plan.md) records the
prototype evidence.

Sliml was the first adapter experiment and remains useful evidence. Taumel is
now the first active consumer and the near-term testing ground. It needs Eta
Crux now. Neither project defines the Eta Crux architecture.
