---
id: Effet-a78
title: Tracer pending-attrs/links leak across fibers (V-O9)
status: closed
priority: 1
issue_type: bug
created_at: 2026-05-19T14:23:34.996Z
created_by: backlog
updated_at: 2026-05-19T15:00:18.571Z
closed_at: 2026-05-19T15:00:18.571Z
close_reason: "Fixed: in-memory tracer pending attrs/links now use fiber-scoped
  state, regression test added, and nix develop -c dune runtest --force passes."
---

# Tracer pending-attrs/links leak across fibers (V-O9)

## description

Capabilities.tracer.in_memory keeps pending_attrs and pending_links as single mutable lists on the tracer object (packages/effet/tracer.ml lines 45-46, 70-73, 127, 138). Under concurrent fibers — already reachable via shipped Effect.par / Effect.all / Effect.for_each_par — Annotate / Link_span calls made before begin_span on one fiber leak into the next begin_span on a different fiber. The journal flags this verbatim under V-O9: 'the current Tracer.in_memory.pending is shared across fibers; OK for tests, wrong for concurrent users.' This is a present defect in shipped code, not a future feature gap. Reproduction: run Effect.par (Effect.annotate ~key ~value (Effect.named 'left' ...)) (Effect.annotate ~key ~value (Effect.named 'right' ...)) and observe attrs landing on the wrong span.

## design

Move pending_attrs and pending_links from the tracer record into Eio fiber-local storage. The runtime already follows this pattern with active_span_key in packages/effet/runtime.ml line 6. Add two new Eio.Fiber.key values (pending_attrs_key, pending_links_key) keyed on the tracer instance. add_attr / add_link with no active span on the calling fiber writes to the fiber-local buffer; begin_span drains the calling fiber's buffer. Capabilities.tracer signature stays unchanged; this is an in-memory-tracer implementation fix. Effet_otel does not buffer pending and is unaffected.

## acceptance criteria

A new test exercises Effect.par on two children, each calling Effect.annotate before its inner Effect.named, with sleeps inserted to force interleaving. Each branch's annotation lands only on its own branch's span. Existing observability tests continue to pass. nix develop -c dune runtest --force is green.
