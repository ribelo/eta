# Keyed removal with a nested bind switch

Type: prototype
Status: resolved
Blocked by: none

## Question

Does one stabilization that removes a keyed child and switches its nested bind
reproduce N2?

Build the smallest public graph from the independent review. Observe owner and
scope validity, committed bind state, dependent edges, provisional-scope
cleanup, pending transaction work, and retained node counts. Include a new
branch that points to a top-scope signal.

Vary planning and commit order only in the throwaway prototype. Use the result
to identify the invalidation-closure invariant. Do not implement the production
fix. Link the prototype as an asset.

## Answer

Yes. N2 reproduces with the public graph from the review.

The current run records this order:

```text
stage_bind_switch,commit_keyed_removal,commit_bind_switch
```

The keyed removal invalidates the nested bind and its old branch scope. The
later bind commit publishes `right`. It creates a valid scope under an invalid
parent and attaches the invalid bind to the valid top-scope `right` signal.

The output is the correct empty map. The transaction also leaves no pending
keyed plan or bind snapshot. Thus, the successful transaction publishes a
hybrid topology that output-only checks cannot detect.

A quiescent stabilization keeps the invalid edge. After five removals, `left`
retains two invalid bind dependents and `right` retains three. The control
retains none.

### Ordering control

The control commits keyed removal before bind planning. It records only
`commit_keyed_removal`, so no nested bind switch is staged.

This order is not a production correction. It mutates topology before
preflight. It only confirms that bind planning against the still-committed keyed
child is necessary for the defect.

### Required invalidation-closure invariant

Before topology mutation, one fixed invalidation frontier must include all
keyed removals and staged dynamic operations. A staged operation whose owner is
in that frontier cannot commit.

Discard processing must clear the staged snapshot of that bind. It must also
invalidate the provisional scope. Commit processing cannot attach an invalid
owner to a valid dependency.

[Transaction and invalidation model](09-transaction-and-invalidation-model.md)
owns the final phase model and plan shape. [Laws and economics
gates](16-laws-and-economics-gates.md) owns the regression and diagnostic gate.

### Diagnostic correction

Public DOT and node statistics do not expose the retained edge. The bind appears
as a tombstone, but DOT records its old edge state before the later bind commit.
`total_node_count` also omits invalid nodes.

The current run and the control produce identical DOT output and node counts.
A regression therefore needs direct edge evidence or corrected diagnostics.

### Evidence

The prototype is on branch `prototype/eta-signal-keyed-bind-invalidation` at
commit `96cfde59`. Run it with one command:

```sh
bash .scratch/prototypes/eta-signal-keyed-bind-invalidation/run.sh
```

The command exits with status `0` and fails if the observations differ from the
N2 counterexample or its ordering control.

- [Probe results](../../../../.scratch/research/eta-signal-direction/keyed-bind-invalidation/RESULTS.md)

### Census rows resolved here

The prototype confirms `EXE-010`, `N02-002` through `N02-017`, `N02-019`,
`N02-021`, `N02-022`, `N02-024`, `N02-041`, `S06-002`, `S12-002`, `Q04-001`,
and `Q04-002`.

It amends `N02-018`. The invalid node appears as a tombstone, but public
diagnostics omit the retained post-invalidation edge.
