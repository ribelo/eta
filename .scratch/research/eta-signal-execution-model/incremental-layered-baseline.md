# Incremental layered baseline

Date: 2026-08-05

## Scope

This report answers the
[Incremental layered baseline](../../../docs/wayfinder/eta-signal-execution-model/issues/02-incremental-layered-baseline.md)
ticket. It uses the exact installed source for
`incremental.v0.18~preview.130.91+190`.

The source archive has this revision and checksum:

- Incremental revision: `31eb755facdfcaaf4ccbae55dffd829f7c7278f9`
- Incremental SHA-256: `877c7ea4d71e1bdbe1df29af728e7746aa638f21c54171c9cdddfd20c860f15d`
- Incr_map revision: `07e7d3ca75fe1aa855595cf617fd205f9d419653`
- Incr_map SHA-256: `3c68e7b3cd1258abf1a0b62c51da95b7652b0ef5380d5e94e7170956d2624d0d`

The local Incremental source root was:

```text
/home/ribelo/.cache/opam/5.2.0+ox/.opam-switch/sources/incremental.v0.18~preview.130.91+190
```

The matched workloads are in
[`bench/signal_compare/compare.ml`](../../../bench/signal_compare/compare.ml).
The report does not change that file.

## Result

Incremental separates graph demand, stale-node scheduling, value propagation,
and observer delivery. The steady static path mutates retained records and
arrays. The raw path does not allocate after warm-up.

The matched harness adds one no-op observer-update handler. A changed output
allocates six words for this handler path. These six words are not propagation
cost.

The matched dynamic workload creates a new constant node for each selector
change. Its raw dynamic-topology cost is 43 words. The handler increases this
cost to 49 words.

Incr_map retains the graph for all unchanged keys. Its steady changes still
allocate persistent Core maps. Membership additions also allocate a new child
graph.

## Matched workload boundary

Each Incremental workload performs `Var.set`, then `stabilize`
([changed workload, lines 82-101](../../../bench/signal_compare/compare.ml#L82-L101)).
The cutoff and dynamic workloads use the same operation boundary
([lines 151-171](../../../bench/signal_compare/compare.ml#L151-L171),
[lines 219-237](../../../bench/signal_compare/compare.ml#L219-L237)).

The harness observes the output and installs `fun _ -> ()` before warm-up
([lines 89-93](../../../bench/signal_compare/compare.ml#L89-L93)).
It reads the observer after the measured loop, not after each operation
([lines 95-102](../../../bench/signal_compare/compare.ml#L95-L102)).

The Incr_map workloads also allocate the next persistent input map inside the
operation. Thus their numbers include Core Map cost
([data lines 296-318](../../../bench/signal_compare/compare.ml#L296-L318),
[membership lines 379-404](../../../bench/signal_compare/compare.ml#L379-L404)).

## Hot path

### Variable mutation

`Var.t` retains the current value, a delayed value, the last set cycle, and its
watch node
([`src/var.ml`, lines 5-18](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/var.ml#L5-L18)).

`set_var_while_not_stabilizing` writes the value and `set_at`. It adds the watch
node to the recompute heap only once per cycle
([`src/state.ml`, lines 1276-1286](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1276-L1286)).

`set_var` delays a set that occurs during stabilization. The state retains a
stack and each variable retains the last delayed value
([`src/state.ml`, lines 1289-1301](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1289-L1301)).

### Demand and necessity

An observer first enters `new_observers`. The next stabilization links it into
the state and the observed node
([`src/state.ml`, lines 1179-1194](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1179-L1194),
[lines 1208-1241](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1208-L1241)).

A node is necessary when it has a parent, an observer, a freeze requirement, or
a temporary force flag
([`src/types.ml`, lines 482-490](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/types.ml#L482-L490)).

When demand reaches a node, `became_necessary` installs reverse parent links.
It also computes heights and schedules stale nodes
([`src/state.ml`, lines 549-582](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L549-L582)).

When demand leaves, `became_unnecessary` removes child links and pending heap
membership
([`src/state.ml`, lines 361-387](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L361-L387)).

### Recompute scheduling

The recompute heap is an array indexed by node height. Nodes contain intrusive
previous and next links
([`src/recompute_heap.ml`, lines 20-25](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/recompute_heap.ml#L20-L25),
[lines 98-130](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/recompute_heap.ml#L98-L130)).

`stabilize` drains this retained heap in topological order. It then runs the
observer phase
([`src/state.ml`, lines 1371-1381](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1371-L1381)).

A changed node normally schedules its parents. A unary parent can run
immediately when its scope is stable
([`src/state.ml`, lines 1002-1039](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1002-L1039),
[lines 1053-1118](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1053-L1118)).

This immediate path explains the static chain result. The source watch leaves
the heap, and each unary map calls the next map directly.

### Unary map and cutoff

`map` creates one node whose kind contains the function and child
([`src/state.ml`, lines 1421-1447](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1421-L1447)).

Recompute reads the retained child value and calls the map function
([`src/state.ml`, line 767](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L767)).
The matched integer addition returns an immediate integer.

`maybe_change_value` applies the node cutoff before it writes the value. It
schedules parents only when the value passes the cutoff
([`src/state.ml`, lines 984-1003](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L984-L1003)).

The default cutoff is specialized physical equality
([`src/cutoff.ml`, lines 4-12](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/cutoff.ml#L4-L12),
[lines 30-37](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/cutoff.ml#L30-L37)).
The cutoff workload maps every source value to the immediate integer zero.
Propagation therefore stops at that map.

### Dynamic bind topology

`bind` retains one bind record and two nodes. The record holds the left node,
current right node, right scope, and right-scope node list
([`src/bind.ml`, lines 8-24](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/bind.ml#L8-L24),
[`src/state.ml`, lines 1535-1557](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1535-L1557)).

When the left value changes, Incremental runs the function in the right scope.
It replaces the main node child and invalidates the old right-scope nodes
([`src/state.ml`, lines 687-728](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L687-L728)).

The scope adds each new right node to an intrusive list in the bind record
([`src/scope.ml`, lines 37-43](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/scope.ml#L37-L43)).
The matched function calls `Incr.return` each time
([harness lines 221-225](../../../bench/signal_compare/compare.ml#L221-L225)).
It does not reuse the two possible constant nodes.

### Observer updates and the six words

Changed nodes with handlers retain the old value and enter
`handle_after_stabilization`
([`src/state.ml`, lines 995-1001](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L995-L1001)).

The observer phase creates `Changed (old_value, new_value)`. It then packages
the node and update for the second handler pass
([`src/state.ml`, lines 1337-1359](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1337-L1359)).

`Changed` is one three-word block. `Run_on_update_handlers.T` is another
three-word block
([`src/on_update_handler.ml`, lines 14-20](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/on_update_handler.ml#L14-L20),
[`src/state.ml`, lines 20-22](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L20-L22)).
These two blocks are the observed six words.

The two handler stacks retain their backing arrays. Push and pop do not allocate
after the first resize
(`/home/ribelo/.cache/opam/5.2.0+ox/lib/base/stack.ml`, lines 117-139).

### Incr_map

`mapi'` retains three maps: the prior input, per-key nodes, and the result
accumulator
([`incr_map.ml`, lines 754-777](https://github.com/janestreet/incr_map/blob/07e7d3ca75fe1aa855595cf617fd205f9d419653/src/incr_map.ml#L754-L777)).

An input change folds the symmetric difference. A data change marks one
per-key Expert node stale
([`incr_map.ml`, lines 793-817](https://github.com/janestreet/incr_map/blob/07e7d3ca75fe1aa855595cf617fd205f9d419653/src/incr_map.ml#L793-L817)).

A removal deletes one dependency, removes one result entry, and invalidates one
node. An addition creates the per-key node and user dependency
([`incr_map.ml`, lines 818-842](https://github.com/janestreet/incr_map/blob/07e7d3ca75fe1aa855595cf617fd205f9d419653/src/incr_map.ml#L818-L842)).

Expert nodes retain a growable child array and stale flags
([`src/expert.ml`, lines 19-39](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/expert.ml#L19-L39)).
Expert edge callbacks update only the affected result key
([`src/expert.ml`, lines 145-179](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/expert.ml#L145-L179)).

The remaining steady allocation comes from persistent Core Map updates and
symmetric-difference traversal. It is not scheduler allocation.

### Time

No matched workload creates an Incremental clock or time node. Timer work is
outside all measured Incremental rows.

The timer path is explicit. `at` installs one timing-wheel alarm
([`src/state.ml`, lines 1770-1779](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1770-L1779)).
`advance_clock` advances the wheel, drains fired alarms, and marks only their
nodes stale
([`src/state.ml`, lines 1857-1891](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/state.ml#L1857-L1891)).

Thus a timer-free raw Eta kernel baseline must not scan timer state. A separate
timer layer must measure alarm insertion, clock advance, and fired-node
propagation.

## Retained state that removes steady allocation

The following state exists before the measured static loop:

1. Each node retains its value, cutoff, change cycles, height, and heap links.
2. Each node retains one parent directly and more parents in a growable array.
3. Each node retains arrays that map child and parent indexes.
4. The state retains the height-indexed recompute array.
5. The state retains growable stacks for observer and delayed-set phases.
6. The observer retains intrusive links to the state and observed node.
7. A bind retains its current right node, scope, and right-scope node list.
8. Incr_map retains its prior map, key-node map, result map, Expert nodes, and dependencies.

The main node representation is in
[`src/node.ml`, lines 8-99](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/node.ml#L8-L99).
Node creation initializes the retained arrays and links
([`src/node.ml`, lines 498-537](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/node.ml#L498-L537)).

## Measurements

The repository build used the required OxCaml Nix shell:

```sh
XDG_CACHE_HOME=/tmp/eta-incremental-nix-cache \
  nix develop -c dune build \
  --root "$PWD" \
  --build-dir /tmp/eta-signal-incremental-build \
  --profile release \
  bench/signal_compare/compare.exe
```

Each workload then ran in a pinned process:

```sh
taskset -c 2 \
  /tmp/eta-signal-incremental-build/default/bench/signal_compare/compare.exe \
  --only NAME --samples 1
```

The measured results were:

| Workload | Operations | ns/op | words/op |
|---|---:|---:|---:|
| `incremental.changed.depth_1` | 16,777,216 | 51.69 | 6.000001 |
| `incremental.changed.depth_10` | 4,194,304 | 121.97 | 6.000002 |
| `incremental.changed.depth_100` | 524,288 | 1,005.91 | 6.000019 |
| `incremental.cutoff.depth_10` | 16,777,216 | 32.13 | 0.000001 |
| `incremental.dynamic.switch` | 4,194,304 | 139.19 | 49.000002 |
| `incr_map.data_change.10000` | 2,097,152 | 316.53 | 186.000005 |
| `incr_map.data_change.100000` | 2,097,152 | 344.68 | 234.000005 |
| `incr_map.membership_change.10000` | 1,048,576 | 484.27 | 349.500010 |
| `incr_map.membership_change.100000` | 1,048,576 | 564.28 | 439.500010 |
| `incr_map.child_change.10000` | 8,388,608 | 115.83 | 84.000001 |
| `incr_map.child_change.100000` | 4,194,304 | 126.60 | 108.000002 |

The small fractional excess is the fixed measurement cost divided by the
operation count.

### Allocation probes

A throwaway probe used `Core.Gc.allocated_words`. It ran 1,000,000 operations
after graph warm-up.

```text
static.no_handler 0.000000
static.handler 6.000003
dynamic.cached.no_handler 10.000000
dynamic.cached.handler 16.000000
dynamic.fresh.no_handler 43.000000
dynamic.fresh.handler 49.000000
```

The cached dynamic case returned two prebuilt constants. The fresh case matched
the benchmark and called `Incr.return` for each change.

A second probe used `Core.Gc.For_testing.measure_and_log_allocation` for one
fresh dynamic change. Without a handler, it reported these blocks:

```text
43 words: 2, 2, 29, 5, 5
```

The two five-word blocks remain in the cached dynamic case. They belong to the
bind recompute call path. The 2, 2, and 29-word blocks create the new constant
node and its retained node data.

With the no-op handler, the same probe reported:

```text
49 words: 2, 2, 29, 5, 5, 3, 3
```

The last two blocks match `Changed` and
`Run_on_update_handlers.T`. This result identifies all six observed words.

## Layered raw-kernel baseline

Later Eta prototypes must report these layers separately.

### Layer K0: raw static kernel

K0 contains source mutation, demand-limited scheduling, recompute, cutoff, and
cached-value publication. One retained demand token keeps the graph necessary.
K0 has no update callback and no observer read inside the operation.

The matched Incremental K0 allocation baselines are:

| Workload | Raw words/op |
|---|---:|
| changed depth 1, 10, or 100 | 0 |
| cutoff depth 10 | 0 |

Wall time must use the existing matched operation. Allocation comparisons must
remove the six-word observer delivery cost.

### Layer K1: raw dynamic topology

K1 adds bind scope execution, edge replacement, and old-right invalidation. It
still excludes delivery.

The matched workload creates a fresh constant. Its Incremental K1 baseline is
43 words per switch. A cached-constant variant is a separate diagnostic at 10
words per switch.

The cached variant must not replace the matched workload. It answers a topology
reuse question only.

### Layer K2: raw keyed kernel

K2 includes the persistent input map because the frozen workload creates that
map inside each operation. It includes symmetric-difference and result-map
cost. It excludes observer delivery.

Subtract six words from each changed Incr_map row:

| Workload | Raw words/op |
|---|---:|
| data change 10,000 | 180 |
| data change 100,000 | 228 |
| membership change 10,000 | 343.5 |
| membership change 100,000 | 433.5 |
| child change 10,000 | 78 |
| child change 100,000 | 102 |

The membership workload alternates addition and removal. Its value is the mean
cost of those two operations.

### Layer D: delivery

Layer D adds observer update packaging and callback execution. The matched
Incremental delivery cost is six words for each changed output.

A cutoff that stops the output has zero delivery cost. Observer reads remain
outside the measured operation.

### Layer A: Eta adapters

Each Eta prototype must run K0, K1, or K2 without `Eta.Effect`, `Eta.Runtime`,
or Eio. Then add each adapter around the same kernel operation.

Report these rows:

1. Raw kernel only.
2. Raw kernel plus the Signal observer-delivery adapter.
3. Raw kernel plus the Eta Effect interpreter.
4. Raw kernel plus the Eio runtime adapter.
5. The complete public Signal operation.

The layers must use the same graph, mutation, stabilization count, cutoff, and
output check. This structure prevents adapter allocation from becoming kernel
allocation.

## Uncertainty

The allocation logger gives block sizes, not source labels. Source structure
and the cached-node probe identify the dynamic blocks, but no compiler IR was
inspected.

Wall time is one pinned sample per workload. These values define the measured
environment, not a stable cross-machine time gate.
