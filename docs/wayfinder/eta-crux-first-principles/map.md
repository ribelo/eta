# Eta Crux first-principles design map

## Destination

An implementation-ready V1 design for `eta_crux`: an Eta-native framework for
incremental, composable state machines. The design must use OCaml and Eta well,
use `eta_signal` only where it earns its place, and leave no design question for
implementation.

## Notes

This is a hobby project. Elegance, taste, depth, and what we want to learn have
more authority than market demand or compatibility with another framework.

The package name `eta_crux` is fixed. Its design is not fixed. Use **Rust Crux**
for the Rust framework and **Eta Crux** for this project. Rust Crux, Elm,
Bonsai, and Incremental are references, not compatibility targets.

The existing material is provisional input, not settled direction:

- `docs/requirements/eta-crux/`
- `docs/wayfinder/eta-crux/`
- `docs/prds/0002-eta-signal-frp.md`
- `docs/design/eta_signal-kernel-contract.md`
- `/home/ribelo/projects/ribelo/sliml/docs/`
- `/home/ribelo/projects/ribelo/taumel/`

Sliml is the first adapter experiment and remains useful prior evidence. Taumel
is the first active consumer and the near-term testing ground. Neither project
defines the architecture. A host adapter interprets typed output for its host.
Rendering is one possible interpretation. Eta Crux is not a UI or GUI
framework.

Eta Crux keeps a functional core with an imperative shell and a generic core
with specific shells. Shell placement is a transport choice. V1 includes both
in-process typed delivery and serialized cross-process delivery.

Eta owns effects, scopes, cancellation, resources, supervision, and failure
causes. Eta Crux owns computation structure, identity, advancement, and typed
output. When Eta Crux needs general runtime machinery that Eta lacks, improve Eta
instead of copying that machinery into Eta Crux.

Verify reference claims in source. Relevant local checkouts are
`/home/ribelo/projects/github/bonsai`,
`/home/ribelo/projects/github/incremental`,
`/home/ribelo/projects/github/iced`, and `/home/ribelo/projects/github/zed`.
The former `.reference/crux`, `.reference/foldkit`, and `.reference/syzygy`
checkouts are not present in this worktree.

Use `$grilling` and `$domain-modeling` for grilling tickets, `$prototype` for
prototype tickets, and `$research` for research tickets. Planning is the
deliverable. Implementation is not part of this map.

## Decisions so far

- [Eta Crux first-principles direction](issues/01-eta-crux-direction.md) — Build incremental, composable state machines over private `eta_signal`, with Eta effects, deterministic advancement, and host-interpreted typed output.
- [Reference semantics worth keeping](issues/02-reference-semantics.md) — Keep Bonsai computation laws and Incremental engine laws. Keep only the managed-effects idea from Elm and Rust Crux. Reject copied capability ports, Cmd/Sub, and fragment trees ([report](../../../.scratch/research/eta-crux/reference-semantics.md)).
- [Graph-neutral computation descriptions](issues/03-public-computation-api.md) — Use one identity-bearing, root-neutral `'a t`. Each root creates isolated live state, and no root can enter description composition ([Bonsai history](../../../.scratch/research/eta-crux/bonsai-functor-history.md)).
- [Keyed assoc and stable child identity](issues/04-keyed-assoc-contract.md) — Use `Assoc(Map.S)` and one private transactional keyed-map node. Continuous presence keeps state. Committed removal makes re-entry fresh.
- [Action injection and staged Eta effects](issues/05-action-effect-protocol.md) — State machines return immutable models plus typed-infallible Eta effects. Typed endpoints report ingress closure, while explicit exports add boundary codecs.
- [Deterministic advancement transaction](issues/06-advancement-transaction.md) — Process one message atomically, return output plus mandatory post-commit work, then drain until idle.
- [Dynamic lifetime and work ownership](issues/07-dynamic-lifetime-ownership.md) — Committed absence disposes fresh-incarnation child scopes. Scoped Eta programs and transition effects follow the structural ownership tree.
- [Long-lived sources and subscriptions](issues/08-subscriptions-and-sources.md) — Use a thin `Source` computation with a two-phase Eta producer. Spec equality preserves producers, readiness gates same-commit effects, and terminal outcomes become actions.
- [Root snapshot observation](issues/09-typed-observation-plan.md) — Expose one canonical root output. Adapters retain and reconcile snapshots after commit. V1 adds no typed observation plan.
- [Failure, defect, and crash boundary](issues/11-failure-boundary.md) — Escaping non-interruption causes end the root. Detection closes ingress, one mandatory batch settles teardown, and final reports preserve ordered Eta causes.
- [OCaml API syntax and ergonomics](issues/14-ocaml-api-ergonomics.md) — Use local computation let operators, ordinary modules and labeled constructors, a labeled source emitter, explicit failures, and no V1 PPX.
- [Package and module boundaries](issues/15-package-boundaries.md) — Use one wrapped core, a public Eta Signal keyed seam, optional codec and test packages, and host-owned concrete adapters.
- [Exported endpoint and handle contract](issues/16-exported-endpoint-contract.md) — Use structural export nodes, bounded ingress, authenticated handles, and per-export dispatch permits across local and serialized shells.
- [Eta supervised work substrate](issues/19-eta-supervised-work-substrate.md) — Eta adds request-only supervisor cancellation. Eta Crux registers gated work, requests removed-subtree cancellation, then releases new work without waiting for old cleanup.
- [Generic host adapter contract](issues/10-generic-host-adapter.md) — Use a pull driver with one-shot delivery tokens, an optional resource-bracketed hosted loop, and adapter-owned scheduling and reconciliation.
- [Host capabilities and request-response](issues/13-host-capabilities-and-requests.md) — Use explicit typed requesters and structural request exports with one-shot identity, scoped ownership, bounded capacity, and transport-equivalent driver handoff.
- [Wire codec and protocol contract](issues/17-wire-codec-protocol.md) — Use one strict sequenced driver protocol with typed host-operation descriptors, closed frame outcomes, and exact JSON and S-expression encodings.
- [Identity and serialized transport equivalence](issues/18-transport-equivalence.md) — Select one closed driver binding at root integration. Both variants preserve core semantics, while only the serialized variant owns wire state and session administration.
- [Deterministic testing contract](issues/12-testing-contract.md) — Use a thin scoped handle over production Root and Driver, real Eta effects with controlled dependencies, typed shell-request control, and step-local exact observations.

## Not yet specified

No remaining fog is known. Open child tickets contain the remaining decisions.

## Out of scope

- Changing the package name `eta_crux`.
- A renderer, widget library, form library, or routing framework inside Eta
  Crux.
- Compatibility with Rust Crux, Elm, or Bonsai APIs.
- Sliml and Taumel implementation details beyond the Eta Crux contracts that
  they use.
- Additional concrete host packages. [Generic host adapter contract](issues/10-generic-host-adapter.md)
  validates one same-domain host and one foreign retained host without selecting
  another V1 host.
- Eta Crux implementation as a deliverable of this map.
