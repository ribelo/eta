# ADR 0006: OxCaml is the only compiler target

Status: accepted.

## Context

Eta uses OxCaml `5.2.0+ox`. An upstream OCaml track restricted source design
and required separate Nix shells, package subsets, and test gates.

The upstream track prevented direct use of OxCaml features in shared source.
These features include modes, stack allocation, unboxed layouts, and
zero-allocation checks.

## Decision

Eta targets OxCaml `5.2.0+ox` only.

Production source can use OxCaml extensions when they improve safety,
representation, or measured performance. The default Nix shell and its OxCaml
gates are authoritative.

The repository removes the `mainline` and `ocaml54` Nix shells. It also removes
their test scripts. Upstream OCaml compatibility is not a release requirement.

## Consequences

Eta packages can use compiler-specific representations without a compatibility
implementation.

Contributors must run build and test commands through `nix develop`. Results
from an ambient OCaml switch are not handoff evidence.

The active OxCaml toolchain does not build the js_of_ocaml packages. The native
gates do not verify those adapters.
