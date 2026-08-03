(** Native blocking worker pools for synchronous calls.

    This package is intentionally outside root [eta]. Use it when a native
    runtime can offload synchronous callbacks to a worker substrate. Runtime
    packages such as [eta_eio] provide the worker runner; backend-neutral Eta
    code should keep depending only on [eta]. *)

module Pool : sig
  type t

  type shutdown_policy = Drain | Detach_started

  type config = {
    max_threads : int;
    max_queued : int;
    shutdown_policy : shutdown_policy;
  }
  (** [max_threads] bounds reserved worker slots. [max_queued] bounds callbacks
      admitted by [Eta_blocking.run] while all worker slots are occupied.
      Further [Eta_blocking.run] callers wait outside the bounded queue. *)

  type stats = {
    active : int;
    queued : int;
    waiting : int;
    completed : int;
    rejected : int;
    cancelled_before_start : int;
    detached : int;
  }
  (** [active] includes every reserved slot until physical callback completion.
      [queued] counts admitted bounded-queue entries, and [waiting] counts
      ordinary blocking operations that have not been admitted. [rejected]
      counts fail-fast saturation only. *)

  type runner = {
    run_worker : 'a. label:string -> (unit -> 'a) -> 'a;
  }

  val create : ?name:string -> ?runner:runner -> config -> t
  val shutdown_policy : t -> shutdown_policy
  val stats : t -> stats
  val shutdown : t -> (unit, 'err) Eta.Effect.t
end

val runtime_service :
  ?pool:Pool.t -> ?runner:Pool.runner -> unit -> Eta.Runtime_contract.service
(** Runtime service consumed by blocking effects that do not carry an explicit
    pool or runner. Runtime backends should attach this when they can provide
    a native blocking-worker substrate. *)

val with_defaults :
  ?pool:Pool.t ->
  ?runner:Pool.runner ->
  ('a, 'err) Eta.Effect.t ->
  ('a, 'err) Eta.Effect.t
(** Override the ambient blocking defaults for a subtree. *)

type admission_failure = Saturated | Shutting_down
type 'a try_run_outcome = Completed of 'a | Not_run of admission_failure

val run :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a) ->
  ('a, 'err) Eta.Effect.t
(** Run a blocking callback, waiting for a worker or bounded-queue admission when
    necessary. Pool shutdown before callback start interrupts the effect. *)

val try_run :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a) ->
  ('a try_run_outcome, 'err) Eta.Effect.t
(** Run a blocking callback only when a worker slot is immediately available.
    This operation never enters the bounded queue. Saturation returns
    [Not_run Saturated], and shutdown before worker claim returns
    [Not_run Shutting_down], without running the callback.

    Caller interruption before worker claim prevents the callback and does not
    invoke [on_cancel]. After worker claim, [on_cancel] can run at most once and
    the slot remains occupied until physical callback completion. *)

val run_result :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t
(** Run a blocking leaf that returns an OCaml [result].

    [Ok value] becomes success and [Error err] becomes a typed failure.
    Exceptions raised by the callback remain unchecked defects, exactly like
    {!run}. *)

val try_run_result :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> ('a, 'err) result) ->
  ('a try_run_outcome, 'err) Eta.Effect.t
(** Like {!try_run}, but [Ok value] becomes [Completed value] and [Error err]
    remains a typed Eta failure. *)

val result :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t
(** Short alias for {!run_result}.

    New examples and docs prefer {!run_result} because it makes the boundary
    from OCaml [result] into Eta's typed error channel explicit. *)

val run_result_timeout :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  timeout:Eta.Duration.t ->
  on_timeout:'err ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t
(** Like {!run_result}, but bound the caller's wait with [timeout].

    If the worker has not completed before the timeout, the effect fails with
    [on_timeout]. [on_cancel] is called at most once for started work. *)

val result_timeout :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  timeout:Eta.Duration.t ->
  on_timeout:'err ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t
(** Short alias for {!run_result_timeout}.

    New examples and docs prefer {!run_result_timeout} for the same reason as
    {!run_result}. *)
