---
id: Effet-4yc
title: "B4: README and usage docs for effet-otel"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T11:52:27.192Z
created_by: backlog
updated_at: 2026-05-19T13:55:21.294Z
closed_at: 2026-05-19T13:55:21.294Z
close_reason: packages/effet-otel/README.md covers install, minimal example,
  configuration table, collector targeting, and known gaps
  (metrics/logs/events/links/TLS deferred).
dependencies:
  - issue_id: Effet-4yc
    depends_on_id: Effet-9w1
    type: parent-child
    created_at: 2026-05-19T11:53:15.676Z
    created_by: backlog
  - issue_id: Effet-4yc
    depends_on_id: Effet-vkx
    type: blocks
    created_at: 2026-05-19T11:53:39.967Z
    created_by: backlog
---

# B4: README and usage docs for effet-otel

## description

User-facing documentation for the effet-otel package. Without this, even a working adapter is undiscoverable.

## design

packages/effet-otel/README.md covers: opam install command for effet-otel; minimal example wiring Effet_otel.tracer into a runtime; pointing the resulting OTel SDK at a collector via environment variables or programmatic config; trade-offs vs the built-in in-memory tracer; link to effet's main README and to OpenTelemetry-OCaml docs.

## acceptance criteria

packages/effet-otel/README.md exists, references the same idioms as effet's main README (Effect.fn __POS__ __FUNCTION__), shows installation, minimal example, and a note on collector configuration. The example in the README is also present (compiled) somewhere in the repo to prevent doc drift; either as the example used in B3's test or as an examples/ directory entry.
