---
id: Effet-2ft
title: "A1: Tracer module and capability trait"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T11:51:53.507Z
created_by: backlog
updated_at: 2026-05-19T12:32:28.898Z
closed_at: 2026-05-19T12:32:28.898Z
close_reason: Added Capabilities.tracer,
  Tracer.in_memory/noop/as_capability/dump, manual tracer tests, and verified
  nix develop -c dune runtest --force (56 tests).
dependencies:
  - issue_id: Effet-2ft
    depends_on_id: Effet-dsd
    type: parent-child
    created_at: 2026-05-19T11:53:00.139Z
    created_by: backlog
---

# A1: Tracer module and capability trait

## description

Introduce the Tracer abstraction that subsequent observability tasks build on. This task ships the data structures and the in-memory + noop implementations, plus the Capabilities.tracer class type. No interpreter wiring yet; that is A3.

## design

New packages/effet/tracer.ml and tracer.mli. Span has name, parent_id, span_id, attrs, status, started_ms, ended_ms. Tracer.t holds counter, stack (active spans), spans (full record), pending (buffered attrs). Tracer.in_memory : unit -> tracer constructs an object satisfying Capabilities.tracer. Tracer.noop : tracer is a constant whose methods do nothing. Capabilities.tracer class type added to capabilities.ml/.mli with begin_span / end_span / add_attr methods. Pending-attrs semantics: add_attr with empty stack pushes onto pending list; begin_span drains pending into the new span's initial attributes. This makes pipe-order irrelevant for attr attachment. Mirror the lab tracer shape in scratch/observability_research/obs_lib.ml.

## acceptance criteria

Tracer.in_memory () returns an object satisfying Capabilities.tracer. Tracer.noop satisfies Capabilities.tracer. Manual begin_span / add_attr / end_span calls on a fresh in-memory tracer produce a queryable span list with correct parent_id chains, accumulated attrs, and final status. add_attr called with no active span buffers the pair and the next begin_span consumes the buffer into the new span's initial attrs. A unit test in test_effet.ml covers manual span open/close, attr attachment under both orderings, and pending-buffer drain. Full existing test suite continues to pass.
