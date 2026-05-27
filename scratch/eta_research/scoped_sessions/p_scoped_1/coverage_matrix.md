# P-Scoped-1: Consumer Survey Coverage Matrix

## Consumers surveyed

| # | Consumer | Location | Pattern shape |
|---|----------|----------|---------------|
| 1 | WebSocket streaming session | `lib/http/ws/ws_client.ml` | `start_reader_loop` → return `t` handle → caller uses `send_text`/`incoming`/`close` |
| 2 | HTTP/1 pooled request owner | `lib/http/h1/h1_client.ml` | `start_request_owner` → return response via channel → caller receives response |
| 3 | Resource.auto refresh | `lib/eta/resource.ml` | `start_refresh_loop` → return resource handle → caller uses `get` |
| 4 | eta-otel export daemon | `lib/otel/eta_otel.ml` | `start_daemon` → background batch export loop |
| 5 | Pool eviction loop | `lib/eta/pool.ml` | `start_daemon` → background eviction loop → return pool handle |

## Branch definitions

- **A**: `Supervisor.with_child` helper — callback-shaped API that starts a child, passes a handle to a user callback, and cancels/awaits on callback exit.
- **B**: `Resource.with_session` — session-specific resource pattern with finish-vs-cancel asymmetry and drain semantics.
- **C**: Recipe using existing primitives (`Supervisor.scoped` + `Scope.start` + `Scope.await` + `Effect.acquire_release`) plus documentation.
- **D**: Refactor consumer alone, no Eta change.

## Coverage matrix

Cell values: **✓** = clean fit, **~** = viable with tradeoffs, **✗** = poor fit / cannot express, **N/A** = not applicable.

| Consumer | Branch A | Branch B | Branch C | Branch D | Notes |
|----------|----------|----------|----------|----------|-------|
| 1 WebSocket | **✗** | **~** | **~** | **~** | Handle must escape scope; rank-2 prevents this. `daemon` used instead. |
| 2 HTTP/1 pool req | **~** | **N/A** | **✓** | **✓** | One-shot async; could trivially use `Supervisor.scoped`. Not a session. |
| 3 Resource.auto | **✗** | **N/A** | **~** | **✓** | Background refresh; resource handle lifetime exceeds any callback scope. |
| 4 eta-otel export | **N/A** | **N/A** | **N/A** | **N/A** | Pure background loop; no handle escape. `daemon` is correct. Not in scope. |
| 5 Pool eviction | **N/A** | **N/A** | **N/A** | **N/A** | Pure background loop; no handle escape. `daemon` is correct. Not in scope. |

### Cell justifications

**1 WebSocket**
- **A ✗**: `with_child` passes a `child` fiber handle, not the shared-state `t`. Rank-2 still prevents escape. Mismatched abstraction.
- **B ~**: Fits well conceptually (session with open/use/finish/close), but only one consumer. Cleanup sequence is WS-specific.
- **C ~**: Viable with API reshape to callback shape. Compositional cost (nesting) for multiple connections.
- **D ~**: Viable — reshape WebSocket API to callback shape. Does not help future consumers.

**2 HTTP/1 pool request**
- **A ~**: Could express, but overkill. One-shot pattern doesn't need a session abstraction.
- **C ✓**: `Supervisor.scoped` + `Scope.start` expresses this cleanly. Minor refactor from `daemon`.
- **D ✓**: Refactor h1_client to use `Supervisor.scoped`; no Eta change needed.

**3 Resource.auto**
- **A ✗**: Resource handle lifetime exceeds any callback scope. Cannot use callback-shaped API.
- **C ~**: Could theoretically reshape, but resource caching pattern is fundamentally handle-based.
- **D ✓**: Current `daemon` usage is correct. No change needed.

**4 eta-otel export / 5 Pool eviction**
- Not in scope for this lab. These are legitimate `daemon` use cases (background maintenance loops). No branch applies.

## Completed cross-tab (post-fixture analysis)

| Criterion \ Branch | A (with_child) | B (with_session) | C (recipe) | D (refactor consumer) |
|---|---|---|---|---|
| **LOC call site** | +2 (awkward child/handle mismatch) | +1 (clean callback) | +1 (clean callback) | 0 (current API) |
| **LOC implementation** | ~30 (new primitive) | ~40 (session helper) | 0 (docs only) | ~10 (WS refactor) |
| **Error-path correctness** | Poor (child ≠ shared state) | Good (centralized) | Good (if written well) | Good (current) |
| **Cancellation correctness** | Same as C (no gain) | Good (drain vs cancel) | Good (manual) | Good (daemon) |
| **Observability seam** | Same as C | Slightly better (named span) | Manual | Manual |
| **Discoverability** | Low (mismatched abstraction) | Medium (named pattern) | Medium (docs + examples) | High (no change needed) |
| **Generalizes beyond WS?** | No | Unlikely (only 1 consumer) | Yes (recipe pattern) | N/A |
| **Type-system feasibility** | Questionable (rank-2 escape) | Feasible (callback-shaped) | Already works | Already works |

**Legend:** 0 = baseline, +1 = slight improvement, +2 = significant cost.

## Consumer 1: WebSocket — detailed analysis

Current code (`lib/http/ws/ws_client.ml:441`):
```ocaml
Effect.Private.daemon (reader_loop t reader None)
|> Effect.map (fun () -> t)
```

The `t` handle escapes containing the `incoming` queue, flow, and mutex. The caller then:
- Reads messages via `incoming t` (Eta_stream from queue)
- Sends via `send_text` / `send_binary`
- Closes via `close`

The reader loop runs until the peer sends a Close frame or the connection drops. The loop is NOT scoped to any single caller operation — it outlives the `connect_on_flow` call.

### Branch C (existing primitives) for WebSocket

`Supervisor.scoped` has rank-2 type: `('a, 'err) body = { run : 's. ('s, 'err) t -> ('s, 'a, 'err) Scope.t }`. The `'s` is existentially quantified, preventing child handles from escaping the body. This means we **cannot** return a WebSocket handle `t` that references the supervisor scope.

To express WebSocket with existing primitives, we must reshape the API:
```ocaml
val connect_on_flow :
  ?key:string -> ?headers -> ?protocols ->
  sw:_ -> flow -> Url.t ->
  (t -> ('a, ws_error) Effect.t) -> ('a, ws_error) Effect.t
```

Instead of returning `t`, we pass a callback that uses `t`. Inside the callback, we start the reader loop as a supervised child and the user's code runs alongside it. When the user's callback returns, we cancel the reader child and close the connection.

This is a **real API reshape**. It changes the public shape of WebSocket from "return a handle" to "callback with handle".

### Branch A (`Supervisor.with_child`) for WebSocket

```ocaml
val with_child :
  ('child_result, 'err) Effect.t ->
  (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
```

Wait — this still has the same problem. The `child` handle has the same `'s` scope parameter and cannot escape the callback.

Actually, looking at the hypothesis more carefully, the proposed `with_child` would need to allow the child handle to escape. But `Supervisor.scoped` specifically prevents this with its rank-2 type.

Hmm, let me re-read the OBJECTIVE.md more carefully...

The proposed API is:
```ocaml
val Supervisor.with_child :
  ('child_result, 'err) Effect.t ->
  (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
```

But this is basically just `Supervisor.scoped` with a single child pre-started. The `child` handle still has the scope parameter.

Wait, maybe the idea is different. Let me re-read... The pattern is "long-lived child fiber + handle escape into a callback". Maybe the helper is something like:

```ocaml
val Supervisor.with_child :
  ('child_result, 'err) Effect.t ->
  (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
```

Actually no, the real problem is that the handle must escape. The current `Supervisor.scoped` has a rank-2 type that prevents the handle from escaping. Any helper built on top of it would have the same restriction unless it changes the type system.

So maybe Branch A is NOT actually implementable on top of `Supervisor.scoped` without changing the fundamental type structure. That would be a major finding.

Let me think about this differently. Perhaps the helper isn't built on `Supervisor.scoped` at all — it's a new primitive that allows handle escape. For example:

```ocaml
val with_child :
  ('child_result, 'err) Effect.t ->
  (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
```

Where `child` is a handle WITHOUT a scope parameter. The child is started, the callback receives the handle, and when the callback exits, the child is cancelled/awaited.

This would require runtime support — the child fiber would be attached to the current Switch (not a rank-2 supervisor scope), and cancellation would happen via the Switch.

But wait, that already exists! You can just use `Eio.Fiber.fork ~sw` directly. The question is whether Eta should wrap this pattern.

Actually, looking at the OBJECTIVE.md again: "The agent working on it reached for `Effect.Private.daemon` because the existing structured-concurrency primitives required reshaping camelpie's API shape, and that reshape felt heavy."

So the core issue is: the existing primitives REQUIRE a callback shape (rank-2 body), but the consumer wants a "start, return handle, use handle, close" shape. The daemon allows this but is unsupervised.

OK so the real question is whether Eta should provide a supervised version of "start and return handle".

Let me now write proper fixtures for all branches and consumers.

I think the key insight is:
- Branch A proposes a new primitive that isn't `Supervisor.scoped` — it's a different abstraction that allows handle escape
- Branch C says "use the existing callback shape"
- Branch D says "the consumer should change its API shape"

For WebSocket, the current API returns a handle. With Branch C, you'd need to change it to a callback. With Branch A, you'd keep the handle-returning API but wrap it in something supervised.

Let me write out the actual code shapes.
