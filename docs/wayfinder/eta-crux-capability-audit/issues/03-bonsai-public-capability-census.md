# Bonsai public capability census

Type: research
Status: open

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
