# Keyed operator structural laws

Type: grilling
Status: resolved
Blocked by: 07, 08

## Question

Which named executable laws prove the keyed operator's structural identity,
scope, transaction, and incarnation contracts?

Use the applicable structural claims from
[Keyed assoc and stable child identity](../../eta-crux-first-principles/issues/04-keyed-assoc-contract.md).
Do not restate or weaken those claims.

Map each claim to a generated property or an authoritative Eta Signal test.
Cover successful transitions, failed preflight, rollback, removal before
addition, and remove-and-readd before commit.

Each property must observe builder counts, scope incarnations, data-source
identity, structural cleanup order, output bindings, and pending graph work.

Include laws for the directed `data_cutoff` baseline, physical diff before the
cutoff, child-only output changes, and persistent output-root identity. Include
the non-transitive `A`, `B`, and `C` discriminator from ticket 08.

Do not decide application action errors, effect cancellation, or lifecycle-hook
payloads. The Eta Crux tickets named by the map own those decisions.

Effects with no legitimate background work must finish with an empty fiber
census. Register every law-bearing `.mli` claim in the executable-law registry
when implementation starts.

## Answer

### Decision

Use 37 claim-specific generated properties and one broad model-trace property.
Each claim-specific property is the registry evidence for one structural claim.
The broad trace checks interactions and is not a substitute for those
properties.

Name every operator property `keyed_mapi_<claim>`. This follows the map-law
`map_<claim>` convention and names the public `mapi` operation directly.

This ticket specifies future compatibility laws and test requirements. It does
not implement the `eta_signal_map` and `eta_signal` bridge, keyed node, recorder,
model, or tests.

### Independent model and future test seam

Use an independent pure state machine as the oracle. Compare it with the real
Eta Signal graph after each successful stabilization and each completed
rollback.

The model tracks:

- the last committed raw input map
- the data published to each retained child
- committed and provisional keyed entries
- valid and invalid scope incarnations
- the persistent output map
- structural and observer events
- active transaction and pending-work state

The model assigns abstract fresh tokens. Tests compare tokens only for equality
or inequality. They do not require numeric values, ordering, or monotonicity.

A future package-private test recorder exposes opaque tokens and transaction
events to repository tests only. It must not add graph, scope, node,
transaction, or `For_testing` functions to a public CMI.

Each live entry exposes these test identities:

- stored key representative
- keyed scope
- data source
- data signal
- child signal
- dependency edge
- child-local state

The public observation boundary contains output values, output-map roots, and
observer delivery. The private boundary contains entry identities, scope
validity, output-map node identities, and structural transaction events.

Use a deterministic stateful child fixture. It has local state, data-derived
output, and a controllable child-only source. It starts no timers, effects, or
background fibers.

### Common generated-test contract

Each claim-specific property runs 1,000 cases. Generate 1 to 32 keys and 1 to 16
commands before one stabilization. Commands can write several input maps and
child sources before stabilization.

Use literal seed `[| 0xE22; 0x4B4D; n |]`, where `n` is the stable matrix number
below. A custom shrinker must retain the claim's discriminator.

Each property records and checks:

- builder count and keys
- complete entry identity tuples
- data-cutoff arguments and object identities
- `Detached`, `Invalidated`, and `Attached` structural events
- output bindings, output root, and relevant map-node identities
- observer events
- active transaction, staged cells, provisional scopes, dirty nodes, pending
  observer events, and queued cleanup
- the fiber census

After a completed success or rollback, no active transaction, staged cell,
provisional scope, dirty node, pending observer event, or queued cleanup remains.
The fiber census is empty because the fixture starts no background work.

A failure prints the property name, seed, shrunk commands, failpoint, model
state, identity table, builder and cutoff logs, structural events, output maps,
pending work, and fiber census.

### Identity, scope, and final-snapshot properties

| n | Property | Required discriminator and result |
|---:|---|---|
| 1 | `keyed_mapi_addition_builds_one_incarnation` | Add an absent key. The builder runs once and commit attaches one complete fresh entry. |
| 2 | `keyed_mapi_builder_runs_for_additions_only` | One batch contains an addition, retained update, and removal. Only the addition runs the builder. |
| 3 | `keyed_mapi_retained_key_preserves_incarnation` | Keep a key across committed snapshots. Every entry token remains equal. |
| 4 | `keyed_mapi_retained_child_preserves_local_state` | Update retained data after changing child-local state. The state value and state identity remain. |
| 5 | `keyed_mapi_update_publishes_through_existing_source` | Accept a retained data update. The existing source publishes it without rebuilding the child. |
| 6 | `keyed_mapi_child_reads_accepted_data_same_stabilization` | Accept new data and stabilize once. The child output uses the new published data. |
| 7 | `keyed_mapi_continuous_key_preserves_representative` | Supply a comparator-equal fresh key while presence is continuous. The stored representative remains. |
| 8 | `keyed_mapi_removal_invalidates_incarnation` | Commit absence. The scope detaches, invalidates, and remains invalid. |
| 9 | `keyed_mapi_reentry_creates_fresh_incarnation` | Remove, commit, and later re-enter through an equal key. Every incarnation token is fresh. |
| 10 | `keyed_mapi_final_equal_data_preserves_child` | Remove and re-add before commit with final published-equal data. No lifecycle edge or update occurs. |
| 11 | `keyed_mapi_final_unequal_data_updates_child` | Remove and re-add before commit with final unequal data. The existing child receives one update. |
| 12 | `keyed_mapi_final_absence_removes_child` | Write transient values before final absence. Commit removes the existing child once. |
| 13 | `keyed_mapi_same_child_description_isolated_across_keys` | Return one child description for two keys. Each keyed scope creates a distinct child cell. |
| 14 | `keyed_mapi_reused_child_description_shares_within_key_scope` | Reuse one child description twice inside one keyed scope. Both uses share one child cell. |

The old scope token remains invalid after same-key re-entry. These laws do not
deliver actions through old scopes. Action delivery and its error remain owned
by the Eta Crux action protocol.

### Data-cutoff properties

| n | Property | Required discriminator and result |
|---:|---|---|
| 15 | `keyed_mapi_data_cutoff_runs_for_retained_physical_changes_only` | Include addition, removal, shared-object retention, and distinct-object retention. Only the last case calls the cutoff. |
| 16 | `keyed_mapi_default_data_cutoff_uses_physical_identity` | Shared data is suppressed. Distinct data is published even when fields are equal. |
| 17 | `keyed_mapi_data_cutoff_receives_published_then_candidate` | Use distinct labeled boxes. The exact call is `published` first and `candidate` second. |
| 18 | `keyed_mapi_suppressed_data_keeps_published_value` | Return true for a physical change. Raw input advances while child data and output remain published at the old value. |
| 19 | `keyed_mapi_nontransitive_data_cutoff_uses_published_baseline` | Suppress `A` to `B`, then test `C`. Calls are `(A, B)` and `(A, C)`, never `(B, C)`. |
| 20 | `keyed_mapi_data_cutoff_defect_rolls_back_and_retries` | Raise during a retained update. The old snapshot survives and retry calls the predicate again. |
| 21 | `keyed_mapi_same_object_mutation_is_unobservable` | Mutate one shared object between raw snapshots. No physical diff or cutoff call occurs. |

Cutoff tests record exact labeled arguments and object identities. They do not
impose call order across different keys.

### Output properties

| n | Property | Required discriminator and result |
|---:|---|---|
| 22 | `keyed_mapi_addition_sets_output_binding` | One committed addition sets exactly its output binding. |
| 23 | `keyed_mapi_removal_removes_output_binding` | One committed removal removes exactly its output binding. |
| 24 | `keyed_mapi_child_only_change_patches_one_binding` | Change one child source without changing input. Only that output binding changes. |
| 25 | `keyed_mapi_output_patch_retains_unaffected_ancestry` | Use at least 31 bindings and patch an extreme key. A nonempty unaffected subtree keeps identity. |
| 26 | `keyed_mapi_suppressed_update_preserves_output_root` | Suppress retained data with no child change. The output root remains physically equal. |
| 27 | `keyed_mapi_child_noop_preserves_output_root` | Recompute a child to the same published output. The output root remains physically equal. |
| 28 | `keyed_mapi_rollback_preserves_output_root` | Fail and roll back a plan that would change output. The old output root remains. |

Output patch tests inspect private map-node identities only to distinguish a
persistent patch from an `of_list` rebuild. They set no comparison, allocation,
or timing budget.

### Failure and transaction properties

| n | Property | Required discriminator and result |
|---:|---|---|
| 29 | `keyed_mapi_commit_removes_before_additions` | Commit several removals and additions. Each scope detaches before invalidation, and all invalidations precede every attachment. |
| 30 | `keyed_mapi_builder_defect_rolls_back_provisional_addition` | Raise after provisional scope registration. The provisional scope invalidates and no addition commits. |
| 31 | `keyed_mapi_preflight_failure_preserves_committed_snapshot` | Fail preflight after planning removals, updates, and additions. All committed identities and values survive. |
| 32 | `keyed_mapi_rollback_invalidates_provisional_additions` | Roll back several provisional additions. Each provisional scope becomes invalid and never attaches. |
| 33 | `keyed_mapi_rollback_keeps_removal_candidates_live` | Roll back planned removals. Their scopes and complete entry identities remain live. |
| 34 | `keyed_mapi_retry_after_rollback_uses_fresh_provisional_identity` | Retry the unchanged source transition. The builder can run again with fresh provisional identities. |
| 35 | `keyed_mapi_outer_removal_excludes_nested_plan` | Remove an owner while its descendant keyed node has a plan. Exclude that plan and invalidate its provisional scopes. |

There is no ordering contract among removals or among additions. The only
structural order is the per-scope detach-before-invalidate rule and the global
removal-before-addition barrier.

### Combined publication properties

| n | Property | Required discriminator and result |
|---:|---|---|
| 36 | `keyed_mapi_simultaneous_input_and_child_change_publishes_final_output` | Change retained input data and a child-only source before stabilization. Publish one final output containing both changes. |
| 37 | `keyed_mapi_output_observer_publishes_once_after_commit` | A changed output root produces one final event for the test observer. No-op, rollback, and defect cases produce none. |

Planning and intermediate values are not observer-visible.

### Broad model trace

Name the broad property `keyed_mapi_model_trace_matches_runtime`. It is matrix
number 38 and uses seed `[| 0xE22; 0x4B4559; 0x535452 |]`.

Run 1,000 traces with 1 to 128 transitions and 0 to 32 keys. A transition can
contain zero or more input-map writes and child-source writes before one
stabilization. Generated outcomes include success, builder defect, cutoff
defect, preflight failure, and retry.

After each transition, compare the complete model state and observation log
with the runtime. The shrinker preserves the failing outcome and its committed
or provisional discriminator.

### Authoritative generic transaction tests

Register current tests only for the claims they prove:

- `test_preflight_failure_leaves_current_values_unchanged` in
  `test/signal/transaction/test_eta_signal_transaction.ml`
- `test_stage_read_rollback` in
  `test/signal/transaction/test_eta_signal_transaction.ml`
- `test_rollback_transaction_clears_staged_value` in
  `test/signal/stabilization/test_eta_signal_stabilization.ml`
- `test_staged_switch_preflight_uses_owner_for_old_scope` in
  `test/signal/bind/test_eta_signal_bind.ml`

These tests do not yet prove that commit is total after preflight. They also do
not prove complete owner-before-descendant preflight order. When implementation
starts, add generic tests named `test_commit_is_total_after_preflight` and
`test_preflight_orders_owner_before_descendant`. Do not register either claim
before its test exists.

### Registry and scope

When implementation starts, every law-bearing `.mli` source span gets an exact
row in `.scratch/research/dx/e22/review/LAWS.md`. Each row cites one property or
authoritative generic test from this answer. New debt is not an allowed
substitute.

This law set does not decide application action errors, effect cancellation,
lifecycle-hook payloads, or production diagnostics. It does not implement the
Eta Signal Map bridge.
