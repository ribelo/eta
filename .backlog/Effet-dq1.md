---
id: Effet-dq1
title: "Re-comparison: hand-rolled OTLP transport vs ocaml-opentelemetry adapter
  (post-Yojson)"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T18:39:53.901Z
created_by: backlog
updated_at: 2026-05-20T09:10:05.118Z
closed_at: 2026-05-20T09:10:05.118Z
close_reason: "Completed. OTLP backend re-comparison in scratch/otlp_compare/
  compared current hand-rolled transport vs ocaml-opentelemetry adapter across
  dependency closure, LOC, failure semantics, propagation, and SDK drift.
  Decision diary V-O7r1–V-O7r5 recorded in journal.md lines 6383+.
  Recommendation (c): keep hand-roll but adopt upstream-style retry/backoff/drop
  diagnostics as hardening follow-up. Zero-dependency rationale superseded."
dependencies:
  - issue_id: Effet-dq1
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:35.332Z
    created_by: backlog
  - issue_id: Effet-dq1
    depends_on_id: Effet-2d0
    type: blocks
    created_at: 2026-05-19T18:46:40.071Z
    created_by: backlog
---

# Re-comparison: hand-rolled OTLP transport vs ocaml-opentelemetry adapter (post-Yojson)

## description

Review 1 finding #11 / Review 2 §7. V-O7 chose hand-rolled OTLP/JSON over ocaml-opentelemetry, citing 'zero new dependencies' as one of the wins. Subsequent observability work (logger, meter, links, events, external parents) added Yojson as a dependency, invalidating the zero-dependency claim.

The decision must be re-run with the current dependency baseline. Comparison axes:
- dependency count (current effet-otel vs adapter over ocaml-opentelemetry + its transitive closure)
- LOC (current effet-otel impl vs the adapter)
- failure behaviour (retries, batching, backoff, dropped-span observability)
- propagation surface (extract/inject — Effet-2d0 outcome feeds in)
- semantic conventions (status mapping, span kinds, exception events)
- maintenance cost vs OTel SDK upgrades

If the adapter wins, plan a migration. If hand-rolling still wins for a reason that survives Yojson, document the new rationale and close the comparison.

## design

Build an Effet_otel_alt adapter over ocaml-opentelemetry as a parallel branch in scratch/otlp_compare/. Run both backends against the same effet-otel test suite. Capture:
- packages/effet-otel/ LOC of current vs adapter
- runtime span emission overhead (microbenchmark)
- behaviour under collector-down / collector-slow conditions (current may drop silently)
- whether the adapter inherits propagation, retry, batching from the upstream library

Decision matrix output: which axes flip, which still favour hand-roll, what the recommendation is.

## acceptance criteria

scratch/otlp_compare/ contains both backends running the same fixtures. journal.md gains a V-O7r retrospective entry that supersedes V-O7's claims. Recommendation is one of: (a) hand-roll holds with revised rationale (not 'zero deps'); (b) migrate to ocaml-opentelemetry adapter — capture migration epic; (c) keep hand-roll but cherry-pick adapter behaviour (retry/backoff/dropped-span observability) — capture as small follow-up tasks. 3h time budget. Depends on Effet-2d0 (propagation lab) for the propagation axis.
