---
id: Effet-lnt
title: Span kind on Capabilities.tracer (V-O9)
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T14:24:28.689Z
created_by: backlog
updated_at: 2026-05-19T15:06:40.114Z
closed_at: 2026-05-19T15:06:40.114Z
close_reason: Added Capabilities.span_kind and ?kind to tracer begin_span,
  Effect.named_kind plus ?kind on Effect.fn, in-memory span kind storage/dump,
  OTLP kind encoding (1-5), tests for in-memory Server kind and OTLP JSON
  kind=2, and nix develop -c dune runtest --force passes.
---

# Span kind on Capabilities.tracer (V-O9)

## description

OpenTelemetry semantic conventions classify spans by kind: Internal (1) / Server (2) / Client (3) / Producer (4) / Consumer (5). Capabilities.tracer.begin_span has no kind parameter today, so all emitted spans default to Internal in OTLP. Without kind, OTel consumers cannot distinguish RPC/HTTP server traces from client traces, message-broker producer/consumer relationships from each other, etc. V-O9 explicitly lists this as deferred. Affects effet-otel parity with OTel semantic conventions and any future server/client instrumentation.

## design

Extend Capabilities.tracer.begin_span with optional ?kind:[ `Internal | `Server | `Client | `Producer | `Consumer ]; default `Internal preserves current behavior. Wire kind into Effect.t at the smart-constructor level: add Effect.named_kind : kind:[`Internal|...] -> string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t (or ?kind on Effect.fn). The runtime threads kind through the Named interpreter case to begin_span. In packages/effet/tracer.ml in_memory tracer, store kind on span_record; Tracer.dump exposes it. In packages/effet-otel, map kind to OTLP int (1-5) in the JSON encoder. Existing Effect.named usages stay valid (default kind Internal).

## acceptance criteria

Capabilities.tracer.begin_span accepts ?kind. Effect API gains a way to tag a span with kind (either ?kind on Effect.fn or a new Effect.named_kind). Tracer.in_memory exposes kind on dumped spans. Effet_otel JSON encoder emits the correct kind int. A test in test_effet.ml verifies a Server-kinded effect produces a span with kind = Server in the in-memory tracer dump. A test in effet-otel verifies the OTLP JSON payload includes the correct kind int. Existing 56+ tests pass.
