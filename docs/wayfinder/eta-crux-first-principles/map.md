# Eta Crux first-principles design map

## Destination

An implementation-ready V1 design for `eta_crux`: an Eta-native,
unidirectional application-computation framework. The design must use OCaml and
Eta well, use `eta_signal` only where it earns its place, and leave no design
question for implementation.

## Notes

This is a hobby project. Elegance, depth, and what we want to learn have more
authority than market demand or compatibility with another framework.

The package name `eta_crux` is fixed. Its design is not fixed. Use **Rust Crux**
for the Rust framework and **Eta Crux** for this project. Rust Crux, Elm,
Bonsai, and Incremental are references, not compatibility targets.

The existing material is provisional input, not settled direction:

- `docs/requirements/eta-crux/`
- `docs/wayfinder/eta-crux/`
- `docs/prds/0002-eta-signal-frp.md`
- `docs/design/eta_signal-kernel-contract.md`
- `/home/ribelo/projects/ribelo/sliml/docs/`

Sliml is the first concrete adapter and a useful falsifier. It is one host, not
the architecture. A host adapter owns rendering. Eta Crux ends at compositional
computation and typed output.

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
- [Reference semantics worth keeping](issues/02-reference-semantics.md) — Keep Bonsai computation laws and Incremental engine laws; treat Elm/Crux managed effects thinly; drop unjustified Cmd/Sub, FFI capability, and fragment-tree copies ([report](../../../.scratch/research/eta-crux/reference-semantics.md)).

## Not yet specified

- **Operational introspection.** Logging, action history, graph inspection, and
  time-travel support depend on the final action, error, and test contracts.
- **Performance gates.** Useful budgets and benchmarks depend on the public
  computation API, keyed composition, and output-delivery design.
- **Requirement and ADR replacement.** The old bundle must be reconciled or
  replaced after the design decisions reveal the final document structure.
- **Additional hosts.** Sliml validates one retained foreign-loop host. The next
  useful host type is unclear until the generic adapter contract exists.

## Out of scope

- Changing the package name `eta_crux`.
- A renderer, widget library, form library, or routing framework inside Eta
  Crux.
- Compatibility with Rust Crux, Elm, or Bonsai APIs.
- Sliml implementation details beyond the contract that an Eta Crux adapter
  consumes.
- Eta Crux implementation as a deliverable of this map.
