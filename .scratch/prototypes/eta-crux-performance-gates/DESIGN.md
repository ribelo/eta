# Eta Crux performance-gate prototype

## Purpose

This throwaway prototype tests the shape of the V1 benchmark contract. It does
not measure Eta Crux because the production package does not exist.

The executable measures all required scenario classes with a small model. The
model makes the statistics and gate rules concrete. Production benchmarks must
replace each modeled operation without changing the scenario names or
observation boundaries.

## Proposed benchmark matrix

| Scenario | Production operation | Main size | Hard deterministic gate |
| --- | --- | ---: | --- |
| Complete advancement | One admitted action through delivery and post-commit admission | 100,000 repetitions | One commit and one delivery per action |
| Unchanged recomputation | Stabilize an unchanged live root | 100,000 repetitions | Zero transition calls and zero changed-child visits |
| Changed keyed child | Change one retained child | 10,000 and 100,000 children | One changed-child visit |
| Adapter reconciliation | Deliver and reconcile one changed persistent output | 10,000 and 100,000 rows | One delivery and one host mutation |
| Overlapping cleanup | Remove one child while its cleanup is blocked | 10,000 repetitions | New work starts after cancellation request and before cleanup completion |
| Identity driver | Run the common scenario through direct typed delivery | 100,000 repetitions | Zero wire values, codecs, lookups, and remote handles |
| Serialized driver | Run the same scenario through loopback framing | Payloads of 0 B, 64 B, and 4 KiB | Report codec time, registry lookups, and wire bytes separately |
| Disabled telemetry | Run complete advancement with a disabled capability | 100,000 repetitions | Zero points, attributes, spans, and retained telemetry state |
| Bounded state | Saturate and churn each bounded structure | Each declared capacity plus 25% | Cardinality never exceeds its contract bound |

The keyed benchmark does not require constant lookup. It reports key
comparisons and changed-child visits separately. The deterministic comparison
ceiling comes from `eta_signal_map` and its `Map.S` contract.

An export registry has no independent numeric capacity. Its cardinality is at
most the number of live export nodes. A serialized handle registry has the same
bound for the active session. The benchmark removes half the exports, replaces
the session, and makes sure that no old handle remains.

## Proposed statistics

A full run uses 31 samples after five unreported warm-up samples. Each sample
contains enough repetitions to last at least 50 ms.

The report contains these values:

- the mean wall time per operation;
- the standard deviation of wall time per operation;
- the median wall time per operation;
- the p95 wall time per operation;
- the median allocated words per operation;
- deterministic semantic and complexity counters;
- retained words after full major collection for bounded-state scenarios.

The machine fingerprint, compiler, Dune profile, commit, and dirty state remain
part of the existing benchmark envelope. Results from different fingerprints
are not comparable.

## Proposed regression rules

Deterministic gates fail on any violation. These gates include semantic counts,
complexity ceilings, zero-cost identity properties, and capacity bounds.

Allocation gates compare two fresh runs from the same environment. The first
run uses a selected Git commit or tag. The second run uses the candidate.

A row fails when allocated words increase by more than 5% and more than one
word per operation. The two-part rule avoids large percentages on a near-zero
baseline.

Wall-time gates compare the same two revisions. A row fails when the median
increases by more than 15% in two of three complete reruns. V1 reports p95 but
does not fail on p95 because local scheduler noise can dominate it.

The disabled telemetry row also has a relative pair. Its median must stay within
5% of the same operation compiled with telemetry emission absent. Its allocation
count must be equal. Lazy capability setup outside the operation has a separate
reported cost.

The serialized driver has no fixed ratio against the identity driver. Codec and
payload costs depend on the application codec. The gate compares each serialized
row with its own baseline.

V1 has no absolute latency target and no checked-in numeric baseline. The
selected Git revision identifies the baseline code. Both revisions produce
fresh local measurements for each comparison.

Generated result files remain local and ignored. Historical reports can record
research, but they never control a performance gate.

## Commands

Run the prototype:

```sh
nix develop -c bash .scratch/prototypes/eta-crux-performance-gates/verify.sh
```

The production quick and full commands use the existing Eta benchmark runner:

```sh
nix develop -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop -c bash bench/run.sh --filter '^eta_crux\.'
```

The production benchmark belongs under `lib/crux/bench/`. The root benchmark
runner invokes it. `dune runtest` does not invoke it.

The project has no CI service. A developer or release process runs the full
command for a selected Git revision and for the candidate. Both runs use the
same machine, compiler track, Dune profile, and benchmark configuration.
