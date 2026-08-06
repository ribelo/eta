# Failure and rollback model

Date: 2026-08-06

## Scope

This report answers the
[Failure and rollback model](../../../docs/wayfinder/eta-signal-execution-model/issues/07-failure-and-rollback-model.md)
ticket.

The report covers the failure and publication representation of the raw kernel
from
[Value-propagation kernel prototype](value-propagation-kernel.md).
It covers pure pre-publication failure, retry, and reentry.

Dynamic topology, keyed work, observer delivery, and timers stay with issues 08,
09, and 10. This report states the constraint each of those issues inherits.

The durable probes are
[`rollback-kernel-probe/`](rollback-kernel-probe/) and
[`failure-retry-reference-probe/`](failure-retry-reference-probe/). Both are
throwaway code. Neither changes the production Signal engine.

## Answer

A sparse undo journal preserves the last committed snapshot. It does not need a
universal transaction over the recomputed nodes.

Each node keeps one undo slot and one write stamp. A pass records a node once, at
its first write. Commit resets the journal length, which is O(1). Rollback walks
the journal in reverse and restores each committed value.

The journal records dense node indices, not node pointers. This choice removes
the pointer write barrier from the success path. It costs 1.0 nanoseconds for
each changed node instead of 3.9 nanoseconds.

The selected candidate allocates 4 words at changed depths 1, 10, and 100. This
value equals the issue 06 result, so rollback adds no allocation. Its largest
static wall-time ratio against Incremental is 0.769.

One failed pass with its successful retry allocates 8 words at every depth. The
pinned Eta reference allocates 1,227 words at depth 1 and 11,919 words at depth
100.

Reject prepared publication for the static path. It pays a publication walk on
every changed pass, and it needs two read modes.

Reject lazy epoch rollback. The probe falsifies it with a cutoff counterexample.

Reject persistent state. Issue 06 measured its depth-dependent allocation.

## The rollback surface

A failed pass must restore the state that a public read can observe. It must
not restore state that no public read exposes.

The kernel must restore these items:

1. the published value of each node that the pass overwrote
2. the cutoff published baseline, which is the same slot
3. the retry frontier, so admitted source work runs again
4. the scheduling stamps and height buckets that the frontier uses
5. the demand counters, which a static failure must not change
6. the topology and dynamic scopes of the pass (issue 08)
7. the keyed committed tables and output roots (issue 08)
8. the timer intents of the pass (issue 10)

The kernel must not restore these items:

1. the accepted source values, because a retry needs them
2. the monotonic counters, which the public contract declares monotonic
3. the pass identity, because each attempt is a separate attempt
4. the cumulative diagnostic counters that `stats` reports

This separation is the reason a universal transaction is not necessary. The
observable snapshot is small. The recomputation record is large.

## Binding failure and reentry census

The oracle rows are in
[Binding Signal behavior](binding-signal-behavior.md). The public prose is in
`lib/signal/eta_signal.mli:652-674`.

### Failures before publication

Each row below must leave the committed snapshot in place. Each row must also
leave the admitted source work retryable.

| ID | Failure | Oracle row | Owner |
|---|---|---|---|
| FB01 | A pure graph closure raises during recomputation | SB07, SB10 | issue 07 |
| FB02 | The pass detects a cycle | SB11 | issue 07 |
| FB03 | A monotonic counter reaches `max_int` | SB11 | issue 07 |
| FB04 | A nested stabilization starts inside the pass | SB11 | issue 07 |
| FB05 | Cancellation interrupts the pass before publication | SB02, SB10 | issue 09 |
| FB06 | A bind selector fails, and the old branch must remain | SB12 | issue 08 |
| FB07 | A pure node after a bind switch fails | SB12 | issue 08 |
| FB08 | An invalid or ambiguous scope appears during the pass | SB11, SB12 | issue 08 |
| FB09 | A keyed reconciliation attempt fails | MB09 | issue 08 |

### Failures after publication

Each row below must keep the committed snapshot. Rollback is forbidden.

| ID | Failure | Oracle row | Owner |
|---|---|---|---|
| FA01 | An observer callback fails or is interrupted | SB17 | issue 10 |
| FA02 | A timer lifecycle step raises a defect | SB10, SB18 | issue 10 |
| FA03 | A disposal hook fails | SB16 | issue 10 |

### Reentry

| ID | Reentry | Required outcome | Oracle row | Owner |
|---|---|---|---|---|
| RE01 | `stabilize` from an observer callback | `Reentrant_stabilization`, and the outer delivery phase continues | SB11 | issue 07 |
| RE02 | `Var.set` from an observer callback | The write is accepted for a later pass | SB05 | issue 07 |
| RE03 | `Observer.read` from an observer callback | The read returns the committed snapshot | SB09 | issue 10 |
| RE04 | `update_effect` inside `update_effect` | `Reentrant_update`, and the source value stays | SB05 | issue 09 |

RE01 and RE02 constrain this issue directly. The reentry guard must run before
any state change. A rejected nested attempt must not consume the rollback state
of the outer pass.

RE02 also fixes the clear point of the admitted-source list. The kernel must
clear that list at publication, not at the end of the operation. A write during
the delivery phase belongs to the next pass.

## Candidate models

### The publication dilemma

The kernel keeps values in place. One global counter identifies the current
pass. Under these two conditions a pass must walk the set of written nodes at
commit or at rollback.

A model that walks at neither point is unsound. The counterexample is in
[Lazy epoch falsification](#lazy-epoch-falsification).

The design question is therefore not whether to walk. The question is which
path pays for the walk.

### R1 sparse undo

Each node keeps an undo slot and a write stamp. The first write of a pass copies
the committed value into the undo slot and appends the node to a reusable
buffer. Later writes in the same pass skip the copy.

Commit resets the buffer length. Commit does not touch a node.

Rollback walks the buffer in reverse. It restores each committed value and
clears each write stamp.

The success path pays one stamp compare, one value copy, and one buffer store
for each changed node. The failure path pays one walk.

### R2 prepared publication

Each node keeps a candidate slot and a candidate stamp. Recomputation writes the
candidate slot. A child read returns the candidate when the stamp matches the
current pass, and the committed value otherwise.

Commit walks the buffer and publishes each candidate. Rollback resets the buffer
length.

This model reverses the cost of R1. It pays a walk on every changed pass and
nothing on failure.

R2 also has a locality cost. The module must keep two read modes at the same
time. A child computation reads the current candidate, but a cutoff comparison
must read the committed baseline. This second rule exists because SB03 requires
the published value as the first cutoff argument.

### Variants that reduce to R1 or R2

| Variant | Result |
|---|---|
| Two value slots with a per-node committed selector | The selector flip needs the same walk. This equals R2. |
| An undo log that stores the old value in the log | Equal to R1 for integers. A generic log entry must hold a value of the node's type, so it needs a heterogeneous store. An undo slot in the node stays monomorphic. |
| Repair by recomputation, with no undo slot | Rejected by the oracle. SB04 states that `Observer.read` never stabilizes. A read between the failed pass and the retry then exposes an intermediate value, which SB10 forbids. |

### R3 lazy epoch

This model is the only shape that can make commit and rollback both O(1). It
uses a monotonic pass counter, a committed counter, an undo slot, and a write
stamp. A read returns the undo slot when the write stamp is greater than the
committed counter.

The probe falsifies this model. The result is below.

### R4 persistent state

Issue 06 already rejected a strict immutable prospective snapshot. It allocates
9 words at depth 1 and 108 words at depth 100.

A persistent map from node identity to value has the same defect. Each changed
node adds path copies, so allocation grows with the changed set. This report
does not rebuild that measurement.

### Comparison

| Model | Commit cost | Rollback cost | Read cost | Verdict |
|---|---|---|---|---|
| R1 sparse undo | O(1) | O(written) | One slot read | Selected |
| R2 prepared publication | O(written) | O(1) | One stamp compare and two read modes | Rejected on the static path |
| R3 lazy epoch | O(1) | O(1) | One stamp compare | Falsified |
| R4 persistent state | O(1) | O(1) | One slot read | Rejected on allocation |

Failure is the rare path. A pure closure raises only when an application has a
defect. R1 puts the cost on that path and leaves the common path free.

## Lazy epoch falsification

The probe builds the read rule of R3 as a two-node model. The gate node has a
custom cutoff. The output node maps the gate node.

The sequence is this:

1. The accepted source value becomes 1.
2. Pass 1 writes 1 into the gate node and the output node, and then fails.
3. A read returns 0, because the write stamp is greater than the committed
   counter.
4. The accepted source value becomes 2.
5. Pass 2 starts. The custom cutoff of the gate node suppresses the transition
   from published 0 to candidate 2.
6. Pass 2 commits nothing and advances the committed counter to 2.
7. A read of the output node now returns 1.

The printed counterexample is:

```text
R3 counterexample: failed_pass=1 failed_candidate=1 next_pass=2 next_candidate=2
cutoff_suppressed_n=true after_failure=0 committed=2 observed=1 expected=0
```

The committed counter passed the write stamp of a node that no later pass
rewrote. The failed value became visible. This result breaks SB10.

The cause is general. A monotonic committed counter cannot separate a committed
stamp from an abandoned stamp, because a later admission can suppress
propagation through a node that the failed pass overwrote. A repair must walk
the touched set, which removes the O(1) rollback that motivated the model.

SB03 supplies the suppression that the counterexample needs. A custom cutoff is
part of the public interface, so this scenario is a supported use.

## Behavior evidence

One command runs every semantic, failure, reentry, and economics check:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/rollback-kernel-probe/_build/default/probe.exe \
  --check
```

The suite runs every check against each candidate. Rollback machinery does not
change any inherited result from issue 06.

| Observation | Result |
|---|---|
| Every issue 06 semantic check | Pass for each candidate |
| Failed pass at the first, middle, and last node of depths 1, 10, and 100 | Every committed value stays |
| Bare retry after a failure | The retry commits the retained accepted source value |
| Retry after further admissions | The retry commits the latest accepted value |
| Cutoff baseline after a failure | The next cutoff receives the committed value, not the discarded candidate |
| Three failures and then one success | The success commits the correct value |
| Failure inside a partly drained diamond | The retry restores the frontier and evaluates each affected node once |
| Demand across a failure | Released demand stays released, and reactivation computes a fresh value |
| Reentrant stabilization | The nested call returns a typed error and does not change the outer frontier |
| Quiescence after a failure and a retry | The graph returns `Quiescent` with zero work counts |

The frontier check uses independent expected counts. The diamond retry expects 4
claims, 4 dependency edges, 4 propagation edges, 3 evaluations, 3 cutoffs, and
one evaluation of each closure. Every exact count passes.

The reentry check proves the RE01 constraint. The kernel sets its running state
before the first graph closure. The nested attempt then returns
`Reentrant_stabilization` without a state change.

A retention check proves the bound of the O(1) commit. The active buffer length
is zero after a commit. The stale prefix never exceeds the largest touched count
of the graph. A later pass overwrites the stale prefix from index zero.

## Affected-work evidence

The probe repeats the complete issue 06 economics matrix for each candidate. The
quiescent, narrow-frontier, half-graph, and balanced-reduction counts are
unchanged at 1,000, 10,000, and 100,000 nodes, and at reduction sizes through
131,072.

Rollback adds one new affected-work rule. A failed pass and its retry must not
recompute more than the affected frontier. The diamond frontier check proves the
exact counts above.

The reference engine gives the contrast. Its rollback allocation grows by 40
words for each node that the failed pass had already written. Its depth-10 raw
row rises from 1,839 words with the first node failing to 2,199 words with the
last node failing.

## Measurement protocol

Both probes use the frozen protocol from
[Performance acceptance matrix](performance-acceptance-matrix.md).

The release build used the required OxCaml Nix shell. Each workload ran in a
fresh process on CPU 2. Each workload calibrated from one operation and doubled
its count until 0.5 seconds or 16,777,216 operations.

Each process reported nine samples. The run used three comparison pairs. The
tables contain process medians.

The allocation formula was:

```text
minor words + major words - promoted words
```

Setup, demand retention, warm-up, the final read, and teardown stayed outside
the measured operation.

One static operation set one source and stabilized once. One failed-retry
operation set one source, ran one failed pass, and ran one successful retry.

The two probes ran in sequence on the same CPU. Thus the candidate and the
reference share their measurement conditions.

The measured loop discards the raw result value. Issue 06 used the same
boundary, so both static rows exclude the two-word result block. An Eta adapter
that consumes the result pays those two words at the adapter layer.

The rollback probe repeats each Incremental workload once for each candidate
block. The summary groups the samples of one pair, so each reference median uses
more samples than one candidate median.

## Measurements

### Static success path

The reference is the matched Incremental median in the same pair. The gate is
1.20 in at least two pairs.

| Candidate | Workload | Ratio in each pair | Words | Gate |
|---|---|---|---:|---|
| R1 undo, functor and commit walk | changed depth 1 | 1.037 / 1.017 / 1.036 | 4.000001 | Pass |
| R1 undo, functor and commit walk | changed depth 10 | 1.241 / 1.359 / 1.234 | 4.000002 | **Fail** |
| R1 undo, functor and commit walk | changed depth 100 | 1.080 / 1.032 / 1.079 | 4.000019 | Pass |
| R1 undo, functor and commit walk | cutoff depth 10 | 0.950 / 0.978 / 0.977 | 4.000001 | Pass |
| R2 publication, functor | changed depth 1 | 1.086 / 0.994 / 1.068 | 4.000001 | Pass |
| R2 publication, functor | changed depth 10 | 1.277 / 1.216 / 1.257 | 4.000002 | **Fail** |
| R2 publication, functor | changed depth 100 | 0.986 / 0.964 / 1.033 | 4.000019 | Pass |
| R2 publication, functor | cutoff depth 10 | 0.935 / 1.000 / 0.937 | 4.000001 | Pass |
| R1b undo, functor and O(1) commit | changed depth 1 | 0.941 / 0.921 / 0.933 | 4.000001 | Pass |
| R1b undo, functor and O(1) commit | changed depth 10 | 1.051 / 1.095 / 0.984 | 4.000002 | Pass |
| R1b undo, functor and O(1) commit | changed depth 100 | 0.929 / 0.909 / 0.891 | 4.000019 | Pass |
| R1b undo, functor and O(1) commit | cutoff depth 10 | 0.850 / 0.901 / 0.881 | 4.000001 | Pass |
| R1m undo, pointer journal | changed depth 1 | 0.956 / 0.919 / 0.942 | 4.000001 | Pass |
| R1m undo, pointer journal | changed depth 10 | 0.992 / 0.991 / 0.988 | 4.000001 | Pass |
| R1m undo, pointer journal | changed depth 100 | 0.993 / 0.897 / 0.903 | 4.000019 | Pass |
| R1m undo, pointer journal | cutoff depth 10 | 0.874 / 0.924 / 0.925 | 4.000001 | Pass |
| R1i undo, index journal | changed depth 1 | 0.769 / 0.737 / 0.750 | 4.000001 | Pass |
| R1i undo, index journal | changed depth 10 | 0.676 / 0.678 / 0.683 | 4.000001 | Pass |
| R1i undo, index journal | changed depth 100 | 0.686 / 0.697 / 0.708 | 4.000010 | Pass |
| R1i undo, index journal | cutoff depth 10 | 0.720 / 0.763 / 0.767 | 4.000001 | Pass |
| R2m publication, monomorphic | changed depth 1 | 0.968 / 0.971 / 0.929 | 4.000001 | Pass |
| R2m publication, monomorphic | changed depth 10 | 1.068 / 1.063 / 1.016 | 4.000001 | Pass |
| R2m publication, monomorphic | changed depth 100 | 0.982 / 0.905 / 0.877 | 4.000019 | Pass |
| R2m publication, monomorphic | cutoff depth 10 | 0.925 / 0.980 / 0.980 | 4.000001 | Pass |
| R06 control, issue 06 kernel | changed depth 10 | 0.511 / 0.511 / 0.514 | 4.000001 | Reference |
| R1n control, no journal | changed depth 10 | 0.569 / 0.571 / 0.572 | 4.000001 | Control |

Allocation is 4 words at every depth and for every candidate. This value equals
the issue 06 result, so the rollback machinery adds no allocation after warm-up.

The two functor candidates fail the same row. Their per-node cost comes from the
functor state record and, for R1, from an unnecessary commit walk. Every
monomorphic candidate passes every row.

The selected index-journal candidate has the largest margin. Its worst ratio is
0.769.

### Failure and retry edge row

The matrix requires one Eta-only row for this issue. The reference is the pinned
pre-redesign revision `d04d6e2bedc87ab22326af5cc03c339406177a67`. The worktree
`lib/` tree has no difference from that revision.

The candidate must not exceed the reference allocation. Its wall time must not
exceed the reference median in two of three pairs. The failing node is the last
node of the chain in both probes.

| Depth | Reference words | R1i words | Reference ns | R1i ns in each pair | Result |
|---:|---:|---:|---:|---|---|
| 1 | 1,227.0005 | 8.000001 | 1,030.09 / 1,028.96 / 1,030.76 | 74.35 / 74.01 / 74.85 | Pass |
| 10 | 2,199.0009 | 8.000002 | 2,572.55 / 2,569.98 / 2,584.71 | 218.86 / 221.09 / 215.83 | Pass |
| 100 | 11,919.0073 | 8.000019 | 17,541.63 / 17,561.16 / 17,555.42 | 1,597.71 / 1,672.37 / 1,676.14 | Pass |

The candidate allocates 8 words at every depth. The eight words are two source
enqueue wrappers, one for the failed attempt and one for the retry.

The reference allocation grows with depth and with the position of the failing
node. The candidate allocation does neither.

The reference successful rows reproduce the frozen `729 + 68d` formula exactly at
797, 1,409, and 7,529 words. This agreement validates the reference probe against
[Eta execution-cost decomposition](eta-execution-cost-decomposition.md).

### Public reference context

The public synchronous layer of the reference costs more than its raw layer. The
gate does not use these rows.

| Depth | Failed retry | Successful |
|---:|---|---|
| 1 | 2,536.72 ns / 3,055 words | 1,592.85 ns / 2,059 words |
| 10 | 4,051.25 ns / 4,027 words | 2,465.99 ns / 2,671 words |
| 100 | 19,183.44 ns / 13,747 words | 11,323.26 ns / 8,791 words |

### Cost attribution

The probe contains four controls that differ by one factor each. `R06` is the
issue 06 kernel, copied without change. `R1n` adds the extra node fields and the
admission frontier, but records no journal entry, so it is a timing control and
not a correct kernel. `R1m` adds the pointer journal. `R1i` adds the index
journal instead.

The in-process `R06` control reproduces issue 06 at 18.74, 52.40, and 523.09
nanoseconds. This agreement makes the deltas comparable.

A changed chain of depth `d` writes `d + 1` nodes.

| Factor | Depth 10 | Per node | Depth 100 | Per node |
|---|---:|---:|---:|---:|
| Extra fields and admission frontier | 6.0 ns | 0.55 ns | 20.9 ns | 0.21 ns |
| Index journal | 11.1 ns | 1.01 ns | 156.0 ns | 1.54 ns |
| Pointer journal | 43.0 ns | 3.91 ns | 357.3 ns | 3.54 ns |
| Saving from indices | 31.9 ns | 2.90 ns | 201.3 ns | 1.99 ns |

The pointer journal costs about 3.5 times the index journal. The store
`journal.(i) <- Obj.repr node` writes a pointer into a heap array, so it crosses
the runtime write barrier. An integer store does not.

The probe does not count write-barrier calls. This evidence is a timing
attribution, not a symbol count.

The loop shape is not a factor. A control with `Array.iter` measures 99.31 to
100.28 nanoseconds at depth 10, against 100.76 to 101.77 nanoseconds for the
explicit loop. Both selected kernels keep the explicit issue 06 loop.

The rollback journal is therefore not free, even though it allocates nothing. The
selected kernel costs 1.0 to 1.5 nanoseconds for each changed node. That cost is
the price of SB10.

### Selection between eligible candidates

Both `R1i` and `R2m` pass every applicable gate. The matrix ranks eligible
candidates by module depth, then worst allocation ratio, then worst wall-time
ratio.

| Criterion | R1i sparse undo | R2m prepared publication | Winner |
|---|---|---|---|
| Module depth | One read mode | Two read modes, one for children and one for cutoffs | R1i |
| Worst allocation | 4 words | 4 words | Equal |
| Worst wall-time ratio | 0.769 | 1.068 | R1i |

`R2m` is faster when a pass fails. Its depth-100 failed-retry median is 1,849 to
1,853 nanoseconds, against 1,598 to 1,676 nanoseconds for `R1i`. `R1i` still wins
that row, because its cheaper success path also serves the retry.

### Graph sizes and operation counts

The matrix requires these values for the edge row.

| Row | Graph objects | Reference operations | Candidate operations |
|---|---:|---:|---:|
| failed retry, depth 1 | 3 | 524,288 | 8,388,608 |
| failed retry, depth 10 | 12 | 262,144 | 4,194,304 |
| failed retry, depth 100 | 102 | 32,768 | 524,288 |

The failing node is the last map of the chain in both probes. The reference probe
also measures the first and middle positions at depth 10.

## Limits

The measured workloads use integer values and static topology. The prototype
does not prove generic or boxed value storage.

The prototype does not prove these items:

1. rollback for dynamic topology, scopes, or keyed children
2. post-publication failure, observer retry, or disposal
3. cancellation and interruption before publication
4. typed graph errors other than reentry
5. monotonic counter overflow
6. timer intent rollback
7. adapter cost for Effect, lane, Eio, observers, or timers

The R3 falsification uses a two-node model of the read rule, not the complete
kernel. It rejects the tested lazy rule. It does not reject every conceivable
lazy representation.

The reference row uses one demanded scalar chain. It has no branch, shared node,
bind, or keyed node. The comparison therefore covers the pure-defect path only.

The touched buffer holds `Obj.t` slots in the prototype. A production kernel
needs one existential node type instead.

## Decision

Use a sparse undo journal with an index buffer. Keep these five parts:

1. one undo slot and one write stamp in each node
2. one reusable index journal with an O(1) commit
3. a reverse rollback walk that restores values and clears write stamps
4. a retained admission frontier that a failed pass replays
5. a frontier drain that clears the height buckets and the queue stamps

The execution seam does not change. Failure keeps the interface from issue 06:

```ocaml
val set : t -> 'a var -> 'a -> unit
val stabilize : t -> (stabilization, error) result
```

Reject the tested prepared publication, lazy epoch, and persistent models for
the static path.

## Constraints for later issues

The next prototypes inherit these rules.

### Issue 08, dynamic topology and keyed work

The undo journal holds dense node indices. Invalidation and reuse must not let a
stale index name a different node. Issue 08 must choose the index lifecycle. Its
options include monotonic indices with tombstones, and a free list with a
generation check.

The rollback surface grows with topology. A failed pass must also restore edges,
scopes, keyed tables, and output roots. Each addition must keep the static path
at 4 words and must not walk more than the affected topology.

The O(1) commit leaves a bounded stale prefix in the journal. In a static graph
that prefix retains nothing extra. Issue 08 must define where a removed node
leaves the journal.

### Issue 09, effect seam and runtime

The reentry guard must run before any state change. A rejected nested attempt
must not consume the rollback state of the outer pass.

Cancellation before publication is one more pre-publication failure. It must use
the same rollback path as a defect.

The measured loop discards the raw result value. An adapter that consumes the
result pays two words for the result block at the adapter layer.

### Issue 10, timer and observer edges

Post-publication failure must not use the rollback path. Observer delivery,
timer lifecycle, and disposal run after the journal is empty.

The admitted-source list must clear at publication, not at the end of the
operation. A write from an observer callback belongs to the next pass.

### Issue 11, integrated finalist

The keyed statistics record has a public `reconciliation_rollback_count` field.
The finalist must count one completed rollback for each failed keyed plan.
