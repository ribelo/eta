# P-Scoped-2: Protocol Centralization Test for Branch B

## Context

Branch B (`Resource.with_session`) survived P-Scoped-1 as a "good fit" for the
WebSocket consumer, the only known consumer of the "long-lived child + handle
escape" pattern. This probe tests whether Branch B centralizes a real protocol
or merely renames `Supervisor.scoped + Scope.start + Scope.await`.

## Claimed protocol elements

Per OBJECTIVE.md and H-W4 wrap policy, a helper earns its place by preserving
an Eta-owned invariant:

1. **Typed failure preservation** across parent/child boundary
2. **Cancellation cleanup** that's hard to get right without the helper
3. **Close fences** (parent must drain child output before close)
4. **Observability seam** (child fiber registered with Tracer)
5. **Mode/portability fence**

## Test method

For each claimed protocol element, write:
- What the helper would centralize
- What the consumer would write manually under Branch C
- Whether the manual version is error-prone or boilerplate-heavy
- Whether the protocol element is generic (applies to 2+ consumers)

---

## Element 1: Typed failure preservation

### What Branch B would centralize

A `with_session` helper could propagate the background child's typed failures
to the parent callback. For WebSocket, if `reader_loop` fails with `ws_error`,
the parent should observe that failure rather than getting a runtime defect.

### What Branch C requires

```ocaml
Supervisor.scoped {
  run = fun sup ->
    let open Supervisor.Scope in
    let* child = start sup (lift reader_loop) in
    let* result = lift user_callback in
    let* () = cancel child in
    pure result
}
```

Under Branch C, the child's failures are recorded on the supervisor via
`Scope.failures`. The parent must explicitly check for failures or use
`Scope.check` with `max_failures`. Typed failure propagation is NOT automatic
— the parent must poll or await the child.

### Is this error-prone?

**Yes, partially.** A naive Branch C implementation might forget to check
child failures after cancelling. However, a well-written recipe (which Branch C
explicitly includes) would show the correct pattern:

```ocaml
let* child = start sup (lift reader_loop) in
let* result = lift user_callback in
let* () = cancel child in
let* child_result = await child in  (* re-raise child failure *)
pure result
```

### Is it generic?

**No.** Only WebSocket needs typed failure propagation from a background reader
loop. The other consumers (Resource.auto, Pool, eta-otel) either:
- Handle failures internally (Resource.auto records them in `resource.failures`)
- Are pure background loops where failure = defect (eta-otel, Pool)

**Verdict for Element 1:** Real but narrow. One consumer benefits.

---

## Element 2: Cancellation cleanup

### What Branch B would centralize

The helper would ensure that when the parent callback exits (success, failure,
or cancellation), the background child is cancelled and resources are released.

### What Branch C requires

```ocaml
Effect.scoped (
  Effect.acquire_release
    ~acquire:(Effect.pure t)
    ~release:(fun t -> close_flow t)
  |> Effect.bind (fun t ->
       Supervisor.scoped {
         run = fun sup ->
           let open Supervisor.Scope in
           let* child = start sup (lift (reader_loop t)) in
           let* result = lift (user_callback t) in
           let* () = cancel child in
           pure result
       }))
```

This is ~12 lines and composes three primitives: `Effect.scoped`,
`Effect.acquire_release`, and `Supervisor.scoped`.

### Is this error-prone?

**Moderately.** The nesting is non-obvious. A developer might:
- Forget `Effect.scoped` around the whole thing, losing the close fence
- Forget `cancel child`, leaking the reader fiber
- Put `acquire_release` inside `Supervisor.scoped`, causing the close to happen
  before child cancellation

However, these are exactly the mistakes a good recipe with examples would
prevent.

### Is it generic?

**Partially.** The "cancel child on parent exit" pattern applies to any
supervised child. But the specific cleanup sequence (drain queue, send close
frame, close flow) is WebSocket-specific.

**Verdict for Element 2:** Real but mostly generic to Supervisor already.
The WebSocket-specific parts (drain, close frame) can't be centralized in a
generic helper.

---

## Element 3: Close fences

### What Branch B would centralize

Ensuring the connection flow is closed even if the callback raises or is
cancelled.

### What Branch C requires

`Effect.acquire_release ~release:close_flow` handles this. The release runs
on success, typed failure, and cancellation. This is already a shipped
primitive.

```ocaml
Effect.acquire_release
  ~acquire:(connect_and_upgrade url)
  ~release:(fun t -> close_flow t)
```

### Is this error-prone?

**No.** `Effect.acquire_release` is designed for exactly this. The recipe
would just show how to combine it with `Supervisor.scoped`.

### Is it generic?

**Yes, but already solved.** `Effect.acquire_release` is the generic solution.

**Verdict for Element 3:** Already centralized by `Effect.acquire_release`.
Branch B adds nothing.

---

## Element 4: Observability seam

### What Branch B would centralize

The helper could automatically create a Tracer span for the session and
register the child fiber as a sub-span.

### What Branch C requires

```ocaml
Effect.named "ws.session" (
  Supervisor.scoped {
    run = fun sup ->
      let open Supervisor.Scope in
      let* child = start sup (lift (Effect.named "ws.reader" reader_loop)) in
      ...
  })
```

Manual naming is ~2 lines per span.

### Is this error-prone?

**No.** Naming is optional for correctness. Forgetting a span name doesn't
cause a runtime bug.

### Is it generic?

**Yes, but low value.** Automatic span naming saves 2 lines. Not enough to
justify a new public API.

**Verdict for Element 4:** Convenience, not protocol centralization.

---

## Element 5: Mode/portability fence

### What Branch B would centralize

Enforcing that `'err` and the child's result flow correctly across the
parent/child boundary.

### What Branch C requires

`Supervisor.scoped` already enforces this via the rank-2 type. The `'err`
channel is shared between parent and children. The Scope GADT ensures type
safety.

### Is this error-prone?

**No.** The type system prevents mismatched error channels.

### Is it generic?

**Yes, already solved.** `Supervisor.scoped` is the portability fence.

**Verdict for Element 5:** Already centralized by `Supervisor.scoped`.

---

## Protocol centralization verdict

| Element | Already centralized? | Generic? | Value of new helper |
|---------|---------------------|----------|---------------------|
| Typed failure preservation | Partially (`Scope.await`) | No | Low |
| Cancellation cleanup | Partially (`Supervisor.scoped`) | Partially | Low |
| Close fences | **Yes** (`acquire_release`) | Yes | None |
| Observability seam | No (manual naming) | Yes | Very low |
| Mode/portability fence | **Yes** (`Supervisor.scoped`) | Yes | None |

### Conclusion

**Branch B does NOT centralize a real protocol that is not already handled by
existing primitives.**

The "protocol" Branch B would add is a **naming convention and a canonical
cleanup sequence for WebSocket-like sessions**. This is valuable documentation
but not a new runtime invariant. The hard parts (close fences, typed failure
channels, cancellation propagation) are already owned by:
- `Effect.acquire_release`
- `Supervisor.scoped`
- `Scope.start` / `Scope.await` / `Scope.cancel`

A `with_session` helper would be a thin wrapper around these three primitives,
adding ~20 lines of implementation to save ~5 lines at the call site for ONE
consumer.

Per H-W4: "A helper earns its place when it preserves an Eta-owned invariant."
Branch B preserves no new invariant.

Per OBJECTIVE.md: "a helper that only renames existing primitives is rejected."

**Branch B is REJECTED.**

## Implications

With Branch A rejected in P-Scoped-1 and Branch B rejected in P-Scoped-2,
the remaining candidates are:
- **Branch C**: Recipe in docs, no new public API
- **Branch D**: Refactor WebSocket alone

P-Scoped-3 will test the camelpie/WebSocket refactor under Branch C to
confirm the recipe works in practice.
