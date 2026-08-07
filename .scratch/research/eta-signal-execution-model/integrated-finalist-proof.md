# Integrated finalist proof

Date: 2026-08-07

## Scope

This report answers the
[Integrated finalist proof](../../../docs/wayfinder/eta-signal-execution-model/issues/11-integrated-finalist-proof.md)
ticket.

The probe implements the complete public Signal and Signal Map interfaces.
It uses one selected core and one selected edge driver.
It does not use `Eta_signal.Make`, `Eta_signal.Make_no_error`, or
`Eta_signal_kernel` as candidate implementation code.

## Answer

No.

The integrated finalist passes the complete behavior gate.
Its raw allocation passes every matched ceiling.
Its dynamic and keyed raw wall time also passes every matched row.

The complete public wall time fails every workload in all three pairs.
Three static raw wall-time rows also fail.
Two of eight Eta-only edge rows fail.

The finalist is not eligible for production selection.

## Implementation

The durable probe is in
[`integrated-finalist-probe/`](integrated-finalist-probe/).

The selected implementation has these layers:

1. `selected_core.ml` owns typed propagation, rollback, slots, bind, and keyed work.
2. `selected_edges.ml` owns observer, timer, cleanup, and stream edge protocols.
3. `selected_factory_fresh.ml` supplies the complete public alternative factory.

The core uses existential typed nodes and a sparse integer undo journal.
It also uses generation-safe slots and owner-local structural capsules.
Pass commit clears retained indexes in constant time.

The probe retains `finalist_factory.ml` as an earlier control.
The Dune targets do not link this control into the selected candidate.

## Behavior evidence

The generated suites substitute only the fresh alternative factory.
The source manifest freezes each copied production test source.

| Suite | Result |
|---|---:|
| Public Signal | 14 of 14 |
| Signal contract | 49 of 49 |
| Signal model | 21 of 21 |
| Lifecycle and timer | 64 of 64 |
| Signal Stream | 18 of 18 |
| Persistent Signal Map | 12 of 12 |
| Keyed Signal Map | 6 of 6 |
| Generated Signal properties | 40 of 40 |
| Finalist-native replacements | 3 of 3 |
| Negative compilation | Pass |
| Selected core and edge gates | Pass |

The model and property suites include generated graphs and failure traces.
The lifecycle suite includes interruption, rollback, disposal, timers, and runtime provenance.

The selected core also passes a 100,000-parent wide-attachment gate.
This gate records exactly one insert per parent and no adjacency search.

## Measurement environment

The candidate source is commit `31337140`.
The performance harness source is commit `a3fe7ac8`.
The edge harness source is commit `6167a4fa`.

The host uses an AMD Ryzen 9 9950X processor and Linux 7.1.3.
Each process uses CPU 2.
The toolchain is OxCaml `5.2.0+ox` and Dune `3.22.2`.
The Dune profile is `release`.

The reference and candidate use the same environment.
The performance commands use the native Eio backend.

## Matched performance evidence

Each process uses the frozen calibration rule and nine measured samples.
Each row has three fresh CPU-pinned reference and finalist process pairs.

The raw and public samples are in
[`matched-results.csv`](integrated-finalist-probe/matched-results.csv).
The process medians are in
[`matched-summary.csv`](integrated-finalist-probe/matched-summary.csv).

The pass counts in this table are out of three pairs.

| Workload | Public wall | Raw wall | Raw words | Allocation |
|---|---:|---:|---:|---:|
| Changed depth 1 | 0 | 3 | 0 | 3 |
| Changed depth 10 | 0 | 1 | 0 | 3 |
| Changed depth 100 | 0 | 1 | 0 | 3 |
| Cutoff depth 10 | 0 | 0 | 0 | 3 |
| Dynamic switch | 0 | 3 | 47 | 3 |
| Keyed data, 10,000 | 0 | 3 | 214 | 3 |
| Keyed data, 100,000 | 0 | 3 | 262 | 3 |
| Keyed membership, 10,000 | 0 | 3 | 368 | 3 |
| Keyed membership, 100,000 | 0 | 3 | 422 | 3 |
| Keyed child, 10,000 | 0 | 3 | 89 | 3 |
| Keyed child, 100,000 | 0 | 3 | 113 | 3 |

Static allocation is less than 100 words at every depth.
Dynamic and keyed allocation stays below each pinned inclusive ceiling.

The complete public wall-time ratios are not close to `1.20`.
The smallest ratio is `20.859` for the depth-100 changed row.
The largest ratio is `123210.750` for the 100,000-key child row.

The other public ratios have these three-pair ranges:

| Workload | Smallest ratio | Largest ratio |
|---|---:|---:|
| Changed depth 1 | 108.255 | 111.897 |
| Changed depth 10 | 54.483 | 58.390 |
| Cutoff depth 10 | 131.535 | 136.426 |
| Dynamic switch | 1504.148 | 1710.295 |
| Keyed data, 10,000 | 520.576 | 588.242 |
| Keyed data, 100,000 | 9298.514 | 10394.970 |
| Keyed membership, 10,000 | 326.381 | 353.733 |
| Keyed membership, 100,000 | 5695.177 | 6439.803 |
| Keyed child, 10,000 | 5828.944 | 6119.399 |

## Eta-only edge evidence

The edge runner uses the same operation tape for each side.
The reference uses production Signal at pinned revision
`d04d6e2bedc87ab22326af5cc03c339406177a67`.

The production Signal source has no change from that revision.
The candidate uses the complete fresh factory with the same Eta/Eio runtime.

The samples are in
[`edge-results.csv`](integrated-finalist-probe/edge-results.csv).
The process medians are in
[`edge-summary.csv`](integrated-finalist-probe/edge-summary.csv).

| Workload | Candidate words | Reference words | Wall result | Allocation result |
|---|---:|---:|---:|---:|
| Failed retry, depth 1 | 3,026 | 7,717 | 3 of 3 | 3 of 3 |
| Failed retry, depth 10 | 3,368 | 9,211 | 3 of 3 | 3 of 3 |
| Failed retry, depth 100 | 7,808 | 24,151 | 3 of 3 | 3 of 3 |
| Dynamic-scope cleanup | 4,073 | 7,304 | 0 of 3 | 3 of 3 |
| Cancelled contender | 4,132 | 7,559 | 3 of 3 | 3 of 3 |
| Observer failure and retry | 7,178 | 11,018 | 3 of 3 | 3 of 3 |
| Observer disposal | 310,969 | 6,169 | 0 of 3 | 0 of 3 |
| Timer cycle | 9,614 | 21,548 | 3 of 3 | 3 of 3 |

Dynamic-scope cleanup takes `182970` to `220952` nanoseconds.
The reference takes `8911` to `8996` nanoseconds.

Observer disposal takes `1630003` to `1647210` nanoseconds.
The reference takes `8777` to `8792` nanoseconds.

## Construction result

The first integrated run found quadratic keyed construction.
Two independent scans caused this error.

Fresh parent attachment searched a growing dependent list.
Each keyed child also scanned the complete initializer list.

The final probe uses constant-time fresh attachment.
It also initializes only the entries that one child adds.

Setup for 20,000 keyed children decreased from `22.314` seconds to `0.102` seconds.
The 100,000-key public workload then completed as a normal fresh process.

## Decision

Reject this integrated finalist for production selection.

Keep its implementation as a production-design input.
The behavior result proves that one unified selected architecture can implement the complete interface.

The performance result locates the remaining work at the public adapter and two lifecycle paths.
The raw dynamic and keyed representation is not the rejection cause.

The next finalist must remove repeated public execution crossings.
It must also remove graph-history work from dynamic cleanup and observer disposal.

Issue 12 cannot measure the depth of a selected production interface from this rejected finalist.
The map needs another finalist before issues 12 through 14 can continue.

## Commands

The complete behavior gate uses this command:

```sh
env BUILD_TIMEOUT=300s SUITE_TIMEOUT=120s \
  nix develop -c \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh \
  tests
```

The matched matrix uses this command:

```sh
env BUILD_TIMEOUT=300s CPU=2 \
  nix develop -c \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh \
  performance
```

The matched command exits with status 1 because every public row is rejected.

The Eta-only matrix uses this command:

```sh
env BUILD_TIMEOUT=300s CPU=2 \
  nix develop -c \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run_edges.sh
```

The edge command exits with status 1 for the two rejected edge rows.
