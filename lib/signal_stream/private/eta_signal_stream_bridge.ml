exception Closed_with_invalid_scope
(** Defect raised when a bridge publication reaches a queue already closed by
    invalid scope. The delivery phase and lifecycle finish hooks normally
    serialize close and publication, so this path requires an interrupted
    delivery. *)

module type Source = sig
  type 'a signal
  type 'a observer
  type observer_error

  type 'a update =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  module Observer : sig
    type 'a t = 'a observer

    val observe :
      ?cutoff:'a Eta_signal.Cutoff.t ->
      ?on_finish:([ `Disposed | `Invalid_scope ] -> unit) ->
      ?on_update:('a update -> (unit, observer_error) result) ->
      'a signal ->
      ('a t, Eta_signal.graph_error) result

    val dispose : 'a t -> (unit, Eta_signal.graph_error) result
  end
end

module Make (Source : Source) = struct
  module Effect = Eta.Effect
  module Queue = Eta.Queue

  let default_capacity = 1024

  let create_stream ~capacity =
    if capacity <= 0 then Error `Invalid_capacity
    else
      let queue = Queue.dropping ~capacity () in
      Ok (queue, Eta_stream.Stream.from_queue queue)

  let finish_hook ~queue = function
    | `Disposed -> Queue.close queue
    | `Invalid_scope -> Queue.close_with_error queue `Invalid_scope

  let pending_reports : (string * exn) list ref = ref []

  let flush_reports () =
    let reports = List.rev !pending_reports in
    pending_reports := [];
    let open Eta.Syntax in
    let rec loop = function
      | [] -> Effect.unit
      | (body, exn) :: rest ->
          let* () =
            Eta_observability.log_error
              ~attrs:[ ("exception.message", Printexc.to_string exn) ]
              body
          in
          loop rest
    in
    loop reports

  let offer ~queue ~on_drop update : (unit, 'error) result =
    match
      try Ok (Queue.try_offer_now queue update) with exn -> Error exn
    with
    | Error exn ->
        (* The queue commits a send before waking consumers, so a defect here
           leaves an unknown outcome: the update may already be visible.
           Retrying could duplicate it. Acknowledge and report instead. *)
        pending_reports :=
          ("eta_signal.stream.offer_failure", exn) :: !pending_reports;
        Ok ()
    | Ok (`Sent | `Closed) -> Ok ()
    | Ok (`Dropped | `Full) ->
        (match on_drop with
        | None -> ()
        | Some on_drop ->
            (try on_drop update with exn ->
              pending_reports :=
                ("eta_signal.stream.on_drop_failure", exn)
                :: !pending_reports));
        Ok ()
    | Ok (`Closed_with_error `Invalid_scope) ->
        raise Closed_with_invalid_scope

  let observe ?(capacity = default_capacity) ?on_drop
      ?(cutoff = Eta_signal.Cutoff.phys_equal) signal =
    let open Eta.Syntax in
    let* () = flush_reports () in
    let* queue, stream =
      Effect.sync (fun () -> create_stream ~capacity) |> Effect.flatten_result
    in
    let+ observer =
      Effect.sync_result (fun () ->
        Source.Observer.observe ~cutoff ~on_finish:(finish_hook ~queue)
          ~on_update:(fun update -> offer ~queue ~on_drop update)
          signal)
      |> Effect.map_error (fun err -> (err :> [ Eta_signal.graph_error
                                              | `Invalid_capacity ]))
    in
    (observer, stream)
end
