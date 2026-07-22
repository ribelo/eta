(** Runtime operations required by Eta effect interpretation.

    This module is intentionally backend-neutral. It names Eta's runtime
    contract without committing the root [eta] package to Eio, Unix, domains,
    or any future JavaScript substrate. *)

type scope
(** Runtime-owned lexical scope for child tasks and cancellation. *)

type cancel_context
(** Runtime-owned cancellation handle. *)

type 'a promise
(** Runtime-owned one-shot result handle. *)

type 'a resolver
(** Runtime-owned one-shot resolver. *)

type 'a stream
(** Runtime-owned bounded stream used for internal result handoff. *)

type 'a local
(** Runtime-local binding key. Backends decide whether this maps to fiber-local,
    task-local, or another scoped context mechanism. *)

type local_binding = Local_binding : 'a local * 'a -> local_binding
(** Packed runtime-local binding. Runtime backends use this to transport
    local values without erasing the value independently from its key. *)

type 'a service_key
(** Typed key for runtime services supplied by optional packages. *)

type service = Service : 'a service_key * 'a -> service
(** Packed runtime service binding. Runtime packages use this to attach
    optional capabilities without adding those capability types to root
    [eta]. *)

type t = {
  root_scope : scope;
  now_ms : unit -> int;
  fresh : unit -> int;
  sleep : Duration.t -> unit;
  protect : 'a. (unit -> 'a) -> 'a;
  run_scope : 'a. ?name:string -> (scope -> 'a) -> 'a;
  fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit;
  fork : scope -> (unit -> unit) -> unit;
  fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit;
  await_cancel : 'a. unit -> 'a;
  yield : unit -> unit;
  check : unit -> unit;
  create_promise : 'a. unit -> 'a promise * 'a resolver;
  resolve_promise : 'a. 'a resolver -> 'a -> unit;
  await_promise : 'a. 'a promise -> 'a;
  create_stream : 'a. int -> 'a stream;
  stream_add : 'a. 'a stream -> 'a -> unit;
  stream_take : 'a. 'a stream -> 'a;
  stream_take_nonblocking : 'a. 'a stream -> 'a option;
  with_worker_context : 'a. (unit -> 'a) -> 'a;
  in_worker_context : unit -> bool;
  cancellation_reason : exn -> exn option;
  multiple_exceptions : exn -> (exn * Printexc.raw_backtrace) list option;
  cancel_sub : 'a. (cancel_context -> 'a) -> 'a;
  cancel : cancel_context -> exn -> unit;
  local_get : 'a. 'a local -> 'a option;
  local_with_binding : 'a 'b. 'a local -> 'a -> (unit -> 'b) -> 'b;
  current_fiber_id : unit -> int;
  with_fiber_identity : 'a. (unit -> 'a) -> 'a;
}
(** Erased backend runtime contract used by the current interpreter.

    This record is one of the two runtime layers Eta intentionally exposes:
    backend packages author against the typed {!RUNTIME} module shape, and
    {!of_runtime} erases that implementation into this record for the root
    interpreter. Erased values are wrapped in distinct private token kinds for
    scopes, cancellation handles, promises, resolvers, and streams; promise,
    resolver, and stream wrappers also carry their payload type through the
    erased token. The [Obj.t] representation is confined to those wrappers and
    the adapter; do not add another mirror record of backend operations.

    Erased runtime contracts are owner-domain values. Except for
    [resolve_promise], [with_worker_context], [in_worker_context],
    [cancellation_reason], [multiple_exceptions], [current_fiber_id], and
    [with_fiber_identity],
    contract operations must be called on the domain that created the erased
    contract, and callbacks supplied to [run_scope], [fork], [fork_daemon],
    [protect], [cancel_sub], and [local_with_binding] must resume on that same
    domain. Cross-domain contract use raises [Invalid_argument].

    [resolve_promise] is the explicit cross-domain wake operation. Eta-owned
    queues may store resolvers created by waiters on different domains and
    settle them from the domain that commits the queue transition. Backends must
    make the waiter runnable on its runtime domain; resolving a promise must not
    run Eta callbacks on the resolving domain.

    [now_ms] is monotonic runtime time in milliseconds, not wall/civil time.
    [sleep] must suspend on the same monotonic time base. Eta timers,
    schedules, timeouts, and elapsed-time measurements assume these operations
    are one clock pair; mixing a wall-clock [now_ms] with a relative monotonic
    sleeper makes clock-jump behavior undefined. Contracts exposed through
    [Effect.Expert.contract] select the active fiber-local [Effect.with_clock]
    override for both operations, then return to the base pair outside its
    scope.

    [fresh] advances a counter owned by this runtime instance. It must return a
    strictly increasing, duplicate-free sequence under the backend's concurrent
    fiber substrate. It does not provide global or cross-domain uniqueness;
    separately created runtimes may return the same values. Native concurrent
    backends must synchronize increments, while single-domain JavaScript
    backends may use a plain mutable cell.

    Promise resolution is a commit point for Eta-owned wait queues. When
    [resolve_promise] is called with an unsettled resolver, the backend must
    settle the promise and make every still-observable waiter able to resume
    before returning. Cancellation of an awaiting fiber must not make later
    resolution fail; resolving after a waiter has been cancelled still succeeds
    and leaves the promise settled. [resolve_promise] may raise for programmer
    errors such as resolving the same resolver twice, but it must not raise for
    transient notification or scheduler failures. Queue wakeups and signal
    graph-lane grants rely on this contract after their mutable state has
    committed. *)

val same_runtime : t -> t -> bool
(** [same_runtime left right] is [true] when both erased contracts wrap the same
    backend runtime instance. *)

module type RUNTIME = sig
  type scope
  type cancel_context
  type 'a promise
  type 'a resolver
  type 'a stream

  val root_scope : scope
  val now_ms : unit -> int
  (** Current monotonic runtime clock in milliseconds. This is elapsed runtime
      time, not wall/civil time, and should not move backwards during ordinary
      execution. *)

  val fresh : unit -> int
  (** Advance this backend runtime's monotonic fresh counter. Values must be
      strictly increasing and duplicate-free within this runtime instance, but
      need not be unique across separately created runtimes or domains. *)

  val sleep : Duration.t -> unit
  (** Suspend the current runtime task for at least [duration] on the same
      monotonic time base as {!now_ms}. Backends may ignore non-positive
      durations. *)

  val protect : (unit -> 'a) -> 'a
  (** Run [f] with parent cancellation deferred. If cancellation is pending
      when [f] returns, the backend should surface it before returning to
      ordinary interruptible execution. *)

  val run_scope : ?name:string -> (scope -> 'a) -> 'a
  (** Run [f] in a child scope and wait for finite children before returning.

      If {!fail_scope} fails the child scope, [run_scope] must let children and
      cleanup settle, then propagate the original failure exception rather than
      wrapping it as ordinary cancellation. Parent cancellation should still be
      recognizable through {!cancellation_reason}. This mirrors Eio switch
      behavior and is required by Eta's timeout and race control paths. *)

  val fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit
  (** Fail [scope] with [exn], requesting cancellation of work owned by that
      scope. The first failure reason is the scope failure observed by
      {!run_scope}; additional child failures may still be reported through
      the backend's multiple-exception mechanism. *)

  val fork : scope -> (unit -> unit) -> unit
  val fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit
  val await_cancel : unit -> 'a
  val yield : unit -> unit
  val check : unit -> unit
  val create_promise : unit -> 'a promise * 'a resolver
  val resolve_promise : 'a resolver -> 'a -> unit
  (** Settle an unresolved promise and notify waiters.

      This operation is a commit point. It must not fail because a waiter was
      cancelled or because notification is temporarily unavailable. Once it
      returns normally, every non-cancelled waiter must be able to observe the
      value. It may be called from a different domain than the runtime owner so
      cross-domain data structures can wake owner-domain waiters. It may raise
      only for programmer errors such as resolving an already-settled resolver. *)

  val await_promise : 'a promise -> 'a
  val create_stream : int -> 'a stream
  val stream_add : 'a stream -> 'a -> unit
  val stream_take : 'a stream -> 'a
  val stream_take_nonblocking : 'a stream -> 'a option
  val with_worker_context : (unit -> 'a) -> 'a
  val in_worker_context : unit -> bool
  val cancellation_reason : exn -> exn option
  val multiple_exceptions : exn -> (exn * Printexc.raw_backtrace) list option
  val cancel_sub : (cancel_context -> 'a) -> 'a
  val cancel : cancel_context -> exn -> unit
  val local_get : 'a local -> 'a option
  val local_with_binding : 'a local -> 'a -> (unit -> 'b) -> 'b
  val current_fiber_id : unit -> int
  (** Stable identity for the current runtime fiber/task. The identity must be
      shared by nested Eta runtimes running on the same host fiber, and distinct
      for concurrently running host fibers. *)

  val with_fiber_identity : (unit -> 'a) -> 'a
  (** Establish a current fiber identity for a root {!Eta.Runtime.run} call when
      the host fiber does not already have one. Nested runtime calls in the same
      host fiber must preserve the existing identity. *)
end
(** Module-shaped runtime backend contract. Runtime packages should implement
    this shape. It is the typed authoring surface for backends; {!t} is the
    erased interpreter representation. Fully functorizing the interpreter over
    [RUNTIME] remains the long-term endgame if this boundary becomes a measured
    cost or correctness constraint, but it is not treated as imminent migration
    work. Until then, keep the design to these two layers.

    Backends must preserve same-domain execution for ordinary Eta fibers:
    cancellation propagation, scope callbacks, forked fibers, daemon fibers,
    and runtime-local bindings must not resume Eta code on a different OCaml
    domain from the one running the erased contract. Promise resolution may be
    requested from another domain, but resumed waiters still run on the owning
    runtime domain. Worker callbacks are represented explicitly by
    [with_worker_context]; they must not call Eta graph APIs directly. *)

val create_local : unit -> 'a local
(** Create a runtime-local key. *)

val create_service_key : unit -> 'a service_key
(** Create a typed runtime-service key. *)

val register_worker_context_probe : (unit -> bool) -> unit
(** Register a backend-owned probe for construction-time checks that happen
    before an Eta effect has a runtime frame. Runtime packages should install
    probes for their worker substrates. *)

val in_registered_worker_context : unit -> bool
(** Return [true] if any registered backend reports that the current execution
    context is a runtime worker callback. *)

val of_runtime : (module RUNTIME) -> t
(** Erase a module-shaped runtime implementation into the interpreter record.
    New backends should implement {!RUNTIME}; this adapter is the only place
    that casts backend-owned scope, cancellation, promise, resolver, and stream
    values into Eta's erased representation. Erased tokens produced by one
    returned contract are owned by that contract; using them with another
    contract raises [Invalid_argument]. *)

module Backend : sig
  val local_id : 'a local -> int
  val local_binding_value : 'a local -> local_binding -> 'a option
  val service_key_id : 'a service_key -> int
  val service_value : 'a service_key -> service -> 'a option
end
(** Backend helpers that do not erase runtime-owned tokens. Runtime packages
    may use these helpers for typed locals and service bindings. Backend-owned
    scopes, cancellation handles, promises, resolvers, and streams must cross
    the interpreter boundary through {!of_runtime}. *)
