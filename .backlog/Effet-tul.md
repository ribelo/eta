---
id: Effet-tul
title: Capabilities.logger trait + Effet_otel logs exporter (V-O10)
status: closed
priority: 3
issue_type: epic
created_at: 2026-05-19T14:17:00.185Z
created_by: backlog
updated_at: 2026-05-19T14:34:31.495Z
closed_at: 2026-05-19T14:34:31.495Z
close_reason: "V-O10 landed: Capabilities.logger trait, Logger module,
  Effect.log AST node, Effet_otel logger adapter to OTLP/JSON /v1/logs.
  Logger.test.ts ported with 4 passing tests; logs verified end-to-end against
  motel with traceId/spanId correlation."
---

# Capabilities.logger trait + Effet_otel logs exporter (V-O10)

## description

Effect-TS's Effect.log lands in OTel logs when the SDK provides a logRecordProcessor. Effet has no log primitive on the trait surface and no logs subsystem. Port of @effect/opentelemetry/test/Logger.test.ts is currently a documented skip in packages/effet-otel/test/test_logger.ml. Implement: Capabilities.logger class type (log : level -> string -> attrs -> unit), Logger.in_memory + Logger.noop following the tracer pattern, OTLP/JSON /v1/logs exporter in effet-otel, Logs library bridge that reads Effect.current_span and forwards records through Capabilities.logger so apps already using Logs get OTel logs for free.

## acceptance criteria

Logger.test.ts ports become passing tests in packages/effet-otel/test/test_logger.ml (no longer Alcotest.skip). Capabilities.logger documented in capabilities.mli. Effet_otel.create gains optional logger configuration. Logs records emitted within a named span carry spanId+traceId attributes matching the active span. Logs are POSTed to /v1/logs in OTLP/JSON. Verified end-to-end against motel.
