# Performance and zero-cost gates

Type: grilling
Status: resolved
Blocked by: 09, 10, 11, 12

## Question

Which measurable performance gates constrain the design?

Specify gates for no changed values, one changed value among many, and one
changed keyed row among 10,000 and 100,000 rows.

Also specify attachment with many active values, encoded bytes proportional to
changed values, and zero allocation when the capability is absent.

Name workloads, observation points, counters, thresholds, baselines, and
failure criteria. Separate semantic complexity bounds from benchmark budgets.

## Answer

Six approved decisions fix the performance contract. Semantic complexity
bounds are laws with exact, machine-independent gates. Benchmark budgets are
regression-only records. The benchmark suite is the registered executable gate
for every performance law.

### Gate taxonomy

- **Semantic complexity bounds** enter
  `docs/design/eta-crux-v1/semantic-laws.md` as a new `PRF` family. Each row
  carries one claim, one named gate, one observation boundary, and one binding
  tag. The gates are fixed benchmark workloads, not generated properties. The
  registry rows point at `bench_eta_crux.exe` and `bench/compare.exe --gate`
  as the registered executable suite, under the same convention that registers
  external suites.
- **Benchmark budgets** are not laws. The design names no absolute nanosecond
  or word budgets. The first full run of the implementation records the
  baseline in `bench/results/`. From then on, the existing
  `compare.exe --gate` regression rules police each row: median `wall_ns`
  regression above 15 percent, or median `allocated_words` regression above 5
  percent and above one word, in at least two of three run pairs.

### Observation points

- **Workload counters**: deterministic counts inside each workload, using the
  existing counter mechanism (the `commits`, `deliveries`, and `child_visits`
  pattern).
- **Wire byte counter**: total encoded bytes per delivery, observed at the
  format boundary (the existing `Counting_format` pattern).
- **GC counters**: `allocated_words`, `minor_words`, `promoted_words`, and
  `major_words` per operation, from the existing harness.
- **Compile gate**: `[@zero_alloc]` attributes on the pure projection helpers.
- **Comparison gate**: `bench/compare.exe --gate`, extended with the new specs
  named below.

### Counters

New counters: `batch_records`, `encoded_entries`, `encoded_bytes`,
`cutoff_calls`, `key_compare_calls`, and `bootstrap_entries`. The existing
`commits` and `deliveries` counters apply unchanged. Exact counters hard-fail
the workload on any mismatch. `key_compare_calls` is a ceiling counter, not an
exact one.

### Workloads

All scaled rows run at 10,000 and 100,000 active keyed projections. One
population serves the no-change, one-changed, and attachment rows. Names use
the existing `eta_crux.` prefix.

| Workload | Action | Exact counters | Ceiling counters |
|---|---|---|---|
| `projection.no_change.{10000,100000}` | One candidate recomputes; the cutoff suppresses it | `commits=1`, `deliveries=1`, `batch_records=0`, `encoded_entries=0`, `cutoff_calls=1` | `key_compare_calls ≤ 8·N` |
| `projection.one_changed.{10000,100000}` | One candidate changes and passes the cutoff | `batch_records=1`, `encoded_entries=1`, `cutoff_calls=1`, `encoded_bytes` fixed by the test values | `key_compare_calls ≤ 8·N` |
| `projection.attach.{10000,100000}` | Initial commit attaches N projections | `batch_records=N`, `encoded_entries=N` | — |
| `projection.bootstrap.{10000,100000}` | Session replacement with N active projections | `deliveries=1`, `bootstrap_entries=N` | — |
| `projection.absent` | Empty catalog, no publish occurrence, advance and deliver | `commits=1`, `deliveries=1`, `batch_records=0`, `encoded_entries=0` | — |

The `deliveries` counter counts one answered delivery: the workload operation
ends with the single acknowledgment, following the existing
`action.complete_advancement` pattern. D-02 and H-09 gate the one-answer
property itself.

The one-changed rows answer both ticket questions: one changed value among
many, and one changed keyed row among 10,000 and 100,000 rows.

### Semantic complexity bounds (PRF family)

| ID | Law | Gate |
|---|---|---|
| PRF-01 | A commit with no changed values emits an empty batch: zero batch records and zero encoded entries, independent of the active population. | `bench_projection_no_change` |
| PRF-02 | Cutoff and equality work is proportional to recomputed candidates, not to the active population. The scaled rows each recompute one candidate and report `cutoff_calls=1`. | `bench_projection_no_change` and `bench_projection_one_changed` |
| PRF-03 | Preflight identity validation is O(N) in the active population and allocates zero words. The comparator ceiling is 8·N calls. | `bench_projection_no_change` ceiling plus the `[@zero_alloc]` compile gate on the validation walk |
| PRF-04 | Batch records and encoded entries are proportional to changed identities: one for one changed identity, N for an N-attachment commit. | `bench_projection_one_changed` and `bench_projection_attach` |
| PRF-05 | The retained snapshot is persistent. Per-operation `allocated_words` for one changed identity at 100,000 is at most twice the 10,000 value. A logarithmic path grows by about 1.25 times across this range, so twice admits no linear behavior. | `compare.exe` cross-size ratio spec |
| PRF-06 | Encoded bytes are proportional to delivered entries, per profile. Batch push: one-changed `encoded_bytes` are exactly equal at 10,000 and 100,000. Snapshot push: bytes grow with the active population. Pull: notification bytes are constant; pulled bytes are proportional to retrieved entries. | `bench_projection_one_changed` per profile |
| PRF-07 | A bootstrap is one delivery with N entries and one acknowledgment. | `bench_projection_bootstrap` |
| PRF-08 | An empty-catalog, publish-free root allocates exactly the pre-projection baseline words per advance-and-delivery. | `compare.exe` `projection_absent_allocation` spec plus `[@zero_alloc]` helpers |

Binding tags: PRF-06 and PRF-07 are `serialized-only`. The other rows run on
the identity binding and are `identity-only`.

The final pre-projection full-suite result file in `bench/results/` becomes
the recorded baseline for PRF-08. The first full implementation run records
the budget baselines for every new row. `compare.exe` gains three things: the
`projection_absent_allocation` disabled-path spec (equal word medians, wall
within 5 percent, at least two of three pairs), the cross-size ratio spec for
PRF-05, and new `expected_crux_counters` entries for every exact counter
above.

### Profile coverage

All three protocol profiles receive the byte workloads of PRF-06. The
per-profile measurements are evidence for [Select the public interface and
seam](14-select-public-interface-and-seam.md). The selection change deletes
the two rejected profiles with their workloads, counters, and PRF rows, under
the same rule as PRW-18.

### Failure criteria

- An exact-counter mismatch or a ceiling breach fails the workload with
  `failwith`, and the benchmark executable exits non-zero.
- A `[@zero_alloc]` violation fails compilation.
- A zero-delta, ratio, or regression breach fails `bench/compare.exe --gate`.

The gates are opt-in bench infrastructure. `dune runtest` does not execute
them.

### Relationship to later tickets

[Select the public interface and
seam](14-select-public-interface-and-seam.md) is now unblocked and can use the
PRF-06 per-profile byte evidence. [Implementation
plan](15-implementation-plan.md) must name every PRF row, workload, counter,
`compare.exe` specification, baseline file, and `[@zero_alloc]` site from this
answer.

No new ticket is necessary.
