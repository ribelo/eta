---
kind: requirement
tags: [eta_signal_map, map, keyed, transaction, diagnostics, performance]
refines: ["[[docs/requirements/eta-signal-map/README]]"]
depends_on: ["[[docs/requirements/eta-signal/keyed-extension]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Keyed incremental map

## Intent

Eta Signal Map provides one persistent ordered map and one keyed signal
operator. The map preserves unchanged tree identity across persistent edits.

The keyed operator preserves one child incarnation while its key stays present.
It applies map changes and child changes in one graph transaction.

## Map requirements

- The map kernel shall use an immutable weight-balanced binary tree with cached subtree sizes. ^smmap-iyx7
- When a map operation returns, the tree shall preserve key order, unique keys, correct sizes, and the `(5/2, 3/2)` balance bounds. ^smmap-t9g9
- The `Map.Make` functor shall use only `Ordered_type.compare` to order keys. ^smmap-91wp
- When `Ordered_type.compare` returns zero, the map shall treat the two keys as one key identity. ^smmap-zdxg
- The `empty` value shall contain no bindings and no tree node. ^smmap-eg8v
- The `singleton` function shall return one fresh binding with the supplied key and data. ^smmap-4sla
- When `of_list` receives unique keys, the map shall return all bindings in key order. ^smmap-dq75
- If `of_list` receives duplicate keys, then the map shall return the first duplicate occurrence and its exact key value. ^smmap-cffd
- If `of_list` receives duplicate keys, then the map shall return no partial map. ^smmap-ikdi
- The map shall make `is_empty`, `cardinal`, `mem`, and `find_opt` agree with its current bindings. ^smmap-or8f
- When `set` receives an absent key, the map shall add the supplied key and data. ^smmap-bxwh
- When `set` receives a present key, the map shall retain the stored key representative and replace only its data. ^smmap-nn25
- When `remove` receives a present key, the map shall remove its binding. ^smmap-8a76
- When a removed key enters again, the map shall store the new supplied key representative. ^smmap-e4r1
- When `update` changes a key option, the map shall apply the matching insertion, replacement, removal, or absence result. ^smmap-z7kg
- The `fold` function shall visit each binding once in increasing key order. ^smmap-qm48
- The `to_list` function shall return each binding once in increasing key order. ^smmap-b81w
- The `map` function shall preserve keys and apply its function once to each data value. ^smmap-i14t
- The `filter_mapi` function shall apply its function once to each binding and retain each returned value. ^smmap-g2tz
- The `equal` function shall compare maps by key identity and the supplied data predicate. ^smmap-tz92
- When aligned key sets are equal and the predicate accepts, `equal` shall call the predicate once for every aligned pair. ^smmap-aouh
- When the data predicate rejects one pair, `equal` shall make no later data-predicate call. ^smmap-ge5r
- When a caller edits a map, each earlier snapshot shall keep its original bindings. ^smmap-2sy9
- When `set`, `remove`, or `update` makes a physical no-op, the operation shall return the same map root. ^smmap-hht7
- When `map` or `filter_mapi` makes a physical no-op, the operation shall return the same map root. ^smmap-86dk
- When a transform changes part of a map, it shall retain each node whose key, data, and children stay physically unchanged. ^smmap-2yd7
- When an edit changes one map region, the map shall retain physically unchanged sibling subtrees. ^smmap-inyq
- The `Map.Make` functor shall produce compatible map types for two applications to the same ordered-module path. ^smmap-e04b
- The `Map.Make` functor shall produce incompatible map types for applications to different ordered-module paths. ^smmap-4d3u
- The public map interface shall not expose roots, nodes, heights, balance data, ancestry inventories, or test-only functions. ^smmap-jtck
- The V1 map interface shall contain only the operations declared by `Eta_signal_map.Map.S`. ^smmap-mo45

## Symmetric-diff requirements

- The `fold_symmetric_diff` function shall use physical data identity as its complete aligned-data change rule. ^smdiff-ij95
- When aligned maps contain the same physical data object, `fold_symmetric_diff` shall emit no event for that key. ^smdiff-uoix
- When aligned maps contain distinct data objects, `fold_symmetric_diff` shall emit `Changed` even when their fields are equal. ^smdiff-mwo3
- The symmetric diff shall report first-only data as `Left`, second-only data as `Right`, and aligned changed data as `Changed`. ^smdiff-8cdy
- The symmetric diff shall emit at most one event per key in increasing key order. ^smdiff-zuwx
- The symmetric diff shall use first-map keys for `Left` and `Changed`, and second-map keys for `Right`. ^smdiff-yhgb
- The symmetric diff shall report every addition, removal, and physical data change between its input maps. ^smdiff-g1jq
- The forward symmetric-diff event sequence shall reconstruct the second map from the first map extensionally. ^smdiff-5d9x
- The reversed symmetric-diff event sequence shall reconstruct the first map from the second map extensionally. ^smdiff-4nzq
- When maps have independent ancestry, the symmetric diff shall remain complete and ordered. ^smdiff-fjnq
- When maps share a physical subtree, the symmetric diff shall skip that complete subtree. ^smdiff-i641
- The `singleton` and nonempty `of_list` constructors shall create fresh ancestry without a node from another map. ^smdiff-91zh

## Keyed-operator requirements

- The `Eta_signal_map.Make` factory shall publish one keyed operator named `Keyed(Order).mapi`. ^smkey-r5ns
- The `mapi` function shall take its input signal before `~f` and use the direct `Map.Make(Order).t` path. ^smkey-suok
- The `Keyed(Order)` module shall not expose a map alias, nested map module, diff adapter, or aggregate output predicate. ^smkey-g09a
- When `data_cutoff` is absent, `mapi` shall suppress a retained update only when published and candidate data are physically identical. ^smkey-c4jn
- The keyed node shall call `data_cutoff` only for a retained key with a physical `Changed` event. ^smkey-xj6g
- When `data_cutoff` returns true, the keyed node shall keep the currently published data. ^smkey-jdgk
- When `data_cutoff` returns false, the keyed node shall publish the candidate through the existing data source. ^smkey-4ddk
- When the keyed node calls `data_cutoff`, it shall pass the published value before the candidate value. ^smkey-z4eu
- When an update is suppressed, the next cutoff call shall compare the next candidate with the last published data. ^smkey-8g9u
- If `data_cutoff` raises, then the keyed node shall roll back the plan and retry the predicate during a later stabilization. ^smkey-b4zb
- When a key enters, the builder shall receive its constant stored key and one stable data signal. ^smkey-9b8i
- The keyed node shall run the builder only for provisional additions. ^smkey-445b
- While a key stays present, the keyed node shall preserve its representative, scope, source, data signal, child signal, edge, and child state. ^smkey-69cw
- When retained data is accepted, the child shall read that data during the same stabilization without a rebuild. ^smkey-2vhe
- When a key leaves, the keyed node shall invalidate that child incarnation and its exact keyed scope. ^smkey-d7oa
- When an equal key enters after committed removal, the keyed node shall create a fresh child incarnation and scope. ^smkey-vb62
- When several input writes occur before stabilization, the keyed node shall reconcile only the final input snapshot. ^smkey-fu6q
- When two keys use one child description, the keyed node shall create a distinct child cell in each keyed scope. ^smkey-l98z
- When one keyed scope reuses a child description, the graph shall share that child cell within the scope. ^smkey-pqom
- When a key enters, the keyed node shall patch one addition into the previous persistent output map. ^smkey-mm6e
- When a key leaves, the keyed node shall remove one binding from the previous persistent output map. ^smkey-6vtj
- When one child output changes without an input change, the keyed node shall patch only that output binding. ^smkey-j9v0
- The keyed operator shall use each child signal cutoff as its only output cutoff. ^smkey-bkjn
- When data suppression, child suppression, or rollback changes no output, the keyed node shall preserve the output-map root. ^smkey-gz8v
- When one physical data object mutates in place, the keyed node shall emit no map change or cutoff call. ^smkey-x2z7

## Transaction requirements

- When planning an addition, the keyed node shall register its provisional scope before it runs the builder. ^smtxn-8c7j
- While a provisional child waits for commit, the keyed node shall keep it detached from the keyed owner and committed demand roots. ^smtxn-yty8
- The keyed node shall stage the complete removal, update, addition, edge, and output plan before structural preflight. ^smtxn-j5oi
- When structural plans are nested, preflight shall process each owner before its descendants. ^smtxn-t2rm
- The structural preflight shall complete every fallible validation and counter reservation before pure commit. ^smtxn-4wbt
- When pure commit starts, it shall detach and invalidate all removals before it attaches an addition. ^smtxn-b12v
- When preflight succeeds, pure commit shall not call user code or perform another fallible operation. ^smtxn-78q6
- If planning or preflight fails, then rollback shall invalidate every provisional addition. ^smtxn-7vp7
- If planning or preflight fails, then rollback shall keep each committed removal candidate live. ^smtxn-5rpo
- If planning or preflight fails, then rollback shall preserve committed data, child identities, and the output-map root. ^smtxn-00no
- When stabilization retries a rolled-back addition, the keyed node shall use a fresh provisional scope and can run the builder again. ^smtxn-cdfg
- When an outer removal owns a nested keyed plan, preflight shall exclude that nested plan and invalidate its provisional scopes. ^smtxn-06z2
- When input and child sources change together, commit shall publish one final output that contains both changes. ^smtxn-oqx5
- When a keyed output root changes, its observer shall receive one final event after commit. ^smtxn-lrob
- When success or rollback completes, the graph shall retain no active transaction, staged cell, provisional scope, dirty keyed node, or queued keyed cleanup. ^smtxn-34ol
- When an equal key enters after removal, a signal captured from the old keyed scope shall remain invalid. ^smtxn-ahc5
- When a child output becomes dirty, the keyed owner dependency shall participate in graph order, reachability, demand, and diagnostics. ^smtxn-d6gk

## Diagnostics requirements

- The Eta Signal statistics shall contain one nested `keyed_stats` record with the ten declared keyed fields. ^smdiag-y97e
- When a graph has no keyed node, every field in `keyed_stats` shall be zero. ^smdiag-xfpv
- The keyed node and committed-child counters shall report current valid live state and exclude invalid tombstones. ^smdiag-19k7
- When a keyed plan starts, `reconciliation_count` shall increase once. ^smdiag-z8s2
- The keyed statistics shall count input-key comparisons and emitted input-diff events separately. ^smdiag-o22x
- The keyed statistics shall count only children selected for output evaluation in `child_visit_count`. ^smdiag-709x
- When planning registers a provisional scope, `provisional_addition_count` shall increase even if the plan later fails. ^smdiag-l4ra
- When pure commit adds or removes children, the matching committed counter shall increase at commit. ^smdiag-yqlu
- When a keyed plan completes rollback, `reconciliation_rollback_count` shall increase once. ^smdiag-98i1
- If a cumulative keyed counter reaches `max_int`, then stabilization behavior shall stay unchanged and `stats` shall return `Counter_overflow`. ^smdiag-ss8z
- The existing DOT scope selection shall include keyed nodes and children by necessity, validity, and tombstone state. ^smdiag-lb9n
- The DOT state shall identify keyed owners as `keyed_mapi` and show committed-child and requested scope metadata. ^smdiag-1pr6
- The diagnostics shall not format or retain key values, data values, child outputs, user closures, logs, journals, or action history. ^smdiag-oqvr
- The `stats` and `to_dot` functions shall observe one stable state without changing graph behavior, identities, counters, or pending work. ^smdiag-3hlp

## Performance requirements

- When snapshots share ancestry with `k` edits and size `n`, symmetric diff shall use `O(min(n, k log(n+1)))` key comparisons. ^smperf-ngt2
- When snapshots have independent ancestry, symmetric diff shall remain correct with `O(n)` key comparisons. ^smperf-g70n
- The keyed reconciliation shall use `O(min(n, k log(n+1)) + (d+c) log(n+1))` key comparisons with affected-child notification. ^smperf-siyo
- When only `c` child outputs change, keyed reconciliation shall not visit all retained children. ^smperf-mc2c
- When an output map has `p` persistent patches, downstream diff shall use `O(min(n, p log(n+1)))` key comparisons. ^smperf-ssho
- The deterministic complexity gate shall enforce the comparison and child-visit ceilings defined by the change-proportional benchmark contract. ^smperf-3v0d
- The deterministic complexity gate shall cover insertion, removal, data change, mixed edits, child-only changes, and independent-map controls through one million entries. ^smperf-mnvd
- The public complexity contract shall exclude builder, cutoff, child computation, cleanup, callback, allocation, memory, wall-time, and constant-factor costs. ^smperf-2vzo

## Open questions

None.
