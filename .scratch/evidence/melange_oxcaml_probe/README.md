# Melange / OxCaml syntax probe

This directory is a reproducible syntax probe for whether Eta's OxCaml-flavored
source can be compiled by a standard OCaml/Melange toolchain.

Run:

```sh
bash scratch/evidence/melange_oxcaml_probe/run.sh
```

The script writes generated snippets under `_generated/`, compiles each with
the available OCaml compiler, and tries Melange when `melc` is available. The
expected result is:

- regular attributes such as `[@zero_alloc]` parse under stock OCaml, but are
  not checked as OxCaml zero-allocation contracts;
- OxCaml mode/kind syntax used by Eta, such as `@ portable`, `@ many`,
  `immutable_data`, `value mod portable`, and `global_`, fails before
  ordinary type checking.
