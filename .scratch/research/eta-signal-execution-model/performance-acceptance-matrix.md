# Performance acceptance matrix

Date: 2026-08-05

## Scope

This report answers the
[Performance acceptance matrix](../../../docs/wayfinder/eta-signal-execution-model/issues/04-performance-acceptance-matrix.md)
ticket.

The matrix selects prototypes and the integrated finalist. It does not change
the frozen workloads or their formulas.

## Decision

A candidate is eligible only when it passes these gates in order:

1. the binding Signal behavior oracle
2. the deterministic affected-work gates
3. the allocation gates
4. the wall-time gates

An ineligible candidate cannot win because it is small or fast.

Rank eligible candidates in this order:

1. deepest module interface
2. lowest worst allocation ratio against its reference
3. lowest worst wall-time ratio against its reference

The interface comparison uses Design It Twice in issue 05. The performance
ratios do not replace that interface judgment.

## References

Matched scalar work uses Incremental revision
`31eb755facdfcaaf4ccbae55dffd829f7c7278f9`.

Matched keyed work uses Incr_map revision
`07e7d3ca75fe1aa855595cf617fd205f9d419653`.

Eta-only edge work uses Eta revision
`d04d6e2bedc87ab22326af5cc03c339406177a67`. This revision contains the
completed cost decomposition and precedes replacement-kernel prototypes.

The source revisions and checksums are in
[Incremental layered baseline](incremental-layered-baseline.md). The Eta
adapter baselines are in
[Eta execution-cost decomposition](eta-execution-cost-decomposition.md).

## Measurement protocol

Run the reference and candidate in the same environment. The machine, CPU,
OxCaml version, Dune profile, Eio backend, and benchmark configuration must
match.

Use the frozen release-profile harness in
`bench/signal_compare/compare.ml`. Each workload runs in a fresh process pinned
to one CPU.

The harness starts with one operation. It doubles the count until the batch
takes at least 0.5 seconds or reaches 16,777,216 operations.

Run three complete reference and candidate comparisons. Each process reports
nine measured samples. Use the median for each process.

A matched wall-time row passes when the Eta median is no more than `1.20` times
the reference median in at least two comparison pairs.

An Eta-only wall-time row passes when the candidate median is no greater than
the pre-redesign Eta median in at least two comparison pairs.

Allocation uses this existing formula:

```text
minor words + major words - promoted words
```

Normalize wall time and allocation by the operation count. Setup, warm-up, the
final observer read, and teardown stay outside one measured operation.

## Matched kernel gates

One scalar operation sets one source and stabilizes once. One keyed operation
changes one input binding, one membership, or one child source and stabilizes
once. The observer read occurs after the measured batch.

The operation counts below record the completed reference run. Future paired
runs use the calibration rule above.

| Workload | Graph size | Reference operations | Raw reference allocation | Raw Eta allocation gate |
|---|---:|---:|---:|---:|
| changed scalar | depth 1 | 16,777,216 | 0 words | fewer than 100 words |
| changed scalar | depth 10 | 4,194,304 | 0 words | fewer than 100 words |
| changed scalar | depth 100 | 524,288 | 0 words | fewer than 100 words |
| cutoff | 10 dependents | 16,777,216 | 0 words | fewer than 100 words |
| dynamic switch | one selector and a fresh constant branch | 4,194,304 | 43 words | at most 51.6 words |
| keyed data change | 10,000 keys | 2,097,152 | 180 words | at most 216 words |
| keyed data change | 100,000 keys | 2,097,152 | 228 words | at most 273.6 words |
| keyed membership change | 10,000 keys | 1,048,576 | 343.5 words | at most 412.2 words |
| keyed membership change | 100,000 keys | 1,048,576 | 433.5 words | at most 520.2 words |
| keyed child change | 10,000 keys | 8,388,608 | 78 words | at most 93.6 words |
| keyed child change | 100,000 keys | 4,194,304 | 102 words | at most 122.4 words |

The static allocation gate is absolute because a ratio against zero is not
defined. It applies after warm-up and cannot increase with graph depth.

The other raw gates are `1.20` times the matched raw Incremental allocation.
The public reference allocates six additional words when it delivers a changed
value. Those words do not belong to the raw kernel reference.

Each raw row and its complete public row also uses the matched `1.20` wall-time
gate. The complete public row retains the same graph, mutation, stabilization,
cutoff, and final read.

## Eta adapter gates

Measure each adapter around the same accepted raw kernel operation. An adapter
delta cannot exceed its pre-redesign Eta allocation delta.

| Adapter | Operation boundary | Allocation ceiling |
|---|---|---:|
| Effect | one prebuilt Effect step | 10 words |
| Uncontended lane | one fused lane acquisition | 169 words |
| Public synchronous protocol | separate public set and stabilization | 1,083 words |
| Eio runtime | the same public operation on Eio, without a yield | 1,174 words |
| Explicit yield control | one Eio-backed `Effect.yield` | 53 words |
| Observer delivery | demand plus one no-op callback | 2,140 words |
| Non-firing timer | one demanded timer around a changed chain | `2,315 + (6 * depth)` words |

The explicit-yield row is diagnostic unless a candidate operation requires a
yield. Timer, observer-failure, disposal, and contention prototypes also use
the Eta-only wall-time rule.

Issues 09 and 10 can split an adapter into smaller rows. They cannot hide its
total cost or weaken the ceiling.

## Deterministic affected-work gates

Use the complete economics matrix from
[Laws and economics gates](../../../docs/wayfinder/eta-signal-direction/issues/16-laws-and-economics-gates.md#economics-gates).
These gates fail on the first count violation.

| Gate | Sizes | Required bound |
|---|---|---|
| quiescent work | 1,000, 10,000, and 100,000 nodes | one admission and one quiescent return, with all other work counts at zero |
| narrow frontier | the same graph sizes with one source and ten maps | the exact 11-claim, 10-edge, 10-evaluation, and 10-cutoff manifest |
| half graph | the same graph sizes | `m + 1` claims and `m` map or edge operations, where `m = floor((N - 1) / 2)` |
| nested bind switch | depths 1, 8, and 64 at each graph size | the exact frontier manifest, with all search-step counts at zero |
| keyed child change | 1,000, 10,000, and 100,000 keys | one selected child and no input comparison, diff event, or topology edit |
| observer candidate union | 1, 32, and 1,024 candidates | exact union counts and at most `4 * C * ceil(log2(C + 1))` ready comparisons |
| unrelated observers | eight candidates and 1,000, 10,000, or 100,000 unrelated observers | the complete candidate-work vector is unchanged |
| timer reconciliation | 1, 32, and 1,024 queued mismatches | one claim for each mismatch, while timer ballast adds no visit |
| wide attachment | 1,000, 10,000, and 100,000 edges | exactly `N` inserts and no adjacency search |
| wide invalidation | the same edge sizes | exactly `N` removals, at most `N` repairs, and no adjacency search |
| keyed removal | 1, 1,000, 10,000, and 100,000 children | exactly `K` removals and cleanup transitions, at most `K` repairs |
| balanced reduction | powers of two through 131,072 | `N - 1` construction calls and `log2 N` calls for one changed leaf |
| tombstone insertion | 0, 1, 1,023, 1,024, 1,025, and 100,000 entries | one slot write per entry, exact bounded retention and eviction, no duplicate scan |

The existing `@signal-map-complexity` gate remains binding for shared ancestry,
independent snapshots, keyed reconciliation, and child-only changes. Its
existing sizes, comparison formulas, and four-times linear-control separation
remain unchanged.

## Edge capability rows

The frozen comparison does not cover rollback, demand transitions, observer
failure, timer lifecycle, disposal, or lane contention.

The owning prototype issue must add one Eta-only row when it introduces one of
these paths:

| Owner | Required row |
|---|---|
| issue 07 | failed stabilization and successful retry around one unchanged raw graph |
| issue 08 | demand activation, release, and dynamic-scope cleanup |
| issue 09 | one uncontended operation and one queued, cancelled contender |
| issue 10 | observer failure and retry, disposal, timer start, timer wake, and timer stop |

Each row compares the same operation against the pinned pre-redesign Eta
revision. Its candidate allocation cannot exceed the reference allocation. Its
wall time cannot exceed the reference median in two of three comparison pairs.

The row must also pass its binding behavior and affected-work counts. A later
issue can choose the smallest graph that reaches every documented branch. It
must state that graph size and operation count in its prototype report.

This rule adds evidence only when a prototype reaches the capability. It does
not add speculative benchmark machinery to earlier kernel prototypes.

## Eligibility and selection

A candidate is rejected when any applicable behavior, affected-work,
allocation, or wall-time row fails.

After all gates pass, compare module depth. If two candidates have equal module
depth, compare their largest allocation ratio across all applicable rows. If
that ratio is equal, compare their largest wall-time ratio.

This worst-row rule prevents a fast common path from hiding one expensive
capability.

## Decision

Keep the frozen matched workloads unchanged. Use Incremental for matched raw
kernel and complete-operation wall references. Use the pinned pre-redesign Eta
revision only for Eta-specific adapters and edge protocols.

Correctness and affected-work bounds determine eligibility. Performance ranks
only eligible candidates.
