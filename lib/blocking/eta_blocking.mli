(** Native blocking worker pools for synchronous calls.

    This package is intentionally outside root [eta]. Use it when a native
    runtime can offload synchronous callbacks to a worker substrate. Runtime
    packages such as [eta_eio] provide the worker runner; backend-neutral Eta
    code should keep depending only on [eta]. *)

module Pool : sig
  type t

  type queue_policy = Wait | Reject
  type shutdown_policy = Drain | Detach_started

  type config = {
    max_threads : int;
    max_queued : int;
    queue_policy : queue_policy;
    shutdown_policy : shutdown_policy;
  }

  type stats = {
    active : int;
    queued : int;
    completed : int;
    rejected : int;
    cancelled_before_start : int;
    detached : int;
  }

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

val run :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a) ->
  ('a, 'err) Eta.Effect.t

val result :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t

val result_timeout :
  ?pool:Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  timeout:Eta.Duration.t ->
  on_timeout:'err ->
  (unit -> ('a, 'err) result) ->
  ('a, 'err) Eta.Effect.t
