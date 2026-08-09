# Eta Crux and Bonsai benchmark

This research bundle compares the computation overlap between Eta Crux and
Jane Street Bonsai. It does not compare rendering, transport, requests,
telemetry, or browser functions.

The primary operation contains these steps:

1. Inject one typed action.
2. Apply one state transition.
3. Run one production-driver cycle.
4. Read one typed root result.
5. Complete the required post-commit or lifecycle dispatch.

Both adapters use production interfaces. The Eta adapter uses `Root`. The
Bonsai adapter uses `Bonsai_driver`.

## Workloads

| Workload | Measured change |
|---|---|
| `scalar.changed` | One integer state change and one dependent projection |
| `scalar.equal` | One action that returns the published model |
| `assoc.changed.1000` | One retained child changes in a 1,000-key map |
| `assoc.changed.10000` | One retained child changes in a 10,000-key map |
| `startup.root` | Construct one stateful root and obtain its first output |

Steady-state workloads alternate between two prebuilt states. Input
construction stays outside the timed interval. `startup.root` measures root
construction and first output. Root teardown stays outside its timed interval.

## Compiler rule

Both systems use `oxcaml-compiler.5.2.0minus38`. Bonsai uses the matched package
set `v0.18~preview.130.100+614`.

Do not compare a Bonsai result from upstream OCaml with an Eta OxCaml result.
Do not compare results from two OxCaml compiler revisions.

## Setup

Run these commands from the Eta repository:

```sh
nix develop
.scratch/research/eta-crux-bonsai-bench/setup.sh
```

The script creates an ignored local switch under `.scratch/`. It does not
change Eta's normal project switch.

## Semantic check

Run this command before a measurement:

```sh
.scratch/research/eta-crux-bonsai-bench/run.sh --quick
```

Each timed batch checks action, transition, production-driver-cycle,
observation, projection, child-visit, and changed-row counts. The run stops if
the adapters do not execute the expected work. One cycle means one
`Root.advance` or one `Bonsai_driver.flush`; it does not claim that the engines
perform the same number of internal stabilization calls.

## Full measurement

Choose one physical CPU that has low background load:

```sh
.scratch/research/eta-crux-bonsai-bench/run.sh --cpu 2
```

The runner uses an ABBA process schedule. It records 32 raw samples for each
framework and workload. It calibrates each adapter independently so every
sample reaches the duration floor. The result records every operation count,
and metrics are normalized per operation.

The result contains raw samples and summary ratios. A ratio larger than `1`
means that Eta used more time or allocation than Bonsai.

## Limits

The map rows include each framework's persistent-map and keyed-diff
implementation. These implementations are part of the measured computation
path.

The Eta runtime and Bonsai effect scheduler have different implementations.
The workloads use no application lifecycle effects. Each adapter still runs
the empty post-commit or lifecycle dispatch required before its next
production-driver cycle.

Eta lifecycle removal cancels a scoped job and can settle asynchronously.
Bonsai runs explicit deactivation and activation effects synchronously during
`trigger_lifecycles`. This difference has no neutral completion boundary, so
keyed lifecycle replacement is excluded from quantitative comparison.

The comparison has no aggregate score. Read each workload and metric
separately.

The design evidence and source citations are in
[`../eta-crux/bonsai-performance-comparison.md`](../eta-crux/bonsai-performance-comparison.md).
