# Bonsai public capability census

Type: research
Status: resolved

## Question

What public capability families do Bonsai and Bonsai test tools provide?

Use current primary source code and official documentation. Include Incremental
only where its semantics support a public Bonsai capability.

Inventory each public capability family at a useful architectural level. Cover
graph values, inputs, state machines, time, lifecycle, dynamic structure,
effects, resources, and edge-triggered operations. Also cover host integration,
observation, testing, debugging, and other families that the source exposes.

For each family, record:

- its user-visible purpose.
- its essential semantic contract.
- its test control.
- its lifecycle and effect ownership.
- whether it has a plausible generic Eta Crux role, supplies design evidence
  only, or appears Bonsai-specific.

The last classification is research evidence, not the final Eta Crux decision.
Record every excluded family with a reason.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [Bonsai census report](../../../../.scratch/research/eta-crux-capability-audit/bonsai-public-capability-census.md)
records 21 public capability families.

Sixteen families have a plausible generic Eta Crux role.
Four families supply design evidence only.
Graph paths and stable identity are Bonsai-specific.

The census covers graph values, inputs, state, time, lifecycle, dynamic
structure, effects, resources, host integration, observation, and test tools.
It records each semantic contract, test control, ownership boundary, and
research classification.

The report makes no final capability decision.
It also records that Bonsai has lifecycle evidence, but no general scoped-resource contract.
