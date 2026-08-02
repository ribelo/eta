# Keyed node observability

Type: grilling
Status: resolved
Blocked by: 07, 08

## Question

What minimum diagnostics make keyed reconciliation visible through existing Eta
Signal observability without publishing another expert surface?

Decide which existing stats and DOT views include keyed nodes, scopes, and
structural transitions. Define the counters needed to distinguish full map
scans from changed-key work.

Specify visibility for provisional additions, rolled-back edits, invalidated
scopes, and committed children. Diagnostics must not retain live child state or
change transaction behavior.

Name the tests that prove counter and graph-view behavior. Do not add logging,
action history, or time travel to this package.

## Answer

### Public surface

Use the existing Eta Signal `stats` and `to_dot` functions. Do not add a
`Keyed.stats` function or another diagnostics module.

Add one nested record to the existing statistics result:

```ocaml
type keyed_stats = {
  node_count : int;
  committed_child_count : int;
  reconciliation_count : int;
  input_key_comparison_count : int;
  input_diff_event_count : int;
  child_visit_count : int;
  provisional_addition_count : int;
  committed_addition_count : int;
  committed_removal_count : int;
  reconciliation_rollback_count : int;
}

type stats = {
  (* Existing fields remain here. *)
  keyed : keyed_stats;
}
```

Plain `Eta_signal.Make` graphs return zero for every keyed field. The
`Eta_signal_map.Make` factory reports the fields through the same `stats`
function.

### Counter semantics

`node_count` and `committed_child_count` are current gauges. The node gauge
counts valid live `keyed_mapi` nodes. The child gauge sums their committed
entries. Invalid tombstones do not contribute to either gauge.

The remaining fields are cumulative:

- `reconciliation_count` counts each keyed node plan that starts.
- `input_key_comparison_count` counts key comparisons in input symmetric diff.
- `input_diff_event_count` counts emitted `Added`, `Removed`, and `Changed`
  input events.
- `child_visit_count` counts children selected for output evaluation.
- `provisional_addition_count` counts provisional scopes after registration.
- `committed_addition_count` counts child additions at pure snapshot commit.
- `committed_removal_count` counts child removals at pure snapshot commit.
- `reconciliation_rollback_count` counts keyed plans that complete rollback.

The performance and provisional counters include work from failed attempts.
The commit counters change only after the pure snapshot commits. Thus, an
observer-delivery failure after commit does not erase a committed transition.

These counters distinguish the two linear failure modes. A full input-map scan
has a high `input_key_comparison_count` relative to `input_diff_event_count`. A
full retained-child scan has a high `child_visit_count` relative to affected
input and child events.

All cumulative fields use saturating addition. A diagnostic counter cannot make
stabilization fail or change commit and rollback behavior. The existing
`stats` call returns `Counter_overflow` when a public count has reached
`max_int`.

### DOT views

Keep the existing `dot_options` type. Do not add a keyed-only DOT option.

Every keyed owner node uses `kind=keyed_mapi`. The existing scope selection has
these results:

- `Necessary` includes a keyed node only when an observer demands it.
- `All_valid` includes every retained valid keyed node and committed child.
- `All_including_invalid` also includes entries from the shared bounded
  tombstone index.

With `dot_state=true`, a keyed owner label includes its committed child count.
With `dot_dynamic_scopes=true`, committed child signals include their scope ID,
scope owner, scope parent, and validity. Existing dependency edges connect child
outputs to their keyed owner.

DOT is a stable graph snapshot, not a transition history. Statistics expose
attempted provisional work and rollback. Rolled-back removals and data edits do
not create tombstones because their committed children remain live.

Invalidated provisional signals can appear as tombstones. A provisional scope
that creates no signal leaves no DOT node, but its statistics remain visible.
The shared tombstone limit remains 1,024 entries.

Diagnostics never format or retain key values, data values, child outputs, or
user closures. DOT uses only signal IDs, scope IDs, kinds, counts, state flags,
and graph edges. This rule needs no key printer in `Map.Ordered_type`.

Both diagnostic functions keep their existing graph-lane serialization. A read
observes a stable committed or rolled-back state. A read cannot observe an
in-progress provisional graph.

### Executable tests

Add these named tests with the implementation:

| Test | Required discriminator |
|---|---|
| `test_keyed_stats_zero_without_keyed_nodes` | Read a plain Eta Signal graph and an unused Eta Signal Map graph. Every keyed field is zero. |
| `test_keyed_stats_live_gauges_follow_committed_state` | Commit additions and removals. The node and child gauges equal the live keyed graph after each commit. |
| `test_keyed_stats_report_shared_and_independent_diff_work` | Use 1,023 keys and one edit. Shared ancestry reports change-proportional comparisons, while an independent rebuild reports linear comparisons. Both report the same diff event. |
| `test_keyed_stats_report_affected_child_visits` | Notify three children in a 1,023-child node without an input edit. The child-visit delta is exactly three. |
| `test_keyed_stats_count_failed_attempt_and_rollback` | Trigger builder, cutoff, and preflight failures. Attempt and rollback counters increase, while commit counters and live gauges stay unchanged. |
| `test_keyed_stats_commit_transitions_only_after_commit` | Inspect counters before commit, after commit, and after a post-commit callback failure. Additions and removals appear only in committed snapshots. |
| `test_keyed_stats_saturation_does_not_change_transaction` | Target each cumulative field with the private overflow harness. Stabilization behavior stays unchanged, and `stats` reports `Counter_overflow`. |
| `test_keyed_dot_scope_selection_shows_keyed_nodes` | Compare all three `dot_scope` values across necessity, disposal, and invalidation. Each view includes exactly its selected keyed nodes. |
| `test_keyed_dot_dynamic_scopes_show_committed_children` | Enable state and dynamic-scope metadata. Each committed child has the keyed owner and valid scope metadata. |
| `test_keyed_dot_invalid_tombstones_are_bounded_and_value_free` | Create more than 1,024 invalidations with sentinel key and data text. The dump stays bounded and contains no sentinel text. |
| `test_keyed_diagnostics_are_read_only` | Insert `stats` and `to_dot` reads between equivalent transitions. Outputs, identities, counters, rollback results, and pending work remain equal. |

The production benchmark from ticket 11 remains the asymptotic gate. These
tests prove that production diagnostics report the work that the gate measures.

Keep the existing generic Eta Signal diagnostics tests as authoritative coverage
for scope selection, read-only behavior, metadata flags, and bounded tombstones.
Every new law-bearing `.mli` claim must have an exact law-registry row in the
same implementation change. New documentation debt is not permitted.

### Exclusions

Do not add key printers, per-key counters, event journals, logs, action history,
time travel, or a diagnostics subscription. Diagnostics must not retain live
child state or add dependency edges.
