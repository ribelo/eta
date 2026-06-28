# OS6 Cutover Verdict

Status: accepted.

Question: can eta-otel finish the Track O cutover with an accurate tutorial,
no active effet-otel imports, and encoder benchmarks at or better than the
historical effet-otel baseline?

## Baseline

The benchmark comparison uses
`.scratch/research/evidence/bench-results/eta-otel-encoder-repeat-current.json` as
the historical encoder baseline. It was recorded on the same machine and OxCaml
toolchain family before the OS6 cutover work and contains five samples for each
eta-otel encoder row.

## Evidence

Run:

```sh
nix develop -c bash .scratch/research/evidence/eta_otel_v2/os6_cutover/run.sh
```

Current five-sample encoder means after the same-key metric aggregation fast
path:

| benchmark | baseline mean ns | current mean ns | verdict |
| --- | ---: | ---: | --- |
| `effect.observability.eta_otel.encoder.span.100` | 58174.13 | 54740.91 | better |
| `effect.observability.eta_otel.encoder.span.1000` | 662612.92 | 632429.12 | better |
| `effect.observability.eta_otel.encoder.log.100` | 44059.75 | 40864.94 | better |
| `effect.observability.eta_otel.encoder.metric.100` | 9679.79 | 3433.23 | better |

Allocation rows remained zero minor and zero major words for all four encoder
benchmarks in both baseline and current runs.

The cutover import check searches active packages, bench sources, docs,
README, opam files, and `dune-project` for:

```text
effet-otel|Effet_otel|effet_otel|packages/effet-otel
```

It excludes historical `journal.md`, `.scratch/`, and retained benchmark
evidence. Result: no active legacy imports.

## Decision

OS6 accepts the eta-otel cutover.

- The tutorial now describes the eta-http transport, OTLP retry classifier,
  recursion suppression, and exporter self-metrics.
- The active tree no longer imports or documents the old effet-otel package.
- The focused encoder benchmark is at or better than the historical baseline
  on the measured rows.

## Residual Risk

This is an encoder benchmark and an import cutover check, not a full live
collector throughput benchmark. R-T3 and the Motel test suite cover live OTLP
behavior; this OS6 bench covers the objective's regression question for the
existing encoder benchmark surface.
