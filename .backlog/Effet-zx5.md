---
id: Effet-zx5
title: Stream package hardening before any release (real merge / flat_map_par /
  early-take cancellation / end-to-end tests)
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T18:42:38.446Z
created_by: backlog
updated_at: 2026-05-19T18:47:27.725Z
dependencies:
  - issue_id: Effet-zx5
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:27.725Z
    created_by: backlog
---

# Stream package hardening before any release (real merge / flat_map_par / early-take cancellation / end-to-end tests)

## description

Review 1 finding #10 / Review 2 §9. The Stream research direction survives, but the shipped package has placeholders: sequential fallbacks where parallel semantics are intended, no package-level tests, and known gaps documented in the journal. The reviews flag this as 'premature' — research-justified, but not yet a real abstraction.

Concrete gaps to close:
- merge: today is sequential; should cancel upstream on downstream completion
- flat_map_par: today is sequential; should run inner streams in bounded parallel with backpressure
- early take: from_file |> take 1 |> drain must close the file (the second stream pass found resource leaks under early take)
- bounded queue: cannot deadlock when downstream stops consuming
- env/error rows survive composition

Scope: bring stream package to real-test-passing state, end-to-end fixtures, before any version-bump or external user.

## design

Implement the gaps above against a fixture suite in packages/effet-stream/test/ (or scratch/stream_hardening/ if package layout is still in flux):

1. take_then_close: read 1 chunk from a file stream, call drain, assert file descriptor closed (use Unix.fstat or ulimit observation in the test).
2. merge_cancellation: merge two streams, downstream finishes after first element, both upstream sources are cancelled — verify with a counter that production stopped.
3. flat_map_par_concurrency: 100 inputs, inner stream sleeps 50ms each, with concurrency:10 the total runtime is ~500ms not 5000ms.
4. bounded_queue_no_deadlock: producer sleeps, consumer cancels mid-flight — neither side blocks indefinitely.
5. row_polymorphism: stream pipeline using clock and db services composes its env row correctly through merge and flat_map_par.

Also: review packages/effet-stream/dune for any (skip_diff) or 'TODO' placeholders. Each must either be implemented or documented as deliberate v0 limitation in README.

## acceptance criteria

packages/effet-stream/test/ runs the five fixtures above as passing tests under nix develop -c dune runtest --force. merge and flat_map_par exhibit real concurrent semantics (verified by timing or counter-based fixtures). early take closes resources (verified by fd count or finalizer execution). README.md for the stream package lists any remaining v0 limitations explicitly. journal.md gains a V-Shv1..V-ShvN entry recording what was implemented vs deferred and why. 4h time budget.
