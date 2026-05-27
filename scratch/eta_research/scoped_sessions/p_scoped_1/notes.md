# P-Scoped-1 Notes: Consumer Survey

## Executive Summary

**One consumer (WebSocket) clearly matches the "long-lived child + handle escape" pattern.
The other four consumers use `Effect.Private.daemon` for different, legitimate reasons.**

This finding strongly suggests **Branch D or Branch C** wins, not A or B.

## Consumer-by-consumer analysis

### 1. WebSocket client (`lib/http/ws/ws_client.ml`)

**Pattern match: YES** — clear start → handle → use → close.

Current code uses `Effect.Private.daemon (reader_loop t reader None)` to start a
background reader fiber, then returns `t` containing the incoming queue, flow,
and mutex. The caller uses `send_text`, `send_binary`, `incoming`, and `close`.

**Branch C (existing primitives):** Requires API reshape from handle-returning to
callback-shaped. For single connections this is ~0 LOC delta. For multiple
connections or mixed resources, it forces callback nesting (pyramid of doom).
Rank-2 `Supervisor.scoped` prevents handle escape, so `connect_on_flow` cannot
return `t` — it must accept a callback.

**Branch A (`with_child`):** Mismatched to the pattern. `with_child` passes a
`child` handle (representing the fiber) to the callback, but the consumer needs
the shared state (`t`, the queue/flow). Constructing `t` before `with_child` and
using a mutable ref to escape it is MORE awkward than current code. The rank-2
constraint is still present unless `with_child` is a completely new primitive
(not built on `Supervisor.scoped`).

**Branch B (`with_session`):** Fits well. WebSocket IS a session with open → use
→ finish/cancel → close semantics. A `Ws.with_session` helper would centralize:
- Graceful close (send close frame, drain queue)
- Hard cancel on timeout/parent cancellation
- Typed failure propagation from reader loop
- Close fence (flow always closed)

However, this is essentially a well-written recipe using Branch C primitives.
The "centralization" is naming and cleanup logic, not a fundamentally new
runtime mechanism.

**Branch D (refactor consumer):** WebSocket could be reshaped to callback-shaped
`with_connection`. This is idiomatic in OCaml (cf. `In_channel.with_file`). The
compositional cost (nesting) is real but acceptable for most use cases.

**Verdict for WebSocket:** Branch B is the best fit IF it generalizes.
Branch C is viable with a good recipe. Branch D is acceptable.

---

### 2. HTTP/1 pooled request (`lib/http/h1/h1_client.ml:646`)

**Pattern match: NO** — one-shot background task, not long-lived session.

`request_with_pool` starts a `request_owner` daemon that handles a single
request/response exchange via channels. The daemon finishes when the response
is sent. This is a "fire and forget with async response" pattern.

**All branches:** This could use `Supervisor.scoped` naturally because the
lifetime is bounded to a single request. The current `daemon` usage is a
convenience, not a necessity. A refactor to `Supervisor.scoped` would be
trivial and arguably cleaner.

**Verdict:** Not a motivating consumer for any new API.

---

### 3. Resource.auto (`lib/eta/resource.ml:59`)

**Pattern match: PARTIAL** — background loop + handle escape, but handle is
not "used interactively" like WebSocket.

`Resource.auto` starts a refresh loop daemon and returns the resource handle.
The caller uses `get` to read the cached value. The refresh loop is invisible
to the caller.

**Branch C:** `Supervisor.scoped` doesn't fit because the resource lifetime
exceeds any single callback scope. A resource might be passed between functions,
stored in a data structure, etc.

**Branches A/B:** Neither `with_child` nor `with_session` fits well. The
resource pattern is already served by `Effect.acquire_release` (for one-shot)
and `Resource.auto` (for periodic refresh). A new helper wouldn't improve this.

**Verdict:** Current `daemon` usage is correct. No new API needed.

---

### 4. eta-otel export daemon (`lib/otel/eta_otel.ml:371`)

**Pattern match: NO** — pure background loop, no handle escape.

`start_daemon` starts an export loop that reads from mailboxes and sends
batches. There is no handle returned to callers.

**Verdict:** `daemon` is the correct primitive. No new API needed.

---

### 5. Pool eviction loop (`lib/eta/pool.ml:464`)

**Pattern match: NO** — pure background loop, no handle escape.

The eviction loop runs in background to close idle connections. The pool handle
is returned, but the caller doesn't interact with the eviction loop.

**Verdict:** `daemon` is correct. No new API needed.

---

## Cross-tab summary

| Consumer | Branch A | Branch B | Branch C | Branch D | Match pattern? |
|----------|----------|----------|----------|----------|----------------|
| WebSocket | Poor fit | Good fit | Viable | Viable | YES |
| HTTP/1 pool | N/A | N/A | Easy refactor | Easy refactor | NO |
| Resource.auto | N/A | N/A | Already served | Already served | PARTIAL |
| eta-otel | N/A | N/A | N/A | N/A | NO |
| Pool | N/A | N/A | N/A | N/A | NO |

## Key finding

**Only 1 of 5 consumers matches the "long-lived child + handle escape" pattern.**
This is the WebSocket client. The other four use `daemon` for unrelated patterns
(background maintenance loops, one-shot async handlers) where `daemon` is correct.

## Implications for hypothesis space

- **Branch A (`with_child`)**: Poor fit for the ONE consumer that matches the
  pattern. The `child` handle type doesn't match the shared-state handle that
  WebSocket needs. Rejected.

- **Branch B (`with_session`)**: Good fit for WebSocket, but WebSocket is the
  ONLY consumer that needs it. If we add a session abstraction, it serves one
  known consumer. The "protocol" it centralizes (graceful close, drain,
  typed failure propagation) is real but narrow.

- **Branch C (recipe in docs)**: Viable. WebSocket CAN be expressed with
  existing primitives by reshaping to callback-based `with_connection`. The
  recipe would show how to combine `Supervisor.scoped` + `Scope.start` +
  `Effect.acquire_release` for session-like lifetimes. HTTP/1 pool could also
  be refactored to use `Supervisor.scoped` instead of `daemon`.

- **Branch D (refactor camelpie/WebSocket alone)**: Strong contender. If
  WebSocket is the only consumer, reshape its API and document the pattern.
  No Eta change needed.

## Verdict so far

**P-Scoped-1 strongly favors Branch D or Branch C.**

- Branch D wins if we believe WebSocket is the only consumer that will ever
  need this pattern.
- Branch C wins if we believe 2+ future consumers might need the same recipe.

Since the OBJECTIVE.md mentions OpenAI Realtime as "almost certainly the same
shape" and a "hypothetical agent-loop" as a future consumer, there is SOME
risk that Branch D misses future needs. But these consumers are NOT in the
codebase today. The evidence says: 1 known consumer.

**Recommendation:** Proceed to P-Scoped-2 only for Branch B (the one helper
that could theoretically generalize), but expect it to fail the protocol
centralization test due to narrow applicability. The likely final verdict is
Branch C (recipe + examples in docs) with a note that Branch B could be
revisited if a 2nd concrete consumer emerges.

## What was NOT measured

- Actual camelpie PTT streaming code (not in this repo)
- OpenAI Realtime session implementation (only tests exist, no runtime)
- HTTP/2 multiplexer writer-fiber (not found in codebase)
- Performance delta between daemon and supervised approaches
- Migration cost for existing consumers
