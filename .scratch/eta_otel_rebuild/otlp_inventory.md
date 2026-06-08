# OTLP capability and wire-shape inventory

Sources:

- Current encoders: packages/eta-otel/eta_otel.ml.
- OpenTelemetry Protocol specification: https://github.com/open-telemetry/opentelemetry-proto.
- OpenTelemetry semantic conventions: https://github.com/open-telemetry/semantic-conventions.
- tracing-opentelemetry docs for semantic convention pass-through: https://docs.rs/tracing-opentelemetry/latest/tracing_opentelemetry/.

## Current exported signals

| Signal | Current endpoint | Current input | Current batch size | Encoder |
| --- | --- | --- | ---: | --- |
| Traces | /v1/traces | ended span record | 32 | encode_traces_request |
| Logs | /v1/logs | Eta.Capabilities.log_record | 64 | encode_logs_request |
| Metrics | /v1/metrics | Eta.Meter.point | 128 | encode_metrics_request |

## Trace fields currently preserved

- traceId
- spanId
- parentSpanId when present
- traceState
- name
- kind
- startTimeUnixNano
- endTimeUnixNano
- attributes
- events
- links
- status

The current encoder also carries baggage in Eta span records for propagation
context, but baggage is not encoded as an OTLP span field.

## Log fields currently preserved

- timeUnixNano
- observedTimeUnixNano
- severityNumber
- severityText
- body.stringValue
- attributes
- optional traceId
- optional spanId

## Metric fields currently preserved

- metric identity: name, description, unit
- Gauge maps to OTLP gauge
- Counter_cumulative and Counter_monotonic map to OTLP sum
- counters use aggregationTemporality = 2
- monotonic counters set isMonotonic = true
- gauges keep latest value per key within a batch
- counters sum values per key within a batch

## Non-goals for this epic

- No protobuf transport.
- No TLS stack.
- No H3 transport.
- No change to trace/log/metric JSON field names.
- No new semantic-convention abstraction.

## Decision

The rewrite must keep the encoder functions and JSON shape behaviorally stable.
Exporter architecture may change, but protocol output stays under current tests
plus any new golden/adversarial checks.

