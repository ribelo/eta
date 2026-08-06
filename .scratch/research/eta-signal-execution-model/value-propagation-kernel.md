# Value-propagation kernel prototype

Date: 2026-08-06

## Scope

This report answers the
[Value-propagation kernel prototype](../../../docs/wayfinder/eta-signal-execution-model/issues/06-value-propagation-kernel.md)
ticket.

The prototype covers the raw static kernel. It excludes Eta Effect, Eio,
rollback, dynamic topology, observers, timers, and keyed work.

The durable probe is in
[`static-kernel-probe/`](static-kernel-probe/). The code is throwaway code. It
does not change the production Signal engine.

## Answer

A synchronous direct-propagation kernel passes the applicable static gates.
Its measured path allocates 4 words at depths 1, 10, and 100.

The kernel also passes every matched wall-time gate. Its largest paired ratio
against Incremental is 0.614.

The immutable-plan candidate fails its allocation gate. It allocates 9 words
at depth 1, 18 words at depth 10, and 108 words at depth 100.

Keep direct propagation as the primary kernel. Reject strict immutable
prospective snapshots for the static path.

## Immutable-plan falsification

The `Plan` prototype separates planning from installation. Its graph retains
the operation closures. A plan contains these items:

- a base revision
- a prospective value array

Planning copies the committed value array. It computes candidate values in that
copy. Planning does not mutate the committed snapshot.

Commit checks the revision and installs the prospective array with one root
change. Commit does not run a graph closure.

The probe covers source admission, unary maps, cutoff, and depths 1, 10, and
100. Allocation increases with depth and reaches 108 words at depth 100.

This result reaches two kill conditions from issue 05:

1. Allocation increases with graph depth.
2. Allocation reaches 100 words.

This result rejects the tested prospective-array shape. It does not reject
every persistent or delta-based representation.

## Direct kernel

The `Raw` prototype has this execution interface:

```ocaml
val set : t -> var -> int -> unit
val stabilize : t -> (stabilization, error) result
```

This throwaway implementation is integer-specialized. It measures the static
execution representation, not generic typed value storage.

Constructors create variables, watches, unary maps, and binary maps. The test
interface reads a committed value and the accepted source value.

Each node retains these fields:

- its committed value
- its pure compute closure
- its cutoff
- its height
- its children and parents
- its demand state
- its queue stamp and intrusive queue link

The graph retains height-bucket heads and tails. A pass stamp prevents duplicate
queue entries.

The kernel recomputes a single unary parent directly. Other parents enter a
height bucket. This rule removes depth-dependent queue allocation from a static
chain and preserves topological order for fan-in.

Queue links use `node option`, which allocates wrappers on fan-in paths.

The measured integer callbacks return immediate values. The raw diamond
allocates 16 words per operation in all three measurement processes.

## Behavior evidence

One command runs all semantic and economics checks:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/static-kernel-probe/run.sh
```

The checks cover these observations:

| Observation | Result |
|---|---|
| Explicit stabilization | A source read changes at admission. A derived read changes after stabilization. |
| Coalesced source writes | Two writes produce one propagation of the last value. |
| Dependency order | Probe counters record left, right, then consumer. The consumer runs once. |
| Cutoff argument order | The custom cutoff receives published value first and candidate value second. |
| Published cutoff baseline | A suppressed candidate does not replace the next published argument. |
| Cutoff propagation | The frozen constant map stops all ten dependents. |
| Demand | Released work does not run. Reactivation computes the latest accepted source value. |
| Consistent success | A derived read stays old before stabilization. The output equation is complete after stabilization. |

The synchronous raw interface does not expose a read during stabilization.
Thus a caller cannot read an in-place intermediate value.

Some semantic probes increment counters from graph callbacks. This
instrumentation is not evidence that public callbacks can have side effects.

Issue 07 owns failed-pass publication and retry. It can add candidate slots,
sparse undo, or another rollback model without changing this execution shape.

## Affected-work evidence

The probe uses independent expected counts. It does not calculate an expected
count from a measured count.

| Gate | Sizes | Result |
|---|---|---|
| Quiescent work | 1,000, 10,000, and 100,000 nodes | One admission, one quiescent return, and zero claims, edges, evaluations, and cutoffs |
| Narrow frontier | The same sizes with one source and ten maps | 11 claims, 10 dependency edges, 10 propagation edges, 10 evaluations, and 10 cutoffs |
| Half graph | The same sizes | `m + 1` claims and `m` dependency edges, propagation edges, evaluations, and cutoffs |
| Balanced reduction | Powers of two through 131,072 | `N - 1` construction calls, `log2 N` changed-leaf combinations, and one aggregate cutoff |

Unrelated ballast does not change the counts. The scheduler follows the
affected frontier.

The dependency counter records each child read during evaluation. The
propagation counter records each parent notification after a changed value.

A two-source fan-in control changes one source. It records two dependency reads
and one parent notification. This control distinguishes the counters.

## Measurement protocol

The release build used the required OxCaml Nix shell. Each process ran on CPU
2. Each workload calibrated from one operation and doubled its count until
0.5 seconds or 16,777,216 operations.

Each process reported nine samples. The comparison used three fresh process
pairs. The table contains each process median.

The allocation formula was:

```text
minor words + major words - promoted words
```

Setup, demand retention, warm-up, the final read, and teardown stayed outside
the measured operation. One operation set one source and stabilized once.

The Incremental process uses the frozen graph and mutation formula without an
update handler. This K0 variant removes the six-word delivery layer.

Both the Incremental and Raw processes read their outputs after the timer
stops. Thus the compared operation boundaries are symmetric.

The complete samples are in
[`results.csv`](static-kernel-probe/results.csv). The process medians are in
[`summary.csv`](static-kernel-probe/summary.csv).

## Direct-kernel measurements

| Workload | Pair | Incremental ns/op | Raw ns/op | Ratio | Raw words/op |
|---|---:|---:|---:|---:|---:|
| Changed depth 1 | 1 | 33.31 | 20.13 | 0.604 | 4.000001 |
| Changed depth 1 | 2 | 32.21 | 19.76 | 0.613 | 4.000001 |
| Changed depth 1 | 3 | 32.23 | 19.78 | 0.614 | 4.000001 |
| Changed depth 10 | 1 | 98.06 | 51.26 | 0.523 | 4.000001 |
| Changed depth 10 | 2 | 96.80 | 51.15 | 0.528 | 4.000001 |
| Changed depth 10 | 3 | 102.40 | 51.22 | 0.500 | 4.000001 |
| Changed depth 100 | 1 | 984.69 | 520.11 | 0.528 | 4.000010 |
| Changed depth 100 | 2 | 981.47 | 521.67 | 0.532 | 4.000010 |
| Changed depth 100 | 3 | 983.78 | 521.33 | 0.530 | 4.000010 |
| Cutoff depth 10 | 1 | 31.00 | 18.46 | 0.596 | 4.000001 |
| Cutoff depth 10 | 2 | 30.89 | 18.85 | 0.610 | 4.000001 |
| Cutoff depth 10 | 3 | 31.01 | 18.46 | 0.595 | 4.000001 |

All allocation rows are less than 100 words. Allocation does not increase with
graph depth after the fixed measurement residue.

All wall-time ratios are less than 1.20 in all three pairs. The candidate
passes the required two-pair rule for every workload.

## Immutable-plan measurements

| Depth | Median words/op in each process | Median ns/op range |
|---:|---:|---:|
| 1 | 9.000001 | 12.74-12.80 |
| 10 | 18.000001 | 36.64-37.08 |
| 100 | 108.000005 | 303.89-306.73 |

The plan is fast because `Array.copy` is a compact operation. Its allocation
still represents every prospective value. This cost disqualifies the design.

The immutable cutoff row allocates 19.000001 words in all three processes.
This row does not change the depth-based rejection.

## Limits

The measured workloads use integer values and static topology. The prototype
does not cover the representation for generic or boxed values.

The prototype does not prove failed-pass atomicity. It also does not prove
dynamic topology, keyed continuity, observer order, timer behavior, or adapter
cost.

The direct unary path depends on one static parent and one static child. Fan-in
uses the retained height buckets. Later topology work must preserve this
distinction without adding static-path allocation.

## Decision

Use retained in-place values, pass stamps, affected-parent scheduling, and the
direct unary path for the next prototype.

Keep this raw execution seam as the target. A later prototype must prove its
generic typed storage:

```ocaml
val set : t -> 'a var -> 'a -> unit
val stabilize : t -> (stabilization, error) result
```

Issue 07 must add failure and rollback without increasing the 4-word static
result with graph depth. It must preserve the successful direct path when no
failure machinery is active.
