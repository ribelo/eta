---
id: Eta-hac
title: "P0: Typed_fail exception key counter is not domain-safe"
status: open
priority: 0
issue_type: bug
created_at: 2026-05-24T12:50:24.520Z
created_by: backlog
updated_at: 2026-05-24T12:50:30.298Z
dependencies:
  - issue_id: Eta-hac
    depends_on_id: Eta-4ob
    type: parent-child
    created_at: 2026-05-24T12:50:30.298Z
    created_by: backlog
---

# P0: Typed_fail exception key counter is not domain-safe

## description

Bug: Typed_fail module (runtime.ml:18-20) uses `let counter = ref 0; let fresh () = incr counter; !counter` to generate unique exception keys. If Runtime.run is called from multiple domains concurrently, the non-atomic ref increment can race, producing duplicate keys. Two Catch/Retry blocks on different domains receiving the same key could cause an exception intended for one to be erroneously caught by the other.

Location: packages/eta/runtime.ml:18-20

## design

Change counter to Atomic.t and use Atomic.fetch_and_add. Simple fix: `let counter = Atomic.make 0; let fresh () = Atomic.fetch_and_add counter 1`. No API change.

## acceptance criteria

Typed_fail.counter is Atomic.t. Redundancy: no runtime test required for a language-level fix, but existing typed-failure tests (Catch, retry) continue to pass under dune runtest --force.
