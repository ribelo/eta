(** Shared runtime helpers for Eta SQL-style driver pools. *)

module type BACKEND = sig
  type driver_error
  type error

  val map_error : driver_error -> error
  val detach_started_error : error
end

module Make (Backend : BACKEND) = struct
  type driver_error = Backend.driver_error
  type error = Backend.error

  let map_result f () =
    match f () with
    | Ok value -> Ok value
    | Error err -> Error (Backend.map_error err)

  let blocking_result ?blocking_pool ?name ?on_cancel f =
    Eta_blocking.result ?pool:blocking_pool ?name ?on_cancel
      (map_result f)

  let reject_detach_started_blocking_pool = function
    | Some pool
      when Eta_blocking.Pool.shutdown_policy pool
           = Eta_blocking.Pool.Detach_started ->
        Eta.Effect.fail Backend.detach_started_error
    | Some _ | None -> Eta.Effect.unit

  let leased_blocking_result ?blocking_pool ?name ?on_cancel f =
    (* A detached worker can keep using a checked-out connection after the pool has
       returned it to another caller, so every leased driver call rejects those
       pools at the shared boundary. *)
    reject_detach_started_blocking_pool blocking_pool
    |> Eta.Effect.bind (fun () ->
           blocking_result ?blocking_pool ?name ?on_cancel f)

  let leased_blocking_result_timeout ?blocking_pool ?name ?on_cancel ~timeout
      ~on_timeout f =
    reject_detach_started_blocking_pool blocking_pool
    |> Eta.Effect.bind (fun () ->
           Eta_blocking.result_timeout ?pool:blocking_pool ?name
             ?on_cancel ~timeout ~on_timeout (map_result f))
end
