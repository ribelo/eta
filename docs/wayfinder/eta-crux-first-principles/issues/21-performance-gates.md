# V1 performance gates

Type: prototype
Status: resolved
Blocked by: 09, 10, 12, 15, 18

## Question

Which performance budgets and benchmark scenarios can guard the V1 design
without encoding accidental implementation details?

Prototype and measure at least:

- one action and one complete advancement.
- unchanged incremental recomputation.
- one changed child in a large keyed map.
- committed root-output delivery and adapter reconciliation.
- lifecycle removal with overlapping cleanup.
- identity and serialized driver overhead.
- test instrumentation when disabled.
- bounded memory for ingress, requests, exports, and serialized registries.

Select reproducible Nix benchmark commands, input sizes, reported statistics,
and regression thresholds. Keep benchmarks outside `dune runtest`. Do not claim
change-proportional behavior where the selected collection contract provides
only a linear scan.

## Answer

### Gate model

Eta Crux V1 uses relative regression gates and deterministic contract gates. It
has no absolute latency target.

A Git commit or tag identifies the baseline code. A comparison uses fresh runs
of that revision and the candidate in the same environment. The environment
includes the machine, OxCaml version, Dune profile, and benchmark configuration.

Generated measurements remain local. Eta Crux does not use a checked-in numeric
result as a baseline. Historical reports can record evidence, but they never
control a gate.

### Benchmark location and commands

The production benchmark source belongs under `lib/crux/bench/`. The shared
runner and comparison tools remain under `bench/`.

The existing Eta benchmark runner invokes the Eta Crux executable. These are the
standard commands:

```sh
nix develop -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop -c bash bench/run.sh --filter '^eta_crux\.'
```

`dune runtest` does not run these benchmarks. A developer runs the selected
baseline revision and the candidate, then applies the documented thresholds.
The repository has no CI requirement for this gate.

### Sampling and report

A full row uses five unreported warm-up samples and 31 measured samples. The
harness increases the operation count until each measured sample lasts at least
50 ms.

Each row reports:

- mean wall time per operation.
- standard deviation of wall time per operation.
- median wall time per operation.
- p95 wall time per operation.
- allocated, minor, promoted, and major words per operation.
- scenario-specific deterministic counters.

The report also contains the existing machine fingerprint, compiler, Dune
profile, Git revision, and dirty-tree state.

P95 is diagnostic. It does not fail a V1 gate because local scheduler noise can
dominate it.

### Regression thresholds

A wall-time row fails when its median increases by more than 15%. The same
increase must occur in two of three complete comparison reruns.

An allocation row fails when allocated words increase by more than 5% and more
than one word per operation. Both conditions must hold. This rule avoids large
percentages from a near-zero baseline.

Deterministic contract gates fail on the first violation. These gates include
semantic counts, public engine complexity ceilings, zero-wire identity behavior,
and capacity bounds.

### Scenario matrix

The production suite contains these rows:

1. One admitted action through transition, commit, output delivery, and complete
   post-commit admission.
2. One admitted action whose transition leaves its model equal. Application
   counters record skipped dependent projections.
3. One retained child change in keyed collections of 10,000 and 100,000
   children.
4. One committed root-output delivery and adapter reconciliation for persistent
   outputs of 10,000 and 100,000 rows.
5. One child removal while its cleanup remains blocked, followed by admission of
   new work before that cleanup completes.
6. One common driver scenario through the identity binding.
7. The same common scenario through serialized loopback payloads of 0 B, 64 B,
   and 4 KiB.
8. One complete advancement with disabled telemetry and its telemetry-absent
   control.
9. Saturation and churn for bounded structures at capacities 1, 64, and 1,024.
   Each row attempts 25% more admissions than its capacity.

Each workload separates setup from the measured operation. A benchmark cannot
hide root creation, codec creation, or collection construction inside a row that
claims steady-state operation cost.

### Keyed collection limits

The keyed rows report changed-child visits and key comparisons separately. One
changed retained child causes one child-projection visit.

The comparison ceiling comes from the public `eta_signal_map` contract and its
deterministic complexity gate. Eta Crux does not claim constant lookup or generic
change-proportional behavior.

Adapter reconciliation uses a persistent output with shared ancestry. It records
one host mutation for one changed row. A linear-scan control remains visible and
has no change-proportional claim.

### Driver and telemetry controls

The identity row creates no wire frames, encoded payloads, sequence values,
remote handles, or serialized-registry lookups. Any nonzero count fails the
gate.

Serialized rows compare only with the same payload row from the selected
baseline revision. V1 defines no fixed serialized-to-identity ratio because
application codecs and payload sizes control that ratio.

Disabled telemetry creates no points, attributes, spans, or retained telemetry
state. It allocates the same number of words as the telemetry-absent control.
Its median wall time can exceed the control by at most 5%.

### Bounded memory

Ingress cardinality never exceeds its configured capacity. Pending-request
cardinality never exceeds the separate configured request capacity.

An export registry has no second configured capacity. Its cardinality never
exceeds the number of live export nodes. The active serialized session has no
more remote handles than live serialized export nodes.

The memory rows remove half of all exports and replace the serialized session.
After a full major collection, no removed export or old-session handle remains.
Retained words must satisfy the applicable relative allocation gate.

### Prototype evidence

The contract prototype is on branch `prototype/eta-crux-performance-gates` at
commit `5bc26cff`:

- [prototype](https://github.com/ribelo/eta/tree/5bc26cff25851410eb3ffe3f9ab9cd64f9e89f06/.scratch/prototypes/eta-crux-performance-gates)
- [design](https://github.com/ribelo/eta/blob/5bc26cff25851410eb3ffe3f9ab9cd64f9e89f06/.scratch/prototypes/eta-crux-performance-gates/DESIGN.md)
- [results](https://github.com/ribelo/eta/blob/5bc26cff25851410eb3ffe3f9ab9cd64f9e89f06/.scratch/prototypes/eta-crux-performance-gates/RESULTS.md)

The prototype passes in the OxCaml Nix shell. Its measurements validate the
report and gate shape only. They are not Eta Crux performance measurements.
