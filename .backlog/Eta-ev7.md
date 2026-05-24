---
id: Eta-ev7
title: "Major: Split test_eta.ml and test_eta_http.ml into focused test modules"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:43:48.880Z
created_by: backlog
updated_at: 2026-05-24T11:47:27Z
closed_at: 2026-05-24T11:47:27Z
close_reason: "Split eta and eta-http monolithic test files into focused runner/module layouts; preserved Alcotest suite and case names; verified targeted package tests and nix develop -c dune runtest --force."
dependencies:
  - issue_id: Eta-ev7
    depends_on_id: Eta-6j9
    type: parent-child
    created_at: 2026-05-24T09:44:20.022Z
    created_by: backlog
---

# Major: Split test_eta.ml and test_eta_http.ml into focused test modules

## description

Issue: packages/eta/test/test_eta.ml is 4016 lines and packages/eta-http/test/test_eta_http.ml is 2709 lines, each registered as a single test executable. This makes targeted review harder, failure isolation worse, and re-running narrow slices during debugging impossible. eta-otel already follows the right pattern: packages/eta-otel/test/run.ml (553L runner) plus test_logger.ml (150L), test_metrics.ml (236L), test_tracer.ml (303L) — about 1240L total split into clear areas.

Locations:
- packages/eta/test/test_eta.ml (4016 lines)
- packages/eta-http/test/test_eta_http.ml (2709 lines)
- Reference pattern: packages/eta-otel/test/

## design

No RED test. Behavior-preserving refactor. Verification = the same Alcotest cases run before and after, with the same pass/fail outcomes.

Fix shape:
- Group test_eta.ml cases by concern. Likely areas (to be confirmed by reading the file): Effect AST + smart constructors, Runtime interpretation, Schedule, Resource, Supervisor / Supervisor.scoped, Channel, Pool, Semaphore, Tracer, Logger / Meter, Effect.Island, Effect.Blocking, Capabilities (random/clock), Soundness gates.
- Move each group into packages/eta/test/test_<area>.ml. Keep helpers (Test_clock, Test_random, expect.* helpers from Eta_test) imported from Eta_test where possible.
- Create packages/eta/test/run.ml that wires the area suites into a single Alcotest run, mirroring eta-otel/test/run.ml.
- Same shape for eta-http: split test_eta_http.ml by area (Header, Url, H1.Write, H1.Parse, H1.Client, H2.Multiplexer, H2.Frame, Body.Chunked, Body.Stream, Transport.Connect, Client.Retry, Client.Idempotency, Tls.Config, Audit, etc.).
- Update packages/eta/test/dune and packages/eta-http/test/dune accordingly. Keep a single test executable per package (the runner) so the test harness shape and CI command are unchanged.

## acceptance criteria

Every test that ran before still runs after, with the same name, and produces the same pass/fail outcome (verify by Alcotest output diff if practical). Each area module is small enough to read in one sitting. Adding a new test for an area means touching one focused file. nix develop -c dune runtest --force passes.
