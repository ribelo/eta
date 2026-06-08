# OxCaml Toolchain Probe

This probe is the executable evidence for `Effet-OxCaml-nkh`.

It keeps one dependency-free source file with OxCaml mode syntax:

- `mode_syntax.ml`

The flake helper `effet-oxcaml-check-toolchain` builds the file, checks
ocamlformat round-trip fidelity, asks merlin for diagnostics, and opens the
same document through ocaml-lsp over stdio.
