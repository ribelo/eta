# Map kernel prototype

Type: prototype
Status: claimed
Blocked by: 04

## Question

Does the selected clean-room kernel satisfy Eta's map semantics and preserve
the structure that later performance claims require?

Build a throwaway kernel from the cited algorithms. Do not copy Base
implementation code. The prototype must include only the operations needed to
exercise persistent edits and diff.

Rewrite the relevant Base scenarios in the repository test style. Cite the
reviewed Base revision.

The prototype must show:

- ordering and balance invariants after random edit scripts
- unchanged subtree sharing after insert, remove, and update
- correct forward and reverse reconstruction from diffs
- correct linear comparison for independently built maps
- a small comparison-count check for shared and independent snapshots

Decide the node shape, invariant checks, physical-sharing rules, and exact diff
frontier. The dedicated benchmark ticket owns asymptotic measurements.

Keep the prototype on a throwaway branch. Link its design note, command, and
commit from the answer.
