# ADR 0002: Exporter Self-Metrics

Status: Accepted

Date: 2026-05-24

## Context

Track O requires eta-otel to expose its own exporter health: export rate,
queue depth, and dropped items. The exporter already owns bounded mailboxes,
a drain counter, and one Eta daemon that merges trace, log, and metric
batches. Recording self-metrics through the public meter capability would
feed the exporter back into itself and risk an unbounded metric-export loop.

Dogfooding exposed one missing Eta primitive: Eta_stream.Mailbox tracked
dropped values but did not expose current queue depth. eta-stream now exposes
Mailbox.length so consumers can report depth without reaching into mailbox
internals.

## Decision

eta-otel records self-metrics as internal Eta.Meter.point values:

- Trace, log, and application metric exports enqueue one follow-up self-metric
  batch after each export attempt while the original batch is still counted as
  in-flight.
- Self-metric exports do not enqueue another self-metric batch.
- Self-metrics use their own bounded mailbox and configurable OTLP path, so
  applications can disable or reroute exporter health metrics without corrupting
  application metrics or logs.
- Queue depth comes from Mailbox.length; cumulative drops come from
  Mailbox.dropped.
- Export POSTs still use eta-http with observability suppression, so the
  self-metrics do not include eta-http internal spans, logs, or metrics.

The exported metric names are:

- eta_otel.export.batches
- eta_otel.export.items
- eta_otel.queue.depth
- eta_otel.queue.dropped
- eta_otel.in_flight

## Consequences

Exporter health is visible through the same OTLP metrics endpoint as
application metrics. The design reports export attempts and attempted item
counts; it does not yet split success and failure counts.

The first trace or log export now causes one follow-up self-metrics export.
Tests that inspect raw send counts must count by OTLP path rather than assume
one POST per emitted application signal.

eta-stream's new Mailbox.length is intentionally narrow. It exposes observable
mailbox state without exposing queue mutation or capacity policy.

## Verification

- test/stream/test_eta_stream.ml checks mailbox length before
  close and after drain.
- test/otel/run.ml checks self-metrics are exported once for a
  trace export and do not recursively schedule another metrics POST.
- eta-otel retry tests count trace-path attempts, proving OTLP 408 remains
  non-retryable and 429 remains retryable after self-metrics add a metrics
  POST.
