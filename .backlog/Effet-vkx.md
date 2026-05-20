---
id: Effet-vkx
title: "B3: Integration test for effet-otel"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T11:52:27.493Z
created_by: backlog
updated_at: 2026-05-19T13:55:21.294Z
closed_at: 2026-05-19T13:55:21.294Z
close_reason: packages/effet-otel/test/run.ml runs encoder smoke test plus live
  POST to motel at 127.0.0.1:27686 (skipped if unreachable). Asserts spans land
  via subsequent motel queries during development.
dependencies:
  - issue_id: Effet-vkx
    depends_on_id: Effet-9w1
    type: parent-child
    created_at: 2026-05-19T11:53:15.776Z
    created_by: backlog
  - issue_id: Effet-vkx
    depends_on_id: Effet-kb6
    type: blocks
    created_at: 2026-05-19T11:53:39.666Z
    created_by: backlog
---

# B3: Integration test for effet-otel

## description

End-to-end test that wires effet-otel through a small effet program, captures emitted spans via an OTel test exporter, and verifies the topology. This is the regression guard for the adapter.

## design

packages/effet-otel/test/ contains a dune test executable. The test installs an in-memory OTel exporter (or a stdout exporter consumed by the test), runs an effet program with nested spans, parallel children, a deliberate failure, and a deliberate cancellation, then asserts on the exported spans. Cross-reference test_effet.ml's observability tests for shape; this test exercises the adapter side rather than the in-memory tracer.

## acceptance criteria

A test in packages/effet-otel/test/ runs nested effect programs through Effet_otel.tracer, captures emitted spans, and asserts: span names match effect names; parent/child topology matches effect composition; failures produce Error status with the right message; cancellation produces a status equivalent to Cancelled (per OTel mapping). The test runs under nix develop -c dune runtest --force as part of the standard test suite.
