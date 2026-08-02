# Executable map laws

Type: grilling
Status: resolved
Blocked by: 05, 06

## Question

Which named executable laws define `Eta_signal_map.Map`?

Specify one property or registered test for each law-bearing public claim. Cover
ordering, uniqueness, lookup after edits, persistence, ancestry preservation,
diff ordering, diff completeness, and forward and reverse reconstruction.

Also cover duplicate rejection, stable key representatives, physical no-op
identity, extensional equality without physical shortcuts, physical-only
`Changed`, and conditional ancestry retention through `map` and `filter_mapi`.

Separate semantic laws from performance observations. A semantic law must hold
for independently built maps. An ancestry-performance claim uses the benchmark
ticket instead.

For each generated property, state:

- the generated map and edit class
- the observation boundary
- the discriminating case
- the printed counterexample

Name the rewritten Base scenarios that remain fixed regression tests. Do not
copy Base test code.

Record every new `.mli` claim and named test in
`.scratch/research/dx/e22/review/LAWS.md` when implementation starts. New prose
cannot use an uncovered placeholder.

## Answer

### Decision

Use one stable, descriptive test name for each law-bearing claim. Do not use a
single state-machine test as evidence for the complete interface. Shared
generators and reference-model helpers are allowed.

Put generated public-semantic laws in
`test/laws/map_semantic_properties.ml`. Put private representation laws in
`test/laws/map_representation_properties.ml`. Put fixed regressions and compiler
checks under `test/signal_map/`.

Semantic laws must pass for maps with shared ancestry and for independently
built maps. Comparison counts, allocation counts, and timing are not semantic
observations. The benchmark ticket owns those observations.

### Reference model and generated values

Use `Stdlib.Map` as the extensional reference model. Key the reference map by an
integer rank. Store the selected key representative and data object in each
reference entry. This side data models Eta's representative rule without using
a second tree implementation.

Generate boxed keys with separate rank and identity fields. The ordered module
compares only ranks. Generate boxed data with separate value and identity
fields. Some data boxes contain mutable fields. These boxes distinguish:

- comparator-equal keys with different representatives
- physically identical data
- distinct data with equal fields
- distinct data with different fields

Semantic properties generate maps with 0 to 128 bindings and traces with 1 to
256 edits. Each semantic property runs 2,000 cases. Representation properties
generate maps with 0 to 255 bindings and traces with 1 to 512 edits. Each
representation property runs 1,000 cases.

Each property stores a literal seed beside its declaration. Use seed
`[| 0xE22; 0x4D4150; n |]`, where `n` is the stable matrix number below. Run
each property through a one-test QCheck runner with that seed. Reordering or
renaming another test must not change its cases.

Use claim-specific generators. Do not rely on random filtering to reach a
required branch. A custom shrinker must retain the property's discriminator.
For example, it must retain a duplicate occurrence, an identity distinction,
or the required ancestry relation.

Every generated failure prints the property name, literal seed, generated
class, shrunk counterexample, subject observation, and oracle observation. It
also prints identity tags and diff events when they apply. The `Print` column
below lists the property-specific part of that report.

### Public semantic properties

The observation boundary for this table is the public `Map.S` interface. A
whole-map physical comparison with `( == )` is also public observation.

| n | Property | Generated class and discriminator | Observation | Print |
|---:|---|---|---|---|
| 1 | `map_empty_is_empty` | An empty map and arbitrary probe keys. | `is_empty`, `cardinal`, `mem`, `find_opt`, and `to_list` all report empty. | Probe keys and all query results. |
| 2 | `map_singleton_contains_binding` | One key and data box, one comparator-equal probe, and one different probe. | Queries and `to_list` report exactly the supplied binding. | Supplied boxes, probes, and observations. |
| 3 | `map_of_list_matches_unique_bindings` | A shuffled list with unique ranks. Nonempty cases are constructed directly. | Successful output equals the ordered reference bindings. Empty input returns `empty`. | Input order, sorted oracle, and result. |
| 4 | `map_of_list_rejects_first_duplicate` | A list with an early duplicate occurrence and a later duplicate distractor. | The result is `Duplicate_key` with the exact early duplicate object. | Indexed input and expected and actual representative identities. |
| 5 | `map_keys_are_unique_by_compare` | An edit trace uses several representatives for the same ranks. | Cardinality and ordered keys contain one binding for each rank. | Trace, representatives, and final bindings. |
| 6 | `map_lookup_matches_edit_trace` | A trace contains present and absent `set`, `remove`, and `update` branches. | After every edit, all public queries match the reference map. | Shrunk trace, step index, probe, and both states. |
| 7 | `map_edits_are_persistent` | Save a snapshot, then run a nonempty edit suffix that changes the current map. | The saved snapshot stays equal to its saved reference state. | Prefix, suffix, saved state, and current state. |
| 8 | `map_set_retains_key_representative` | Set data through a fresh key that compares equal to a stored key. | The data changes and the stored key object remains the original object. | Original key, supplied key, and resulting binding identities. |
| 9 | `map_reinsert_uses_new_key_representative` | Remove a stored key, then insert through a fresh equal key. | The new binding contains the fresh key object. | Removed and inserted identities and final binding. |
| 10 | `map_physical_noop_preserves_root` | Each case performs same-object `set`, absent `remove`, present same-object `update`, and absent-to-absent `update`. | Every operation returns the same physical map root. | Operation, keys, data identities, and root identities. |
| 11 | `map_ordered_observations_match_oracle` | A shuffled unique map with at least two ranks. | `fold` and `to_list` visit each binding once in increasing rank order. | Construction order, fold log, list, and oracle order. |
| 12 | `map_map_matches_oracle` | A map and a function that returns generated output boxes. | Output keys and data match the pointwise reference transform. | Input, function table, expected output, and actual output. |
| 13 | `map_filter_mapi_matches_oracle` | A map and a function table with guaranteed keep and drop branches. | Output matches the filtered pointwise reference transform. | Input, decisions, expected output, and actual output. |
| 14 | `map_equal_is_extensional` | Independently built pairs cover equal maps, key mismatch, and accepted or rejected data pairs. | The Boolean result matches extensional reference equality. | Both construction traces, callback table, and result. |
| 15 | `map_equal_checks_all_aligned_data` | Equal key sets include a physically shared root and shared subtrees. The callback always accepts. | The callback receives every aligned pair exactly once. | Both maps and the callback identity log. |
| 16 | `map_equal_stops_after_rejection` | Equal key sets contain one tagged pair that the callback rejects. | Call order is not constrained. No callback occurs after the first rejection. | Rejecting pair, complete callback log, and result. |
| 17 | `map_diff_events_are_ordered_unique` | Related and independent pairs contain `Left`, `Right`, and `Changed` events. | Events have strictly increasing ranks and no duplicate rank. | Both maps and the ordered event log. |
| 18 | `map_diff_reports_physical_changes_only` | Aligned pairs include one shared object, one mutated shared object, one distinct equal object, and one distinct unequal object. | Shared objects produce no event. Both distinct-object cases produce `Changed`. | Object identities, field values, mutations, and events. |
| 19 | `map_diff_uses_map_representatives` | The maps use different representatives for comparator-equal ranks. | `Left` and `Changed` use first-map keys. `Right` uses second-map keys. | Both key identities and every event-key identity. |
| 20 | `map_diff_reconstructs_forward` | Each case contains one related pair and one independently built pair. | Applying events to the first map reconstructs the second map extensionally. | Source, target, events, and reconstructed map. |
| 21 | `map_diff_reconstructs_reverse` | Each case contains one related pair and one independently built pair. | Reversing events and applying them to the second map reconstructs the first map extensionally. | Source, target, reversed events, and reconstructed map. |
| 22 | `map_diff_handles_independent_maps` | Separate construction traces build both maps without shared nonempty nodes. Nonempty differences are guaranteed. | The complete event list matches an independent reference symmetric diff. | Both traces, expected events, and actual events. |

The equality callback order is unspecified. An accepting callback runs once for
every aligned pair. After a callback rejects a pair, `equal` makes no further
data calls.

Physical identity is the complete diff boundary. Mutating a shared data object
does not create a `Changed` event. A distinct object creates `Changed`, even if
its fields are equal.

### Private representation properties

The private tests use a non-public map-kernel test library. That library exposes
invariant checks and node identity inventories only to repository tests. Do not
add `For_testing`, node, root, height, or sharing functions to public `Map.S`.

| n | Property | Generated class and discriminator | Observation | Print |
|---:|---|---|---|---|
| 23 | `map_kernel_invariants_survive_edits` | A trace guarantees insertion, replacement, removal, and update branches. | After every step, ordering, unique ranks, cached sizes, and `(5/2, 3/2)` balance hold. Empty has no root. | Trace, failing step, tree shape, and invariant failure. |
| 24 | `map_edits_retain_unchanged_subtrees` | Construct edit sites with a nonempty sibling subtree for `set`, `remove`, and `update`. | Unchanged sibling nodes retain their physical identities. | Edit, before and after trees, and node identity sets. |
| 25 | `map_map_preserves_noop_root` | Every mapped output is the original data object. | The transformed map has the same physical root. | Input tree and before and after root identities. |
| 26 | `map_map_retains_unchanged_nodes` | Some output boxes stay identical and others change. Unchanged children are guaranteed. | Every node that meets the retention condition keeps its identity. | Function table and retained, rebuilt, missing, and extra node sets. |
| 27 | `map_filter_mapi_preserves_noop_root` | Every binding is kept with its original data object. | The transformed map has the same physical root. | Input tree and before and after root identities. |
| 28 | `map_filter_mapi_retains_unchanged_nodes` | Guaranteed keep, change, and drop regions leave at least one unchanged subtree. | Every node that meets the retention condition keeps its identity. | Decision table and retained, rebuilt, missing, and extra node sets. |
| 29 | `map_singleton_starts_fresh_ancestry` | Build two singleton maps from the same key and data objects. | Each map has one node, and the two nodes are physically distinct. | Bindings, root identities, and node inventories. |
| 30 | `map_of_list_severs_ancestry` | Convert a nonempty map to a list and build a new map from that list. | The maps are extensionally equal and share no tree nodes. | Source tree, list, rebuilt tree, and shared node set. |

These tests prove representation semantics only. They do not set comparison or
allocation budgets.

### Fixed clean-room regressions

Rewrite these six behavioral scenarios without copying Base test code:

1. `map_diff_empty`
2. `map_diff_left_only`
3. `map_diff_right_only`
4. `map_diff_physical_same`
5. `map_diff_physical_changed`
6. `map_diff_mixed_ordered`

The reviewed behavioral oracle is Base from `avsm/oxmono` at revision
`4e3b745fb95d66fa0e13601d7fa7aeaed7962043`.

Register these compiler tests too:

1. `map_same_order_applications_unify`
2. `map_different_order_applications_reject`

Do not add compiler tests for every operation that V1 intentionally omits.

### Law registry

When implementation starts, each public law-bearing source span gets one row in
`.scratch/research/dx/e22/review/LAWS.md`. Cite the exact property or registered
test from this answer. Representation rows cite the private property and its
test-only observation boundary.

No new prose can use debt or a placeholder instead of one of these tests.

### Deferred

The benchmark ticket owns change-proportional work and timing. The keyed
operator law ticket owns signal-child identity, lifecycle, cutoff, and output
patch laws. This ticket does not implement the map or its tests.
