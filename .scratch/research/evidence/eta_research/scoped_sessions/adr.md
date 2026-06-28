# ADR: Scoped Sessions Ergonomics — Reject Public Helper, Ship Recipe

## Status

**ACCEPTED** — 2026-05-27

## Context

A consumer agent (camelpie PTT streaming) reached for `Effect.Private.daemon`
because `Supervisor.scoped`'s rank-2 callback shape required reshaping the
consumer's API from "return a handle" to "accept a callback." The agent found
this reshape heavy.

The question: does Eta need a public helper for the "long-lived child fiber +
handle escape into a callback" pattern, or do existing primitives plus docs
suffice?

## Decision

**No new public API.** Ship a recipe and worked examples in documentation.

## Consequences

- **Positive:** Smaller public surface. No new abstraction to maintain, test,
  or document long-term.
- **Positive:** Forces each consumer to own its protocol-specific cleanup
  (WebSocket close frames, queue drain, etc.), which a generic helper cannot
  centralize correctly.
- **Negative:** Consumers must reshape handle-returning APIs to callback-shaped
  ones. This adds callback nesting for compositional cases.
- **Negative:** Discoverability depends on documentation quality. A poorly
  written recipe could lead to incorrect `daemon` usage.

## Alternatives considered

### A. `Supervisor.with_child` helper

**Rejected.** The `child` handle type does not match the shared-state handle
that streaming consumers need. The rank-2 constraint that prevents escape is
fundamental to `Supervisor.scoped`; any helper built on it inherits the same
restriction. A helper not built on `Supervisor.scoped` would need new runtime
machinery and would essentially be `daemon` with a different name.

### B. `Resource.with_session` helper

**Rejected.** Does not centralize a real protocol not already handled by
`Supervisor.scoped`, `Scope.start/await/cancel`, and `Effect.acquire_release`.
The "protocol" it would add is a naming convention and canonical cleanup
sequence — valuable documentation, not a new runtime invariant. Only one known
consumer (WebSocket) would benefit.

### D. Refactor WebSocket only, no docs

**Partially accepted for the refactor, rejected for omitting docs.** The
WebSocket refactor is correct and should happen on a separate branch. But the
recipe still needs to be documented so future consumers (OpenAI Realtime,
agent-loop sessions) have a reference.

## Recipe (draft for docs)

### Pattern: Long-lived supervised child with callback

Use `Supervisor.scoped` when a background fiber must outlive the function that
starts it, but the overall lifetime is still bounded by a callback.

```ocaml
open Eta

let with_background_consumer ~init ~loop ~close f =
  Effect.scoped (
    Effect.acquire_release
      ~acquire:(Effect.pure init)
      ~release:close
    |> Effect.bind (fun state ->
           Supervisor.scoped
             {
               run =
                 (fun sup ->
                   let open Supervisor.Scope in
                   let* child = start sup (lift (loop state)) in
                   let* result = lift (f state) in
                   let* () = cancel child in
                   pure result);
             }))
```

Key points:
- `Effect.scoped` + `acquire_release` ensures cleanup on all exit paths.
- `Supervisor.scoped` owns the child fiber.
- `cancel child` on callback exit stops the background loop.
- Use `await child` instead of (or after) `cancel` if child failures must be
  propagated.

## Related

- Lab results: `.scratch/research/evidence/eta_research/scoped_sessions/results.md`
- Coverage matrix: `.scratch/research/evidence/eta_research/scoped_sessions/p_scoped_1/coverage_matrix.md`
- Protocol test: `.scratch/research/evidence/eta_research/scoped_sessions/p_scoped_2/protocol.md`
- Refactor diff: `.scratch/research/evidence/eta_research/scoped_sessions/p_scoped_3/refactor.diff`
