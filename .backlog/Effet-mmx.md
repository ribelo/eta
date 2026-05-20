---
id: Effet-mmx
title: Capabilities.meter trait + Effet.Metric module + Effet_otel metrics
  exporter (V-O11)
status: closed
priority: 3
issue_type: epic
created_at: 2026-05-19T14:17:00.287Z
created_by: backlog
updated_at: 2026-05-19T14:34:31.495Z
closed_at: 2026-05-19T14:34:31.495Z
close_reason: "V-O11 landed: Capabilities.meter trait, Meter module,
  Effect.metric_update AST node, Effet_otel meter adapter to OTLP/JSON
  /v1/metrics, aggregate_points helper (gauges latest-wins, counters sum).
  Metrics.test.ts ported with 4 passing tests including JSON-body verification
  via on_send capture."
---

# Capabilities.meter trait + Effet.Metric module + Effet_otel metrics exporter (V-O11)

## description

Effect-TS's effect/Metric registry maps to OTel ResourceMetrics at collection time, supporting gauges (double + bigint), counters (cumulative + incremental, double + bigint), histograms. Effet has no metrics module. Port of @effect/opentelemetry/test/Metrics.test.ts is currently a documented skip in packages/effet-otel/test/test_metrics.ml. Implement: Capabilities.meter class type (counter / gauge / histogram), small Effet.Metric module typed for OCaml (incremental vs cumulative as variant, value type as phantom: int Counter.t, float Gauge.t), Effet_otel.meter adapter targeting OTLP/JSON /v1/metrics, optional bridge to the prometheus opam package for users who already expose /metrics.

## acceptance criteria

Metrics.test.ts ports become passing tests in packages/effet-otel/test/test_metrics.ml. Capabilities.meter documented in capabilities.mli. Counters and gauges (double + int) round-trip through OTLP and arrive at motel with correct aggregation temporality and value type. Cumulative vs incremental counters distinguished correctly.
