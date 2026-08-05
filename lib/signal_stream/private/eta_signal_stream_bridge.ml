exception Closed_with_invalid_scope
(** Defect raised when a bridge publication reaches a queue already closed by
    invalid scope. The graph lane and lifecycle finish hooks normally
    serialize close and publication, so this path requires an interrupted
    delivery. *)

module Make (Source : Eta_signal.Stream_source) = struct
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

  let acknowledge_once acknowledged acknowledge =
    if !acknowledged then Effect.unit
    else
      let open Eta.Syntax in
      let* () = acknowledge () in
      Effect.sync (fun () -> acknowledged := true)

  let acknowledge_after_published ~published ~acknowledged acknowledge =
    if !acknowledged || not !published then Effect.unit
    else acknowledge_once acknowledged acknowledge

  let report_dropped_update ~on_drop ~acknowledge update =
    let drop_published = ref false in
    let drop_acknowledged = ref false in
    let acknowledge_published_drop () =
      acknowledge_after_published ~published:drop_published
        ~acknowledged:drop_acknowledged acknowledge
    in
    let report_on_drop_failure exn =
      Eta_observability.log_error
        ~attrs:[ ("exception.message", Printexc.to_string exn) ]
        "eta_signal.stream.on_drop_failure"
    in
    let open Eta.Syntax in
    (let* on_drop_failure =
       Effect.sync (fun () ->
           let on_drop_failure =
             match on_drop with
             | None -> None
             | Some on_drop -> (
                 try
                   on_drop update;
                   None
                 with exn -> Some exn)
           in
           drop_published := true;
           on_drop_failure)
     in
     let* () =
       match on_drop_failure with
       | None -> Effect.unit
       | Some exn -> report_on_drop_failure exn
     in
     acknowledge_published_drop ())
    |> Effect.on_exit (fun _exit -> acknowledge_published_drop ())

  let acknowledge_sent_after_published ~queue ~sent_before ~sent_published
      ~sent_acknowledged ~acknowledge_sent_once =
    let open Eta.Syntax in
    let* () =
      if !sent_published then Effect.unit
      else
        Effect.sync (fun () ->
            if not (Queue.same_sent_token (Queue.sent_token queue) sent_before)
            then sent_published := true)
    in
    acknowledge_after_published ~published:sent_published
      ~acknowledged:sent_acknowledged acknowledge_sent_once

  let offer ~queue ~on_drop delivery =
    let open Eta.Syntax in
    let* current = Source.current delivery in
    match current with
    | None -> Effect.unit
    | Some update ->
        let* sent_before = Effect.sync (fun () -> Queue.sent_token queue) in
        let sent_published = ref false in
        let sent_acknowledged = ref false in
        let acknowledge_sent_once () = Source.acknowledge delivery in
        let acknowledge_published_sent () =
          acknowledge_sent_after_published ~queue ~sent_before ~sent_published
            ~sent_acknowledged ~acknowledge_sent_once
        in
        (let* send_result = Queue.try_offer queue update in
         match send_result with
         | `Sent ->
             let* () = Effect.sync (fun () -> sent_published := true) in
             acknowledge_published_sent ()
         | `Closed -> Effect.unit
         | `Dropped | `Full ->
             report_dropped_update ~on_drop
               ~acknowledge:(fun () -> Source.acknowledge delivery)
               update
         | `Closed_with_error `Invalid_scope ->
             Effect.sync (fun () -> raise Closed_with_invalid_scope))
        |> Effect.on_exit (fun _exit -> acknowledge_published_sent ())

  let observe ?(capacity = default_capacity) ?on_drop
      ?(cutoff = Eta_signal.Cutoff.phys_equal) signal =
    let open Eta.Syntax in
    let* queue, stream =
      Effect.sync (fun () -> create_stream ~capacity) |> Effect.flatten_result
    in
    let+ observer =
      Source.observe_delivery ~cutoff ~on_finish:(finish_hook ~queue) signal
        (fun delivery -> offer ~queue ~on_drop delivery)
      |> Effect.map_error (fun err -> (err :> [ Eta_signal.graph_error
                                              | `Invalid_capacity ]))
    in
    (observer, stream)
end
