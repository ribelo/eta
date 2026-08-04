# Core work economics

Type: prototype
Status: resolved
Blocked by: none

## Question

What deterministic graph work does the current engine perform for F1, N4, and
F13 workloads?

Add throwaway counters for node visits, edge checks, registry scans, observer
root scans, dependency searches, bind candidates, necessity work, and timer
work. Measure quiescent stabilization, a narrow source change, a half-graph
change, a nested bind switch, a keyed child-only change, and wide `all`
construction and invalidation.

Use several graph sizes to distinguish constant, linear, and quadratic work.
Record wall time only as supporting evidence. Link the prototype and results as
assets.

## Answer

The deterministic counts confirm F1 and F13. They amend N4.

### Stabilization

A quiescent graph performs no user-function recomputation. It still performs
graph-wide compute, registry, necessity, bind-reachability, and timer work.

The `128`, `512`, and `2048` target series gives these controls:

- Narrow changes recompute exactly 10 nodes while graph-wide counts grow.
- Half-graph changes recompute approximately half the graph.
- Nested bind switches recompute 3 nodes and use 2 fixpoint passes.
- Keyed child-only changes compute 1 selected child at every size.
- The surrounding core scans still grow with the complete graph.

A multi-observer chain also exercises the comparator counter. Comparator DFS
visits grow from `608` to `8,832` to `134,656`.

### Wide edges

Public `all` construction performs exactly:

```text
n * (n - 1) / 2
```

adjacency checks. Construction is quadratic.

Whole-node `all` invalidation performs `n + 3` detachment checks. Its adjacency
work is linear, so the review's general wide-teardown claim is too broad.

The keyed bulk-removal control keeps its owner live. It performs exactly:

```text
n * (n + 5) / 2
```

detachment checks. This public removal path is quadratic.

### Adjacent diagnostic cost

Each invalidated node enters a bounded list of 1,024 tombstones. Insertion scans
the existing list before truncation.

The measured work is:

```text
sum for i = 0 to count - 1 of min(i, 1024)
```

Ticket 15 owns this diagnostic index. Ticket 16 owns its deterministic gate.

[Scheduler, demand, and topology model](10-scheduler-demand-and-topology.md)
owns the F1 and N4 design. [Laws and economics
gates](16-laws-and-economics-gates.md) owns production counter boundaries,
sizes, and ceilings.

### Evidence

The prototype is on branch `prototype/eta-signal-core-economics` at commit
`c52f22df`. Run it with one command:

```sh
bash .scratch/prototypes/eta-signal-core-economics/run.sh
```

The command exits with status `0` only when the exact formulas and growth
controls hold.

- [Probe results](../../../../.scratch/research/eta-signal-direction/core-work-economics/RESULTS.md)

### Census rows resolved here

- Limits and verdicts: `SCP-006` and `EXE-012`.
- F1 evidence: `F01-002` through `F01-020`.
- Static `all`: `F08-002`.
- F13 counters: `F13-007` and `F13-015` through `F13-022`.
- Observer-search cost: `N03-012`.
- N4 evidence: `N04-002` through `N04-008` and `N04-011`.
- Semantic and evidence limits: `S02-002`, `S13-001`, `S13-002`, and
  `Q01-002`.
