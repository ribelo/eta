module Effect = Eta.Effect
module Queue = Eta.Queue

let default_capacity = 1024

let create_queue ~capacity =
  if capacity <= 0 then Error `Invalid_capacity
  else Ok (Queue.create ~overflow:(Queue.Drop_new { capacity }) ())

let report_dropped_update ~on_drop ~after_drop_before_ack ~acknowledge_drop
    update =
  let drop_published = ref false in
  let drop_acknowledged = ref false in
  let acknowledge_published_drop () =
    if (not !drop_acknowledged) && !drop_published then
      acknowledge_drop update
      |> Effect.bind (fun () ->
             Effect.sync (fun () -> drop_acknowledged := true))
    else Effect.unit
  in
  let report_on_drop_failure exn =
    Effect.log_error
      ~attrs:[ ("exception.message", Printexc.to_string exn) ]
      "eta_signal.stream.on_drop_failure"
  in
  (Effect.sync (fun () ->
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
   |> Effect.bind (function
        | None -> Effect.unit
        | Some exn -> report_on_drop_failure exn)
   |> Effect.bind (fun () -> after_drop_before_ack ())
   |> Effect.bind (fun () -> acknowledge_published_drop ()))
  |> Effect.on_exit (fun _exit -> acknowledge_published_drop ())

let offer ~queue ~current_token ~acknowledge_sent ~acknowledge_drop
    ~after_try_send_before_ack ~after_drop_before_ack ~on_closed_with_error
    ~on_drop update =
  current_token ()
  |> Effect.bind (function
       | None -> Effect.unit
       | Some token ->
           Effect.sync (fun () -> Queue.sent_token queue)
           |> Effect.bind (fun sent_before ->
                  let sent_published = ref false in
                  let sent_acknowledged = ref false in
                  let acknowledge_sent_once () =
                    if !sent_acknowledged then Effect.unit
                    else
                      acknowledge_sent token update
                      |> Effect.bind (fun () ->
                             Effect.sync (fun () -> sent_acknowledged := true))
                  in
                  let acknowledge_published_sent () =
                    if !sent_acknowledged then Effect.unit
                    else if !sent_published then acknowledge_sent_once ()
                    else
                      Effect.sync (fun () ->
                          if
                            not
                              (Queue.same_sent_token
                                 (Queue.sent_token queue)
                                 sent_before)
                          then sent_published := true)
                      |> Effect.bind (fun () ->
                             if !sent_published then acknowledge_sent_once ()
                             else Effect.unit)
                  in
                  (Queue.try_send queue update
                   |> Effect.bind (function
                        | `Sent ->
                            after_try_send_before_ack ()
                            |> Effect.bind (fun () ->
                                   Effect.sync (fun () ->
                                       sent_published := true))
                            |> Effect.bind (fun () ->
                                   acknowledge_published_sent ())
                        | `Closed -> Effect.unit
                        | `Dropped | `Full ->
                            report_dropped_update ~on_drop
                              ~after_drop_before_ack
                              ~acknowledge_drop:(acknowledge_drop token)
                              update
                        | `Closed_with_error err -> on_closed_with_error err))
                  |> Effect.on_exit (fun _exit -> acknowledge_published_sent ())))
