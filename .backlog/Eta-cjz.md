---
id: Eta-cjz
title: "eta-otel: Span attribution findings"
status: open
priority: 1
issue_type: epic
created_at: 2026-05-24T12:49:44.342Z
created_by: backlog
updated_at: 2026-05-24T12:49:51.605Z
dependencies:
  - issue_id: Eta-cjz
    depends_on_id: Eta-cu7
    type: parent-child
    created_at: 2026-05-24T12:49:51.605Z
    created_by: backlog
---

# eta-otel: Span attribution findings

## description

P1 finding from the 2026-05-24 code review: add_attr/add_link use pick_latest_open (global latest-open span by highest handle), not fiber-local active span, causing concurrent span attribute/link corruption.

## acceptance criteria

add_attr and add_link take explicit span_id (matching add_event), or eta-otel maintains fiber-local active-span stack. Attribute corruption under concurrency is verified fixed.
