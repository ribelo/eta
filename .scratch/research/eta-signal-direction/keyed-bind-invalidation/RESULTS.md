# Keyed-bind invalidation: executable evidence for N2

## Question

Can one stabilization remove a keyed child and commit a staged switch from a
bind inside that child?

## Method

The probe constructs the graph through the Signal Map public API. One keyed
child contains a bind that selects between two top-scope constants.

The probe observes the keyed output and uses branch-only introspection for these
internal facts:

- The validity of the keyed scope and bind owner.
- The committed bind inner signal and inner scope.
- The validity of the inner scope and its parent.
- The dependency lists of the bind and top-scope signals.
- Pending keyed and bind transaction state.
- Public statistics and DOT output.

The observation boundary is the idle graph after `stabilize` returns. The probe
also runs a quiescent stabilization and four more add, switch, and removal
cycles.

The primary run uses the current order. A control computes and commits the keyed
removal before bind planning. This control mutates topology before preflight, so
it is not a production correction. It only isolates the order dependency.

The prototype is on branch
`prototype/eta-signal-keyed-bind-invalidation` at commit `96cfde59`. One command
runs it:

```sh
bash .scratch/prototypes/eta-signal-keyed-bind-invalidation/run.sh
```

The command exits with status `0` only when all recorded observations match the
counterexample and the control.

## Exact public scenario

The initial keyed map contains key `1`. Its child bind selects `left` because
`choose` is `true`.

The probe then performs these operations before one stabilization:

1. It sets `choose` to `false`.
2. It removes key `1` from the keyed input.
3. It stabilizes the graph.

The output is the correct empty map in both runs. An output-only assertion
therefore cannot detect the defect.

Repository evidence found no durable test with this exact mixed operation. The
prototype supplies the first executable instance of the complete scenario.

## Observed result

The current run records this topology order:

```text
stage_bind_switch,commit_keyed_removal,commit_bind_switch
```

The control records only `commit_keyed_removal`. Keyed invalidation removes the
nested bind before bind planning can stage a switch.

The first stabilization produces these states:

| Observation | Current order | Keyed-removal-first control |
| --- | --- | --- |
| keyed child scope valid | false | false |
| bind owner valid | false | false |
| committed bind inner | `right` | `left` |
| old bind scope valid | false | false |
| bind scope changed | true | false |
| committed bind scope valid | true | false |
| committed bind parent scope valid | false | false |
| `right` retains bind as a dependent | true | false |
| bind retains `right` as a dependency | true | false |
| invalid dependents on `right` | 1 | 0 |
| keyed plan pending | false | false |
| bind snapshot pending | false | false |

The current transaction completes successfully. It has no pending keyed plan or
bind snapshot, but it publishes invalid topology.

A quiescent stabilization leaves the invalid dependent on `right`. Later churn
also keeps each invalid edge:

| Observation after five total removals | Current order | Control |
| --- | ---: | ---: |
| invalid dependents on `left` | 2 | 0 |
| invalid dependents on `right` | 3 | 0 |
| `total_node_count` | 4 | 4 |
| `dead_node_count` | 15 | 15 |

The two top-scope constants strongly retain five invalid bind owners in the
current run. Each bind snapshot retains a valid provisional scope whose parent
is invalid.

## Diagnostic correction

The independent review says that the invalid edge and node remain visible in
all-node diagnostics. The probe refutes the edge part of that claim.

The public DOT output is identical for the current order and the control. The
bind tombstone records dependencies when keyed invalidation runs. The later
bind commit changes the retained live object, but it does not change that
tombstone. Therefore DOT shows the old `left` edge and does not show the retained
`right` edge.

The live-node registry also removes invalid nodes. As a result,
`total_node_count` stays at `4` while invalid dependents accumulate on the
top-scope signals. `dead_node_count` records invalidation in both runs, so it
does not distinguish valid cleanup from retained topology.

The invalid bind node is visible as a tombstone. The retained post-invalidation
edge is not visible in public DOT or statistics.

## Analysis

N2 reproduces. A pure public graph can finish one successful stabilization with
an invalid bind attached to a valid top-scope signal.

The observed current order matches the static trace. Bind planning stages the
new branch while the keyed child is still committed. Keyed commit then
invalidates the child and the old bind state. Bind commit finally attaches the
new branch to the invalid bind and publishes its snapshot.

The control removes the failure only because keyed invalidation makes the bind
unreachable before bind planning. Its early topology mutation violates the
current preflight boundary. Thus, this control is causal evidence, not a fix.

### Required invalidation-closure invariant

Before topology mutation, one fixed invalidation frontier must include all
keyed removals and staged dynamic operations. A staged operation whose owner is
in that frontier cannot commit.

For this case, discard processing must clear the staged bind snapshot and
invalidate its provisional scope. Commit processing cannot attach an invalid
owner to a valid dependency.

Ticket 09 owns the final transaction model and the internal plan shape. Ticket
16 owns the regression gate. That gate needs direct edge evidence or corrected
diagnostics because output, DOT, and node counts do not discriminate this case.

## Limits

The probe changes private code only on the prototype branch. No prototype hook
is part of the shipped library.

The probe uses pure selectors and observer callbacks. It does not include a
timer, callback failure, or defect. Those combinations belong to the final gate
design in ticket 16.

The four-cycle churn retains one new invalid edge after each observed removal.
It is not a performance measurement or a long-run bound.

## Census rows resolved

Executable reproduction confirms these claim-census rows: `EXE-010`,
`N02-002` through `N02-017`, `N02-019`, `N02-021`, `N02-022`, `N02-024`,
`N02-041`, `S06-002`, `S12-002`, `Q04-001`, and `Q04-002`.

The diagnostic comparison amends `N02-018`. The invalid node appears as a
tombstone, but public diagnostics omit the retained post-invalidation edge.
