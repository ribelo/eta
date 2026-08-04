# Eta Signal core work economics

## Question

What deterministic graph work does the current engine perform for F1, F13,
and N4 workloads?

## Method

The prototype instruments the selected Signal source revision. It uses branch
`prototype/eta-signal-core-economics` at commit `c52f22df`.

Each case uses a fresh Signal functor instance. All effectful cases use one Eta
runtime and one test clock.

The probe resets its counters immediately before the measured operation. Setup,
observer registration, and the first stabilization do not affect the reported
counts.

The size series is `128`, `512`, and `2048`. A fourfold size increase separates
constant, linear, and quadratic work without relying on elapsed time.

The final production gates can use larger sizes. Ticket 16 owns those sizes and
ceilings.

Wall time appears in the branch log as supporting evidence. It is not a gate.

## Counter boundaries

The counters have these exact boundaries:

- `compute` counts each call to `compute_cached`, including a generation-cache
  hit.
- `recomputed` counts each selected node-recompute plan.
- `keyed_children` counts each selected keyed-child computation.
- `edge_checks` counts each dependency-version read or comparison.
- `registry` counts each weak live-node cell presented to registry collection.
- `source_watchers` counts each weak source-watcher cell presented to
  collection.
- `roots` counts each observer record considered for an active or demand root.
- `delivery` counts each observer record presented to delivery planning.
- `order_dfs` counts each recursive candidate visit in an observer dependency
  search.
- `bind_reach` counts each valid node visited while the engine collects bind
  candidates.
- `bind_passes` counts each fixpoint pass, including the final pass.
- `bind_candidates` counts selected bind nodes across those passes.
- `necessity` counts each valid node visited while necessity is rebuilt.
- `timer_registry` counts live-node cells scanned for timer demand.
- `timer_reach` counts valid nodes visited during timer reachability.
- `dirty_frontier` counts valid nodes visited during dirty notification.
- `attach_checks` counts adjacency predicates during edge attachment.
- `detach_checks` counts adjacency predicates during edge detachment.
- `tombstone_checks` counts entries inspected in the bounded dead-node index.
- `invalidations` counts live nodes that become invalid.

The counters overlap by design. Each counter reports one operation class. Their
sum is not a total-work value.

## Stabilization results

### Quiescent stabilization

| Signal nodes | Compute visits | Recomputation | Registry cells | Necessity visits | Timer registry visits | Timer reachability visits |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 108 | 119 | 0 | 864 | 108 | 324 | 324 |
| 459 | 509 | 0 | 3,672 | 459 | 1,377 | 1,377 |
| 1,836 | 2,039 | 0 | 14,688 | 1,836 | 5,508 | 5,508 |

The graph does no user-function recomputation. It still performs graph-wide
compute, registry, necessity, and timer work.

The registry count is exactly eight times the signal-node count. Each timer
counter is exactly three times that count.

### Narrow source change

| Signal nodes | Compute visits | Recomputation | Registry cells | Dirty-frontier visits |
| ---: | ---: | ---: | ---: | ---: |
| 118 | 129 | 10 | 944 | 10 |
| 460 | 509 | 10 | 3,680 | 10 |
| 1,846 | 2,049 | 10 | 14,768 | 10 |

Useful recomputation stays constant at ten nodes. Compute and registry work grow
with the complete graph.

This case confirms the amended F1 statement. Current user-function
recomputation can be change-proportional while stabilization is not.

### Half-graph source change

| Signal nodes | Compute visits | Recomputation | Registry cells | Dirty-frontier visits |
| ---: | ---: | ---: | ---: | ---: |
| 119 | 119 | 61 | 952 | 61 |
| 509 | 509 | 253 | 4,072 | 253 |
| 2,039 | 2,039 | 1,023 | 16,312 | 1,023 |

Recomputation and dirty propagation cover approximately half the graph.
Compute, registry, necessity, and timer work still cover the full graph.

### Nested bind switch

| Signal nodes | Recomputation | Bind passes | Bind candidates | Bind-reachability visits | Registry cells |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 116 | 3 | 2 | 2 | 224 | 1,273 |
| 467 | 3 | 2 | 2 | 926 | 5,134 |
| 1,844 | 3 | 2 | 2 | 3,680 | 20,281 |

The switch has constant useful recomputation and two fixpoint passes.
Bind-reachability and registry work grow with the complete graph.

### Keyed child-only change

| Signal nodes | Compute visits | Recomputation | Selected keyed children | Registry cells | Necessity visits |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 132 | 5 | 2 | 1 | 1,056 | 132 |
| 516 | 5 | 2 | 1 | 4,128 | 516 |
| 2,052 | 5 | 2 | 1 | 16,416 | 2,052 |

The keyed algorithm selects exactly one child at every size. Core registry,
necessity, bind-reachability, and timer work still grow with all signal nodes.

This result separates Signal Map child selection from core scheduler economics.

## Observer-order control

The control observes every eighth node in one dependency chain.

| Signal nodes | Observers | Comparator DFS visits | Observer-root scans |
| ---: | ---: | ---: | ---: |
| 128 | 16 | 608 | 80 |
| 512 | 64 | 8,832 | 320 |
| 2,048 | 256 | 134,656 | 1,280 |

A fourfold increase in graph size and observer count gives approximately
sixteen times more comparator visits.

This control exercises the F13 comparator counter. It also confirms that
pairwise dependency searches can add superlinear work.

Ticket 11 still owns the observer-order contract. This probe does not select a
delivery policy.

## Wide edge results

### Public `all` construction

| Children | Attachment checks |
| ---: | ---: |
| 128 | 8,128 |
| 512 | 130,816 |
| 2,048 | 2,096,128 |

Every row equals:

```text
n * (n - 1) / 2
```

Public `all` construction is exactly quadratic in its child count.

### Whole-node `all` invalidation

| Children | Detachment checks | Invalidated nodes | Tombstone checks |
| ---: | ---: | ---: | ---: |
| 128 | 131 | 129 | 8,256 |
| 512 | 515 | 513 | 131,328 |
| 2,048 | 2,051 | 2,049 | 1,573,376 |

Detachment checks equal `n + 3`. Whole-node adjacency detachment is linear.

The dead-node index scans all retained tombstones before it keeps the latest
1,024 entries. Its exact work is:

```text
sum for i = 0 to count - 1 of min(i, 1024)
```

This diagnostic path gives quadratic growth before the index reaches its bound.
It then adds 1,024 checks for each further invalidation.

### Keyed bulk-removal control

| Children removed | Detachment checks | Tombstone checks |
| ---: | ---: | ---: |
| 128 | 8,512 | 8,128 |
| 512 | 132,352 | 130,816 |
| 2,048 | 2,102,272 | 1,572,352 |

Detachment checks equal:

```text
n * (n + 5) / 2
```

The keyed owner stays valid while removals detach one child at a time. Each
removal filters the shrinking owner dependency list.

This public keyed path has quadratic edge-removal work.

## Disposition

F1 is confirmed with the review amendment. Useful recomputation can be narrow,
but each stabilization performs graph-wide core work.

F13 is confirmed. The current public counters do not expose these work
dimensions. The test-only counter set measures every requested class.

N4 needs an amendment:

- Wide `all` construction has quadratic adjacency work.
- Whole-node `all` invalidation has linear adjacency work.
- Repeated detachment from a live keyed owner has quadratic adjacency work.
- The bounded tombstone index adds separate diagnostic work during
  invalidation.

The review attributed all wide teardown cost to repeated edge filtering. That
statement is too broad.

Ticket 10 owns the scheduler, edge representation, and complexity contracts.
It must distinguish whole-node invalidation from repeated live-owner
detachment.

Ticket 15 owns the bounded tombstone index and its diagnostic invariant. Ticket
16 owns deterministic production gates for all measured classes.

## Evidence

Run the prototype from its branch:

```sh
bash .scratch/prototypes/eta-signal-core-economics/run.sh
```

The command exits with status `0` only when all exact formulas and growth
controls hold.

The branch keeps the probe source, instrumentation, and complete CSV result
log. Production code and tests remain unchanged on `master`.
