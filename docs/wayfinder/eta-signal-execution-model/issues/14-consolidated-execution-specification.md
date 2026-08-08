# Consolidated execution specification

Type: task
Status: resolved
Blocked by: 04, 12, 13, 17

## Question

What complete implementation specification and replacement route follow from
the production pre-alpha execution model?

Name the representations, state transitions, seams, module invariants, public
interface, package ownership, performance gates, and ordered replacement work.

The specification must describe the implemented production modules.
Production must pass the complete behavior and package gates.
Record the current performance baseline without optimizing it.

## Answer

The production replacement is usable and behavior-correct.
The complete architecture is in
[Eta Signal execution model](../../../design/eta_signal-execution-model.md).

This ticket fixed a demanded timer that could stop after its daemon failed
during startup. It also replaced the broken `@signal-gates` aliases and updated
the Signal Map example for the synchronous interface.

These OxCaml gates pass:

- `nix develop -c dune build @signal-gates @install`
- `EIO_BACKEND=posix nix develop -c dune runtest --force`
- `EIO_BACKEND=posix nix develop -c eta-oxcaml-test-shipped`

The focused baseline still misses the frozen performance matrix.
The user selected the order: make it work, make it right, then make it fast.
Performance optimization moves to a later effort.
