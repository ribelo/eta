# Eta Signal graph construction compared with Jane Street Incremental

Date: 2026-08-05

## Scope

This report compares static source code only. It covers node creation, static edges, bind scopes, and keyed child graphs.

The Jane Street revisions are:

- `incremental` at `2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6`.
- `incr_map` at `21c6bc602c75d57242b4c3e945da597f82c6280f`.

This report does not compare stabilization or runtime performance. It does not contain benchmark results.

## Result

Eta does more work during graph construction. The largest difference is eager topology allocation and registration.

Jane Street stores static children in the node kind. A constructor creates one node and does not register reverse edges ([state.ml, lines 1421-1447](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1421-L1447)). Reverse edges appear when the node becomes necessary ([state.ml, lines 549-573](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L549-L573)).

Eta stores children in the kind and in topology vectors. Each static edge also has its own record and two slot indexes ([eta_signal_kernel.ml, lines 2501-2509](../../../lib/signal/kernel/eta_signal_kernel.ml#L2501-L2509), [lines 2553-2562](../../../lib/signal/kernel/eta_signal_kernel.ml#L2553-L2562)). `new_signal` registers every edge before it returns ([eta_signal_kernel.ml, lines 3797-3801](../../../lib/signal/kernel/eta_signal_kernel.ml#L3797-L3801), [lines 2134-2154](../../../lib/signal/kernel/eta_signal_kernel.ml#L2134-L2154)).

## Construction comparison

| Area | Eta | Jane Street | Construction effect |
|---|---|---|---|
| Static node | Allocates two topology vectors, a hash table, a staged snapshot, and a lifetime cell ([eta_signal_kernel.ml, lines 3753-3785](../../../lib/signal/kernel/eta_signal_kernel.ml#L3753-L3785)). | Allocates one node. It uses a shared empty parent array and an array sized to the static child count ([node.ml, lines 498-534](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L498-L534)). | Eta has a larger fixed allocation cost for every node, including constants. |
| Static edge | Allocates an edge record. Then it appends that record to both endpoint vectors ([eta_signal_kernel.ml, lines 3273-3306](../../../lib/signal/kernel/eta_signal_kernel.ml#L3273-L3306)). | Stores the child in the node kind. It registers the reverse parent link only after demand reaches the node ([state.ml, lines 563-573](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L563-L573)). | Eta construction is `O(k)` edge work for a node with `k` inputs. Jane construction stores the kind and initializes an array of length `k`. |
| Static constructors | Builds temporary packed dependency lists for `map` through `map9` ([eta_signal_kernel.ml, lines 5737-5775](../../../lib/signal/kernel/eta_signal_kernel.ml#L5737-L5775)). | Passes children directly in the kind constructors ([state.ml, lines 1443-1475](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1443-L1475)). | Eta allocates list cells and existential wrappers before it allocates edges. |
| Bind shell | Creates one bind node and one static edge to the source ([eta_signal_kernel.ml, lines 3936-3947](../../../lib/signal/kernel/eta_signal_kernel.ml#L3936-L3947)). | Creates `lhs_change` and `main`, then connects them through one bind record ([state.ml, lines 1535-1557](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1535-L1557)). | Eta has the smaller bind shell. This is an Eta advantage. |
| Bind scope | Creates a scope only when the selector runs. The scope has an ID, owner, and parent ([eta_signal_kernel.ml, lines 3191-3195](../../../lib/signal/kernel/eta_signal_kernel.ml#L3191-L3195)). | Represents the right-hand scope as `Scope.Bind bind`. Nodes form an intrusive list in the bind record ([scope.ml, lines 37-43](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/scope.ml#L37-L43), [bind.ml, lines 18-23](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/bind.ml#L18-L23)). | Eta allocates a separate scope record. Jane reuses the bind record as the scope identity. |
| Keyed addition | Creates a scope, a `Var`, a watched signal, and the user graph. Then it traverses the output graph for scope validation ([eta_signal_kernel.ml, lines 4745-4761](../../../lib/signal/kernel/eta_signal_kernel.ml#L4745-L4761)). | Creates one Expert data node, adds its input dependency, builds the user graph, and adds one result dependency ([incr_map.ml, lines 826-841](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L826-L841)). | Eta performs more per-key allocation and a validation traversal. |
| Keyed reuse | Keeps the child graph by key. A data change updates the child source and does not call the builder again ([eta_signal_kernel.ml, lines 4780-4800](../../../lib/signal/kernel/eta_signal_kernel.ml#L4780-L4800)). | Keeps the Expert node and child graph by key. A data change marks that node stale ([incr_map.ml, lines 811-816](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L811-L816)). | Both designs reuse keyed child graphs. Their asymptotic expansion work is similar. |

## Speedup opportunities

1. Make empty topology storage allocation-free.

   Each Eta vector starts with an array of four options ([eta_signal_topology.ml, lines 77-83](../../../lib/signal/engine/transaction/eta_signal_topology.ml#L77-L83)). Each signal allocates two such arrays. Use a shared empty array and allocate exact dependency capacity on first use.

2. Remove the per-node dynamic-edge hash table from static-only nodes.

   Every signal creates `Hashtbl.create 4` ([eta_signal_kernel.ml, lines 3762-3765](../../../lib/signal/kernel/eta_signal_kernel.ml#L3762-L3765)). Only dynamic attachment uses the index ([eta_signal_kernel.ml, lines 3273-3299](../../../lib/signal/kernel/eta_signal_kernel.ml#L3273-L3299)). Allocate this index only for `Bind`, `Keyed`, or the first dynamic edge.

3. Add a preallocated static-edge path.

   `create_live_node` reserves all dependency capacity before attachment ([eta_signal_kernel.ml, lines 2143-2149](../../../lib/signal/kernel/eta_signal_kernel.ml#L2143-L2149)). `attach_edge` reserves both vectors again for every edge ([eta_signal_kernel.ml, lines 3290-3292](../../../lib/signal/kernel/eta_signal_kernel.ml#L3290-L3292)). A static helper can append without the repeated reserve calls.

4. Remove temporary dependency lists from fixed-arity constructors.

   Specialized `new_signal1` through `new_signal9` helpers can reserve once and attach direct children. This change removes packed lists while it preserves Eta's eager topology contract.

5. Prototype compact static edges before deferred registration.

   Jane Street proves that static child references do not require eager reverse edges. Eta can first separate static and dynamic edge representations. Full deferred registration changes invalidation and graph-inspection behavior, so it needs a separate design and tests.

6. Reduce keyed addition work only after the static-node fixes.

   Eta's `Var` plus watch pair gives typed updates and scope ownership. Removing it changes the model. A safer first step is a private keyed data-source node that combines those two allocations. The scope-validation traversal is also a candidate for construction-time proof or a cheaper ownership token.

## Priority

The first four changes are local and preserve public behavior. Start with lazy vectors and a lazy dynamic index. Then add fixed-arity construction helpers.

Deferred reverse edges have a larger possible gain. They also change more invariants. Treat that work as a separate prototype.
