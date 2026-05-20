---
id: Effet-9qk
title: "Survival lab: Logger and Meter as core AST nodes — should they be
  adapters instead?"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T18:40:30.607Z
created_by: backlog
updated_at: 2026-05-19T18:46:48.083Z
dependencies:
  - issue_id: Effet-9qk
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:48.083Z
    created_by: backlog
---

# Survival lab: Logger and Meter as core AST nodes — should they be adapters instead?

## description

Review 2 §3 calls Effect.log and Effect.metric_update 'likely overbuilt'. Both shipped as core AST constructors via V-O10 / V-O11. The reviewer's challenge: span correlation is achievable through an existing OCaml Logs reporter that reads Effect.current_span on emit, plus an existing metrics registry. If correlation works without the AST nodes, the AST nodes are unearned.

This is a deletion-pressure lab. The hypothesis is that Log and Metric_update should not exist as Effect AST constructors — they should be adapters around standard OCaml logging/metrics ecosystems that consult the runtime's active span context.

Risk if confirmed: removing two GADT cases is a public API break and forces every effet-otel logger/meter test to reroute through adapters. Risk if rejected: nothing changes, but the rationale finally exists in the journal.

## design

Branch A: keep current Log and Metric_update AST nodes as today.
Branch B: delete both AST nodes; reimplement effet-otel logger/meter as:
- packages/effet-otel/logs_bridge.ml: a Logs reporter that reads the active span from Eio.Fiber.create_key on each emit and forwards to OTLP.
- packages/effet-otel/meter_bridge.ml: a metrics registry that reads the same key when capturing measurements.

Run identical fixtures through both branches. Compare:
- LOC delta in core (effet) and effet-otel
- ergonomics: how does an app emit a log inside a span? (Branch A: Effect.log; Branch B: Logs.info ~src ...; both should produce a record with the right traceId)
- type signature impact (does Branch B affect any Effect.t signature? probably not)
- whether the existing Logger.test.ts ports still pass without changing the test bodies

If Branch B passes the same tests with fewer AST nodes and similar ergonomics, V-O10/V-O11 are reopened.

## acceptance criteria

scratch/log_meter_survival/ runs Branch A and Branch B against the same fixture suite. journal.md gains a V-LMv1..V-LMvN decision diary citing concrete LOC, ergonomic, and test-equivalence evidence. Recommendation: (a) keep current AST nodes with documented reason; (b) delete Log and Metric_update AST nodes, reroute through adapters — capture as migration epic. 3h time budget.
