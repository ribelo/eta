# R-T2 OTLP Capability Inventory

Status: Initial verdict with eta-http follow-up implemented. This is a probe
result from the historical eta-otel rebuild track.

## Question

Which OTLP/HTTP JSON capabilities must eta-otel v2 implement, which current Eta
and eta-http primitives cover them, and where would the rebuild need a new Eta
or eta-http primitive instead of burying substrate code inside eta-otel?

## Evidence Commands

```sh
git log --oneline -12
sed -n '1,240p' packages/eta-otel/README.md
sed -n '1,280p' packages/eta/capabilities.mli
sed -n '1,300p' packages/eta/tracer.mli
sed -n '1,300p' packages/eta/meter.mli
sed -n '1,320p' packages/eta-stream/eta_stream.mli
sed -n '1,240p' packages/eta-http/eta_http.mli
sed -n '1,260p' packages/eta-http/client/retry.mli
curl -fsSL https://opentelemetry.io/docs/specs/otlp/
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/trace/v1/trace.proto
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/logs/v1/logs.proto
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/metrics/v1/metrics.proto
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/collector/trace/v1/trace_service.proto
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/collector/logs/v1/logs_service.proto
curl -fsSL https://raw.githubusercontent.com/open-telemetry/opentelemetry-proto/main/opentelemetry/proto/collector/metrics/v1/metrics_service.proto
```

Observed local state:

- The Eta-1yb prerequisite is present in git history:
  `dcc70a8` Redacted, `d388c64` Log_level, `051fe58` Mutable_ref,
  `96a0a3e` Semaphore, `102a437` Semaphore journal.
- Current `packages/eta-otel` is still the pre-rebuild implementation. Its
  README says it is a hand-rolled HTTP/1.1 client over Eio TCP and its dune file
  depends directly on `eio`, `eio.unix`, and `yojson`.
- eta-http exposes request bodies, response bodies, retry policy helpers,
  configurable response-status retry classification, gzip transducers, and the
  observability `~enabled:false` wrapper required by ADR 0006.

## Hypothesis Ledger

| Candidate | Why it is plausible | Evidence needed to win | Falsifier | Current evidence | Status |
| --- | --- | --- | --- | --- | --- |
| A. Rebuild eta-otel v2 on current Eta + eta-http primitives | Eta has tracer/logger/meter capabilities, Channel/Mailbox/Stream batching, Resource, Schedule, and eta-http POST/retry/body support. | Every required OTLP/HTTP JSON field and transport rule maps to current APIs, with only local encoder code. | Any MUST/SHOULD requires a primitive missing from Eta or eta-http. | Most signal shape and transport maps; the retry classifier gap found by this probe is now closed in eta-http. | Active |
| B. Add an eta-http retry-classifier extension before OS3 | OTLP/HTTP retry rules are stricter than eta-http's default policy. A reusable classifier belongs near HTTP retry, not inside an exporter. | A small eta-http API can express the OTLP status set and still preserve ADR 0005 behavior for normal clients. | eta-http already has a way to customize retryable statuses. | Implemented as `Retry_policy.make ?retry_status`; tests prove OTLP can reject 408 and retry 429. | Accepted / implemented |
| C. Ship protobuf/gRPC/full OTel SDK scope | Official protos define broader signal shapes than eta-otel v1. | Objective includes protobuf, gRPC, SDK processors, histograms, summaries, or profiles. | Objective explicitly bounds Track O to OTLP/HTTP JSON and excludes non-OTLP/HTTP transports. | Objective out-of-scope list excludes gRPC/native transports and current Eta meter cannot express histograms/summaries. | Out of scope |

## OTLP/HTTP Transport Inventory

| OTLP requirement | Spec evidence | Eta / eta-http mapping | Status |
| --- | --- | --- | --- |
| Use HTTP POST for telemetry. | OTLP/HTTP sends telemetry data via HTTP POST. | `Http.Request.make "POST" uri ~body:(Fixed [bytes])`; `Http.request` or wrapped request. | Covered |
| Default endpoints are `/v1/traces`, `/v1/metrics`, `/v1/logs`. | OTLP/HTTP request section names all three paths and request messages. | eta-otel config should keep per-signal paths. | Covered |
| JSON payload uses `Content-Type: application/json`. | OTLP JSON section requires request and response content type. | `Http.Core.Header.add "content-type" "application/json"`. | Covered |
| Trace IDs and span IDs in OTLP JSON are hex strings, not base64. | OTLP JSON section overrides standard protobuf JSON mapping for `traceId` and `spanId`. | Eta trace IDs are already hex strings; exporter must generate and preserve 16-char hex OTLP span IDs for internal Eta span ids. | Covered with encoder obligation |
| Enum fields are encoded as integer values. | OTLP JSON section requires integer enum values. | Local encoder maps span kind, status, severity, temporality to ints. | Covered |
| 64-bit integer fields are decimal strings. | OTLP JSON section requires 64-bit JSON numbers as decimal strings. | Local encoder must string-encode nanosecond timestamps and int64 counters. Existing old encoder does this for many fields. | Covered with tests |
| Client may gzip request content only with `Content-Encoding: gzip`; may request gzip responses with `Accept-Encoding: gzip`. | OTLP/HTTP request and response sections. | eta-http body transducers cover gzip; v2 can start uncompressed and gate gzip behind explicit scope. | Deferred unless gzip is in scope |
| Partial success must not be retried. | OTLP partial success says client MUST NOT retry populated `partial_success`. | eta-otel must read success response bodies enough to detect `partial_success` for all three signals. | Required OS3 behavior |
| Retryable HTTP response codes are only 429, 502, 503, 504; all other 4xx/5xx must not be retried. | OTLP/HTTP retryable response code table. | `Http.Retry_policy.make ?retry_status` lets eta-otel use the OTLP set while preserving eta-http's default 408 behavior for normal HTTP clients. | Covered |
| Honor `Retry-After` on 429/503 and use exponential backoff otherwise. | OTLP/HTTP throttling and connection sections. | `Http.Retry_policy.retry_after` parses the header; `Eta.Schedule` can express backoff/jitter. | Covered |
| Keep connections alive and allow configurable parallel connections. | OTLP/HTTP connection/concurrent requests sections. | eta-http owns pooling; `Eta.Semaphore` can bound exporter-side concurrent exports if needed. | Covered |
| Disable exporter recursion. | Objective and ADR 0006. | `Http.Observability.Tracer.request ~enabled:false`. | Covered |

## Signal Inventory

### Traces

| OTLP field/capability | Eta source | Status |
| --- | --- | --- |
| `resourceSpans[].resource.attributes` | eta-otel config `service.name`, `service.version`, extra resource attrs. | Covered; OS1 should promote to explicit Resource type. |
| `scopeSpans[].scope.name/version/attributes` | Current config has `scope_name` only. | Partial; OS1 should add InstrumentationScope vocabulary. |
| `traceId`, `spanId`, `parentSpanId` | `Eta.Tracer.span.trace_id`, internal span id mapping, parent id/external parent. | Covered with id mapping tests. |
| `traceState` | `Eta.Tracer.span.trace_state`. | Covered. |
| `flags` low byte trace flags | `Eta.Tracer.span.trace_flags`. | Required; old encoder carries the value internally but does not visibly prove it is encoded. Add regression test. |
| `name`, `kind`, start/end timestamps | `Eta.Tracer.span`. | Covered. |
| `attributes`, events, links, status | `Eta.Tracer.span.attrs/events/links/status`. | Covered for string attributes; no numeric/bool AnyValue yet. |
| dropped attribute/event/link counts | No Eta capability. | Encode zero for v2 or omit where allowed; do not claim dropping support. |

### Logs

| OTLP field/capability | Eta source | Status |
| --- | --- | --- |
| `resourceLogs`, `scopeLogs` | Same resource/scope config as traces. | Covered with OS1 vocabulary. |
| `timeUnixNano`, `observedTimeUnixNano` | `Eta.Capabilities.log_record.ts_ms`. | Covered; observed timestamp can equal event timestamp for Eta-origin logs. |
| `severityNumber`, `severityText` | Objective requires `Eta.Log_level`; current capability still uses `Eta.Capabilities.log_level`. | Gap for OS1: converge eta-otel on the canonical Log_level mapping or adapt without reintroducing ad-hoc strings. |
| `body` | `log_record.body`. | Covered as string AnyValue. |
| `attributes` | `log_record.attrs`. | Covered for string attributes. |
| `traceId`, `spanId` | Runtime-populated fields on `log_record`. | Covered. |
| `flags` | Not present on `log_record`. | Optional in OTLP; omit unless runtime log capability grows trace flags. |
| `eventName` | Not present on `log_record`. | Out of v2 scope unless eta logging grows event vocabulary. |

### Metrics

| OTLP field/capability | Eta source | Status |
| --- | --- | --- |
| Gauge data points | `Eta.Meter.Gauge`. | Covered. |
| Sum data points | `Eta.Meter.Counter_cumulative`, `Counter_monotonic`. | Covered; encode cumulative temporality and monotonic flag from kind. |
| NumberDataPoint timestamps and attrs | `Eta.Meter.point.ts_ms`, attrs. | Covered; start time must be tracked by eta-otel aggregation. |
| Int and double values | `Eta.Capabilities.metric_value`. | Covered. |
| Histogram, exponential histogram, summary | No Eta meter vocabulary. | Out of v2 scope; do not fake with gauges/sums. |
| Exemplars | No Eta meter vocabulary. | Out of v2 scope. |
| Metadata attributes, schema URLs | Not in Eta meter/config today. | Optional/deferred; OS1 can include schema URL fields if evidence requires. |

## Cross-Tab

| Criterion | Current Eta + eta-http | Needs eta-http extension | Out of scope |
| --- | --- | --- | --- |
| OTLP/HTTP JSON POST | Strong: request/body/header APIs cover it. | No. | gRPC/protobuf transport. |
| Correct OTLP retry semantics | Strong: Retry-After parser, schedules, and configurable status classifier exist. | No known eta-http gap after `?retry_status`. | Retrying partial success. |
| Trace/log/metric shape | Strong for existing Eta capabilities. | No transport extension. | Histograms, summaries, exemplars, profiles. |
| Recursion avoidance | Strong: ADR 0006 wrapper has `~enabled:false`. | No. | Automatic global instrumentation. |
| Clean-room boundary | Strong if encoder is local and transport is eta-http. | Classifier should live in eta-http if generalized. | Copying SDK/client implementations. |

## Verdicts

- V-Otel-R-T2-1 - Bound eta-otel v2 to OTLP/HTTP JSON for traces, logs, gauges,
  and sums.
  Decision: accepted for the rebuild scope.
  Evidence: objective excludes non-OTLP/HTTP transports; current Eta
  capabilities express spans, log records, gauges, and counters but not
  histograms, summaries, exemplars, profiles, or a full SDK.
  Confidence: High.
  Would change if: the planner explicitly expands Track O beyond the stated
  effet-otel compatibility boundary.

- V-Otel-R-T2-2 - Use eta-http for transport, but do not use its default retry
  classifier unchanged.
  Decision: accepted; follow-up implemented in eta-http.
  Evidence: OTLP/HTTP retries only 429, 502, 503, and 504; eta-http default
  retry policy also retries 408. `Retry_policy.make ?retry_status` now lets
  eta-otel pass the OTLP set without changing eta-http's default behavior.
  Confidence: High.
  Would change if: OS3's exporter fixture shows OTLP needs response-body-aware
  retry classification beyond HTTP status and `Retry-After`.

- V-Otel-R-T2-3 - OS1 must promote Resource and InstrumentationScope vocabulary
  instead of preserving the old stringly config as the only representation.
  Decision: accepted.
  Evidence: OTLP groups all signals by resource and scope; current eta-otel has
  resource attrs and scope name but no explicit type or scope version.
  Confidence: Medium.
  Would change if: OS1 call-site fixtures show explicit types add no static
  safety or clarity over a record config.

- V-Otel-R-T2-4 - Treat `Eta.Log_level` convergence and trace flags as
  correctness obligations for the rebuild.
  Decision: accepted.
  Evidence: objective says LogLevel replaces ad-hoc severity strings; OTLP Span
  and LogRecord define low-byte trace flags. Current old encoder does not prove
  trace flags are emitted and current logging capability still exposes its own
  level variant.
  Confidence: Medium.
  Would change if: core capabilities are intentionally left unchanged by an ADR
  and eta-otel records an adapter decision.

## Next Evidence

1. R-T0: decide whether transparent-cost requires a new dispatch mechanism.
2. R-T3: prove eta-http POST with `~enabled:false` does not recursively trace
   exporter requests against a real collector.
3. Before OS3: write the eta-otel exporter fixture using
   `Retry_policy.make ?retry_status` and prove it never retries 408, 400, or
   partial success.

## Verification

```sh
git diff --check
# exit 0

nix develop -c dune build
# exit 0

nix develop -c eta-oxcaml-test-shipped
# exit 0
# eta-schema tests passed
# ppx_eta: 2 tests passed
# eta-otel: 26 tests passed
# eta-stream: 17 tests passed
# eta: 185 tests passed

nix develop -c dune runtest packages/eta-http --force
# exit 0
# eta-http: 76 tests passed
# eta-http-security: 1 test passed
```

Follow-up production code changed in eta-http:

- `packages/eta-http/client/retry.{ml,mli}`
- `packages/eta-http/test/test_eta_http.ml`
- `.scratch/research/evidence/eta_http_research/adrs/0005-retry-idempotency-replayability.md`
