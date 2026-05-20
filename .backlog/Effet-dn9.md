---
id: Effet-dn9
title: "A5: Observability test suite"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T11:51:53.407Z
created_by: backlog
updated_at: 2026-05-19T12:32:51.719Z
closed_at: 2026-05-19T12:32:51.719Z
close_reason: Added Observability Alcotest group covering fn/location,
  annotation order, nested topology, status mapping, and fiber propagation. Full
  suite passes under nix develop -c dune runtest --force (56 tests).
dependencies:
  - issue_id: Effet-dn9
    depends_on_id: Effet-dsd
    type: parent-child
    created_at: 2026-05-19T11:53:15.877Z
    created_by: backlog
  - issue_id: Effet-dn9
    depends_on_id: Effet-6mx
    type: blocks
    created_at: 2026-05-19T11:53:38.760Z
    created_by: backlog
  - issue_id: Effet-dn9
    depends_on_id: Effet-0mf
    type: blocks
    created_at: 2026-05-19T11:53:38.962Z
    created_by: backlog
  - issue_id: Effet-dn9
    depends_on_id: Effet-4y2
    type: blocks
    created_at: 2026-05-19T11:53:39.263Z
    created_by: backlog
  - issue_id: Effet-dn9
    depends_on_id: Effet-2ft
    type: blocks
    created_at: 2026-05-19T11:53:39.767Z
    created_by: backlog
---

# A5: Observability test suite

## description

Round out the observability surface with a comprehensive test suite covering auto-naming via __FUNCTION__, location attribution via __POS__, nested span topology, ordering robustness, and status-from-cause across all Cause variants. This task locks in the behavior so future refactors cannot silently regress observability.

## design

Add an Observability test group in test_effet.ml. Tests use the in-memory tracer from A1, the smart constructors from A2, the interpreter wiring from A3, and the cross-fiber propagation from A4. Each test asserts on the dumped span list: names, parent_ids, attrs, statuses, durations. The mockable clock from existing Test_clock helpers covers timing assertions. Cross-reference scratch/observability_research/surface_*.ml for the lab patterns being upgraded to real tests.

## acceptance criteria

test_effet.ml gains an 'Observability' Alcotest group with at least: (1) Effect.fn __POS__ __FUNCTION__ produces correct fully-qualified name and loc attr; (2) annotate-before-named and annotate-after-named both attach attrs; (3) outer/inner Named composition produces correct parent_id chain; (4) Cause.Fail produces Error status; (5) Cause.Die produces Error status; (6) Cause.Interrupt produces Cancelled status; (7) Effect.par children inherit parent span. All tests pass under nix develop -c dune runtest --force. The pre-existing 45+ tests continue to pass.
