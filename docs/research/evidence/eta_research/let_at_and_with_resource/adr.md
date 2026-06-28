# ADR-0NNN: Add `let@` And `Effect.with_resource`

Status: Implemented in this worktree

## Context

A downstream Eta consumer reported a 4-deep CPS resource chain and proposed adding `let@`, a CPS `Effect.with_resource`, and a single-binder `with_*` convention. Eta already exposes binding operators through `Eta.Syntax`, and existing scope-bound APIs include `Pool.with_resource`, `Effect.with_background`, and `Semaphore.with_permits`.

The research split the question into two P1 shapes:

- P1a: pre-wrapped CPS resources such as downstream `with_client` and `with_monitor`.
- P1b: direct `Effect.acquire_release ~acquire ~release` sites and mixed consumer code where pre-wrapped and direct resources appear together.

## Decision

Ship the combined surface:

- Add `let@` to `Eta.Syntax`.
- Add `Effect.with_resource` as the CPS companion to `Effect.acquire_release`.
- Recommend single-binder downstream `with_*` callbacks where the binder names a real resource/session concept.
- Document `Supervisor.scoped` as the intentional rank-2 holdout that does not fit `let@`.

## Signatures

```ocaml
(* lib/eta/syntax.mli *)
val ( let@ ) : (('a -> 'b) -> 'c) -> ('a -> 'b) -> 'c
```

```ocaml
(* lib/eta/effect.mli *)
val with_resource :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
```

## Implementations

```ocaml
(* lib/eta/syntax.ml *)
let ( let@ ) f k = f k
```

```ocaml
(* lib/eta/effect.ml *)
let with_resource ~acquire ~release body =
  acquire_release ~acquire ~release |> bind body
```

`Effect.with_resource` uses a body-shaped callback. It is not a replacement for `Effect.acquire_release` at sites that deliberately register finalizers against a larger surrounding scope.

Because the implementation is exactly `acquire_release ~acquire ~release |> bind body`, `Effect.with_resource` inherits `acquire_release` release semantics. Cancellation safety, release-on-cancel, and suppressed finalizer failures are not reimplemented by the companion; only the binding shape differs.

When `Effect.scoped` participates, a `let@` binder ladder is intentionally interrupted. The interruption marks the scope boundary: resources outside the `scoped` block and resources inside it have different release boundaries.

`Effect.with_resource ~acquire ~release body` and `Pool.with_resource pool body` are different shapes. They may appear next to each other in the same function; the module qualifier carries the distinction.

## Implementation Touch Points

- `lib/eta/syntax.mli`: exports `( let@ )` with documentation saying it is callback inversion for CPS `with_*` functions and not RAII.
- `lib/eta/syntax.ml`: implements `let ( let@ ) f k = f k`.
- `lib/eta/effect.mli`: exports `with_resource` beside `acquire_release`, documenting inherited release semantics, scope-boundary interaction, and the `Pool.with_resource` shape distinction.
- `lib/eta/effect.ml`: implements `with_resource` over `acquire_release` and `bind`.
- `test/eta/test_eta_effect_resource_timeout.ml`: covers `with_resource` success, typed failure cleanup, release-on-cancel, and release failure after a successful body.
- `test/eta/test_eta_effect_core.ml`: covers the general `Eta.Syntax.( let@ )` operator.

## Consequences

- Downstream pre-wrapped resource code can use binder-first layout with `let@`.
- Direct body-shaped acquire/use/release code can also use binder-first layout without a local wrapper.
- Eta public surface grows by one Syntax binding operator and one Effect helper.
- `Effect.acquire_release` remains the correct primitive when release must be registered against an outer scope or when the acquired value is intentionally used across a longer monadic chain.
- `Supervisor.scoped` remains intentionally different because its rank-2 body protects child handle scope.

## Evidence

See `results.md`, `p1_consumer_fixture/`, `p1b_direct_acquire/`, P2, P3, P5, and P6 in this lab.
