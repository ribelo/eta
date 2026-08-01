# Map kernel prototype

Type: prototype
Status: resolved
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

## Answer

### Decision

Use a persistent weight-balanced binary search tree for the map kernel. Each
node stores its left child, key, data, right child, and subtree size. Weight is
`size + 1`.

Use `(delta, gamma) = (5/2, 3/2)`. Cross-multiplied integer comparisons enforce
the balance and rotation conditions.

A same-data `set` returns the same physical root. Removing an absent key also
returns the same physical root. Other edits copy the changed spine and required
rotation nodes. Unchanged subtrees retain physical identity.

The symmetric-diff frontier follows this order:

1. Skip a physically identical tree.
2. Recurse directly when both root keys match.
3. Use ordered cursors when root keys differ.
4. Expand the heavier cursor tree until shared subtrees align.
5. Skip aligned physical subtrees before key comparison.

Independent maps still receive a complete ordered diff. They do not receive the
shared-ancestry performance guarantee.

If the diff accepts `data_equal`, physical equality must imply data equality.
The public map API ticket decides whether that argument remains public.

### Evidence

The prototype is on branch `prototype/eta-signal-map-kernel` at commit
`33d0c10f`:

- [Map kernel prototype](https://github.com/ribelo/eta/tree/33d0c10f/.scratch/prototypes/eta-signal-map-kernel)

Run all checks after checkout:

```sh
bash .scratch/prototypes/eta-signal-map-kernel/run.sh all
```

The OxCaml and mainline OCaml gates pass. The evidence includes:

- 2,000 generated edit scripts checked against `Stdlib.Map`
- 2,000 independently built map pairs reconstructed in both directions
- 1,000 no-op identity cases
- 40,000 fixed-seed invariant-preserving edits
- 200 fixed-seed related-map diff scripts
- 12 key comparisons for one shared-ancestry insertion
- 1,025 comparisons after rebuilding the same 1,025 bindings
- exact sharing counts for insert, update, and removal on a 127-node map

The prototype and both independent reviews found no kernel logic defect.

### Deferred

The public API ticket owns key modules, equality arguments, and ordinary map
operations. The benchmark ticket owns asymptotic budgets and wall-time evidence.
Production implementation remains outside this planning effort.
