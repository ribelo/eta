# OxCaml lifecycle mechanisms

Type: research
Status: open
Blocked by:

## Question

Which OxCaml mechanisms can strengthen or optimize Eta component ownership and
context handling?

Assess `portable`, `contended`, `local`, stack allocation, uniqueness,
once-use values, capsules, kinds, and mode-crossing behavior. Distinguish
semantic guarantees from allocation or race-prevention improvements.

Use the repository compiler version and primary OxCaml documentation or source.
Record small compiler probes where documentation does not settle a claim.
Identify mechanisms that cannot apply because component instances and their
contexts outlive a stack frame or cross domains.

Write one cited report under
`.scratch/research/eta-component-runtime/`.
