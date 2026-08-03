# Eta Crux first-principles design map

## Destination

An implementation-ready V1 design for `eta_crux`: an Eta-native,
unidirectional application-computation framework. The design must use OCaml and
Eta well, use `eta_signal` only where it earns its place, and leave no design
question for implementation.

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
defines the architecture. A host adapter owns rendering. Eta Crux ends at
compositional computation and typed output.

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

- [Eta Crux first-principles direction](issues/01-eta-crux-direction.md) — Build a Bonsai-like layer over private `eta_signal`, with Eta effects, deterministic advancement, typed output, and host-owned rendering.
- [Reference semantics worth keeping](issues/02-reference-semantics.md) — Keep Bonsai computation laws and Incremental engine laws. Keep only the managed-effects idea from Elm and Rust Crux. Reject copied capability ports, Cmd/Sub, and fragment trees ([report](../../../.scratch/research/eta-crux/reference-semantics.md)).
- [Graph-neutral computation descriptions](issues/03-public-computation-api.md) — Use one identity-bearing, root-neutral `'a t`. Each root creates isolated live state, and no root can enter description composition ([Bonsai history](../../../.scratch/research/eta-crux/bonsai-functor-history.md)).
- [Keyed assoc and stable child identity](issues/04-keyed-assoc-contract.md) — Use `Assoc(Map.S)` and one private transactional keyed-map node. Continuous presence keeps state. Committed removal makes re-entry fresh.
- [Action injection and staged Eta effects](issues/05-action-effect-protocol.md) — State machines return immutable models plus typed-infallible Eta effects. Typed endpoints report ingress closure, while explicit exports add boundary codecs.
- [Deterministic advancement transaction](issues/06-advancement-transaction.md) — Process one message atomically, return output plus mandatory post-commit work, then drain until idle.
- [Dynamic lifetime and work ownership](issues/07-dynamic-lifetime-ownership.md) — Committed absence disposes fresh-incarnation child scopes. Scoped Eta programs and transition effects follow the structural ownership tree.
- [Long-lived sources and subscriptions](issues/08-subscriptions-and-sources.md) — Use a thin `Source` computation with a two-phase Eta producer. Spec equality preserves producers, readiness gates same-commit effects, and terminal outcomes become actions.
- [Failure, defect, and crash boundary](issues/11-failure-boundary.md) — Escaping non-interruption causes end the root. Detection closes ingress, one mandatory batch settles teardown, and final reports preserve ordered Eta causes.
- [Eta supervised work substrate](issues/19-eta-supervised-work-substrate.md) — Eta adds request-only supervisor cancellation. Eta Crux registers gated work, requests removed-subtree cancellation, then releases new work without waiting for old cleanup.

## Not yet specified

- **Operational introspection.** Logging, action history, graph inspection, and
  time-travel support depend on the final action, error, and test contracts.
- **Performance gates.** Useful budgets and benchmarks depend on the public
  computation API, keyed composition, and output-delivery design.
- **Requirement and ADR replacement.** The old bundle must be reconciled or
  replaced after the design decisions reveal the final document structure.
- **Additional hosts.** Taumel is the active testing ground. The next distinct
  host type is unclear until the generic adapter contract exists.

## Out of scope

- Changing the package name `eta_crux`.
- A renderer, widget library, form library, or routing framework inside Eta
  Crux.
- Compatibility with Rust Crux, Elm, or Bonsai APIs.
- Sliml and Taumel implementation details beyond the Eta Crux contracts that
  they use.
- Eta Crux implementation as a deliverable of this map.
