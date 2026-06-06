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

type 'a service_key
(** Typed key for runtime services supplied by optional packages. *)

type service = Service : 'a service_key * 'a -> service
(** Packed runtime service binding. Runtime packages use this to attach
    optional capabilities without adding those capability types to root
    [eta]. *)

type t = {
  root_scope : scope;
  now_ms : unit -> int;
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
}
(** Erased backend runtime contract used by the current interpreter.

    This record is one of the two runtime layers Eta intentionally exposes:
    backend packages author against the typed {!RUNTIME} module shape, and
    {!of_runtime} erases that implementation into this record for the root
    interpreter. The [Obj.t] representation is confined to the adapter and
    {!Backend} bridge below; do not add another mirror record of backend
    operations. Concurrency and parallelism semantics belong to the backend
    implementation; the contract only states what Eta can ask for. *)

module type RUNTIME = sig
  type scope
  type cancel_context
  type 'a promise
  type 'a resolver
  type 'a stream

  val root_scope : scope
  val now_ms : unit -> int
  val sleep : Duration.t -> unit
  val protect : (unit -> 'a) -> 'a
  val run_scope : ?name:string -> (scope -> 'a) -> 'a
  val fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit
  val fork : scope -> (unit -> unit) -> unit
  val fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit
  val await_cancel : unit -> 'a
  val yield : unit -> unit
  val check : unit -> unit
  val create_promise : unit -> 'a promise * 'a resolver
  val resolve_promise : 'a resolver -> 'a -> unit
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
end
(** Module-shaped runtime backend contract. Runtime packages should implement
    this shape. It is the typed authoring surface for backends; {!t} is the
    erased interpreter representation. Fully functorizing the interpreter over
    [RUNTIME] remains the long-term endgame if this boundary becomes a measured
    cost or correctness constraint, but it is not treated as imminent migration
    work. Until then, keep the design to these two layers. *)

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
    that should cast backend-owned scope, cancellation, promise, resolver, and
    stream values into Eta's erased representation. *)

module Backend : sig
  val local_id : 'a local -> int
  val service_key_id : 'a service_key -> int
  val scope : Obj.t -> scope
  val scope_value : scope -> Obj.t
  val cancel_context : Obj.t -> cancel_context
  val cancel_context_value : cancel_context -> Obj.t
  val promise : Obj.t -> 'a promise
  val promise_value : 'a promise -> Obj.t
  val resolver : Obj.t -> 'a resolver
  val resolver_value : 'a resolver -> Obj.t
  val stream : Obj.t -> 'a stream
  val stream_value : 'a stream -> Obj.t
end
(** Unsafe token bridge for backend packages and {!of_runtime}. Keep use
    localized to runtime implementations such as [eta_eio] and do not build
    additional erased runtime surfaces on top of it. *)
