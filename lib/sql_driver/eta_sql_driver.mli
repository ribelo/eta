(** Shared runtime helpers for Eta SQL-style driver pools. *)

module type BACKEND = sig
  type driver_error
  type error

  val map_error : driver_error -> error
  val detach_started_error : error
end

module Make (Backend : BACKEND) : sig
  type driver_error = Backend.driver_error
  type error = Backend.error

  val map_result :
    (unit -> ('a, driver_error) result) -> unit -> ('a, error) result

  val blocking_result :
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?name:string ->
    ?on_cancel:(unit -> unit) ->
    (unit -> ('a, driver_error) result) ->
    ('a, error) Eta.Effect.t

  val reject_detach_started_blocking_pool :
    Eta_blocking.Pool.t option -> (unit, error) Eta.Effect.t

  val leased_blocking_result :
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?name:string ->
    ?on_cancel:(unit -> unit) ->
    (unit -> ('a, driver_error) result) ->
    ('a, error) Eta.Effect.t

  val leased_blocking_result_timeout :
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?name:string ->
    ?on_cancel:(unit -> unit) ->
    timeout:Eta.Duration.t ->
    on_timeout:error ->
    (unit -> ('a, driver_error) result) ->
    ('a, error) Eta.Effect.t
end
