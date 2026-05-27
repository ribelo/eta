# Scoped Sessions Ergonomics — Lab Results

## Lab status: CLOSED

Date: 2026-05-27
Epic: Eta-scoped-sessions-9r5

## Final verdict

**Branch C wins: Recipe in docs, no new public API.**

Branch A and Branch B are rejected. Branch D is partially correct (WebSocket
should be refactored) but the refactor is evidence for Branch C, not a reason
to avoid documenting the recipe.

## Hypothesis space — final status

| Branch | Description | Status | Reason |
|--------|-------------|--------|--------|
| A | `Supervisor.with_child` helper | **REJECTED** | Poor fit for the only matching consumer; `child` handle mismatches shared-state handle; rank-2 escape issues |
| B | `Resource.with_session` | **REJECTED** | Does not centralize a real protocol beyond existing primitives; only serves one known consumer |
| C | Recipe in docs, no new API | **ACCEPTED** | Existing primitives (`Supervisor.scoped` + `Scope.start` + `Effect.acquire_release`) express the pattern; well-written recipe + examples suffice |
| D | Refactor camelpie/WebSocket alone | **PARTIAL** | WebSocket SHOULD be refactored (separate branch), but the recipe still needs to be documented for future consumers |

## Probe summaries

### P-Scoped-1: Consumer survey

Surveyed 5 consumers. **Only 1 (WebSocket) matches the "long-lived child +
handle escape" pattern.** The other 4 use `Effect.Private.daemon` for
legitimately different patterns (background maintenance loops, one-shot async
handlers) where `daemon` is correct.

This falsifies the hypothesis that the pattern is common across multiple
consumers. Branch D's strongest reading ("only camelpie hits it") is
essentially correct, with WebSocket as the one known consumer instead of
camelpie.

**Surprise finding:** HTTP/1 pooled request (`h1_client.ml`) uses `daemon` but
could trivially use `Supervisor.scoped` — it's a one-shot pattern, not a
long-lived session. This suggests some existing `daemon` usage is convenience,
not necessity.

### P-Scoped-2: Protocol centralization test

Tested 5 claimed protocol elements for Branch B:

| Element | Already centralized? | Generic? |
|---------|---------------------|----------|
| Typed failure preservation | Partially | No |
| Cancellation cleanup | Partially | Partially |
| Close fences | **Yes** (`acquire_release`) | Yes |
| Observability seam | No (manual) | Yes, low value |
| Mode/portability fence | **Yes** (`Supervisor.scoped`) | Yes |

**No new invariant is centralized.** Branch B would be a thin wrapper (~40 LOC)
around existing primitives, saving ~5 LOC at one call site. Per H-W4 and the
lab's own criteria, this does not justify a new public API.

### P-Scoped-3: Camelpie/WebSocket refactor

Refactored `lib/http/ws/ws_client.ml` from `Effect.Private.daemon` to
`Supervisor.scoped` + `Effect.acquire_release`.

- LOC delta: +10 in library, ~0 in interface, +1 nesting level at call sites
- `daemon`: fully removable from WebSocket
- Compositional cost: real (callback nesting for multiple connections)
- WebSocket-specific cleanup: cannot be centralized, remains in consumer code

The refactor is viable and validates that Branch C is expressible.

## What was NOT measured

1. **Actual camelpie PTT streaming code.** Not in this repository. The lab
   inferred camelpie's shape from OBJECTIVE.md and validated against the
   closest real consumer (WebSocket).
2. **OpenAI Realtime session runtime.** Only tests exist; no full streaming
   session implementation to survey.
3. **HTTP/2 multiplexer writer-fiber.** Not found in codebase.
4. **Performance delta.** No benchmarks run between daemon and supervised
   approaches.
5. **Migration cost for all consumers.** Only WebSocket was fully refactored
   in the diff.
6. **Contributor survey.** No external developers were asked whether they
   would write the supervised pattern correctly without a helper.

## Recommendations for production

1. **Document the recipe.** Add a section to Eta's docs showing the canonical
   "long-lived supervised child + callback" pattern using:
   - `Supervisor.scoped` for the child fiber
   - `Scope.start` + `Scope.cancel` / `Scope.await` for lifecycle
   - `Effect.acquire_release` for close fences
   - Explicit typed failure handling via `Scope.await`

2. **Refactor WebSocket on a separate branch.** Remove `Effect.Private.daemon`
   from `lib/http/ws/ws_client.ml`. The diff in
   `p_scoped_3/refactor.diff` is the starting point.

3. **Audit other `daemon` usage.** HTTP/1 pooled request (`h1_client.ml`)
   should also be evaluated for `Supervisor.scoped` migration. Pool,
   Resource.auto, and eta-otel daemons are correct and should stay.

4. **Defer helper until 2nd consumer emerges.** If a second concrete consumer
   (e.g., OpenAI Realtime runtime, agent-loop chat session) needs the same
   pattern, revisit Branch B. Until then, the recipe is sufficient.
