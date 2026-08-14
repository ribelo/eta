# OxCaml lifecycle mechanisms

Type: research
Status: resolved
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

## Answer

OxCaml can add static lifetime, ownership, and cross-domain race checks, plus
temporary-allocation optimizations. It cannot replace the backend-neutral
lifecycle state machine or its exactly-once cleanup semantics. Capsules remain
unresolved because their external API is not an Eta dependency and is still
evolving. See
[the cited report](../../../../.scratch/research/eta-component-runtime/06-oxcaml-lifecycle-mechanisms.md).
