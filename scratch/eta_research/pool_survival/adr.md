# ADR: Eta.Pool Shape From Pool Survival

## Status

Draft accepted shape; implementation gated by dogfood gaps.

## Decision

Eta should grow a generic pool primitive in packages/eta, but eta-http should
not expose pool types to request callers.

The conservative v1 API should avoid the deferred OxCaml borrow surface:

~~~ocaml
type ('conn, 'err) t

type 'conn config = {
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
  health_check : 'conn -> bool;
}

type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
  opened : int;
  closed : int;
  health_rejected : int;
  cancelled_waiters : int;
}

val create :
  'conn config ->
  acquire:('conn, 'err) Effect.t ->
  release:('conn -> (unit, 'err) Effect.t) ->
  (('conn, 'err) t, 'err) Effect.t

val with_resource :
  ('conn, 'err) t ->
  ('conn -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t

val stats : ('conn, 'err) t -> stats
~~~

Notes:

- The pool type carries the error channel. The backlog sketch used only conn t,
  but the implementation needs the acquire/release error type unless Eta adds
  an error-normalization policy.
- LIFO idle reuse is now the best-tested storage policy. The pool_choice lab
  shows FIFO loses warm reuse and that Eio.Stream take_nonblocking is
  nonportable under Domain.Safe.spawn. The full-protocol lab repeats the result
  through Eta acquire/use/release, health rejection, wait cancellation cleanup,
  idle eviction, and shutdown. For eta-http v1, the storage recommendation is
  same-domain mutex LIFO: real Eio connection handles are nonportable, and a
  Portable.Atomic Treiber stack cannot store them without forcing a portable
  payload constraint into the Pool API. Treiber LIFO over Portable.Atomic
  remains the leading candidate only for a future portable-payload/cross-domain
  pool shape.
- A future mode-aware API may introduce an abstract local borrow handle, but
  not until Eta can express useful effectful work under that borrow.

## Consequences

- H-D5 and H-D2a should consume Pool internally where it fits and keep protocol
  selection hidden at the request layer.
- Eta.Pool implementation must include focused tests for timeout cancellation
  under all_settled and scoped acquire/release before it is production-ready.
- Eta.Resource remains unchanged.
