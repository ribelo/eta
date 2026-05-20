---
id: Effet-9w1
title: effet-otel companion package for OpenTelemetry export
status: closed
priority: 3
issue_type: epic
created_at: 2026-05-19T11:52:27.293Z
created_by: backlog
updated_at: 2026-05-19T13:55:21.294Z
closed_at: 2026-05-19T13:55:21.294Z
close_reason: "Epic B done: effet-otel companion package ships full OTLP/JSON
  exporter with zero dependencies beyond effet+eio. Verified end-to-end against
  motel; topology, durations, statuses, attributes all correct. Journal
  V-O7..V-O9 records the OTLP backend hypothesis space and DX decisions."
dependencies:
  - issue_id: Effet-9w1
    depends_on_id: Effet-dsd
    type: blocks
    created_at: 2026-05-19T11:53:38.559Z
    created_by: backlog
  - issue_id: Effet-9w1
    depends_on_id: Effet-ev6
    type: blocks
    created_at: 2026-05-19T11:53:39.464Z
    created_by: backlog
---

# effet-otel companion package for OpenTelemetry export

## description

A separate opam package effet-otel that adapts effet's Capabilities.tracer to the real OpenTelemetry SDK via the opentelemetry-ocaml library. Users who want OTel export include effet-otel and pass an Effet_otel.tracer instance into their env (or runtime, depending on how A3 settles the design fork). Core effet stays free of OTel SDK dependency. This epic is intentionally separate so effet's main package can ship 0.x without dragging in the OTel ecosystem.

## design

Lives in packages/effet-otel/. Depends on: effet (sibling package), opentelemetry, and an OTel exporter package (likely opentelemetry-client-ocurl or opentelemetry-lwt) chosen during B2 implementation. Effet_otel.tracer constructs a value satisfying Effet.Capabilities.tracer: begin_span -> Opentelemetry.Trace.Span.create / set_active; add_attr -> Span.set_attribute; end_span with status -> Span.set_status then Span.finish. A small Resource module builds OTel resource attributes (service.name, service.version, telemetry.sdk.*). Cross-fiber span context propagation reuses the Eio.Fiber.create_key wiring from A4; the OTel adapter just reads the active span stack and uses its top as the parent context. README documents installation, minimal usage, and pointing at an otel-collector.

## acceptance criteria

packages/effet-otel/ builds as a separate opam package effet-otel, declared in dune-project. effet-otel depends only on effet, opentelemetry, and exporter packages necessary for the integration test. Effet_otel.tracer ?service_name ?service_version () returns a value satisfying Effet.Capabilities.tracer. An integration test in packages/effet-otel/test/ runs an effect with the OTel tracer in env, exports to an in-memory test exporter, and verifies the captured spans match the effect tree (names, parents, attrs, status). README.md in packages/effet-otel/ documents installation, a minimal example, and OTel collector configuration.
