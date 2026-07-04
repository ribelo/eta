module Effect = Eta.Effect
module Queue = Eta.Queue
module Delivery_handle = Eta_signal_observer.Delivery_handle
module Observer_lifecycle = Eta_signal_observer.Lifecycle

let default_capacity = 1024

type metrics = { mutable drop_count : int }

let create_metrics ?(drop_count = 0) () = { drop_count }

let drop_count metrics = metrics.drop_count

let record_drop metrics =
  if metrics.drop_count < max_int then
    metrics.drop_count <- metrics.drop_count + 1

let create_queue ~capacity =
  if capacity <= 0 then Error `Invalid_capacity
  else Ok (Queue.create ~overflow:(Queue.Drop_new { capacity }) ())

let create_stream ~capacity =
  create_queue ~capacity
  |> Result.map (fun queue -> (queue, Eta_stream.Stream.from_queue queue))

type ('token, 'update, 'error) observer_delivery =
  ('token, 'update, unit -> unit) Delivery_handle.t

type ('queue_error, 'error) hooks = {
  after_try_send_before_ack : unit -> (unit, 'error) Effect.t;
  after_drop_before_ack : unit -> (unit, 'error) Effect.t;
  after_drop_acknowledged : unit -> unit;
  on_closed_with_error : 'queue_error -> (unit, 'error) Effect.t;
}

let hooks ~metrics
    ?(after_try_send_before_ack = fun () -> Effect.unit)
    ?(after_drop_before_ack = fun () -> Effect.unit)
    ~on_closed_with_error () =
  {
    after_try_send_before_ack;
    after_drop_before_ack;
    after_drop_acknowledged = (fun () -> record_drop metrics);
    on_closed_with_error;
  }

type ('finish_reason, 'queue_error) finish_policy = {
  is_invalid_scope : 'finish_reason -> bool;
  invalid_scope_error : 'queue_error;
}

let observer_finish_policy =
  {
    is_invalid_scope =
      (function
      | Observer_lifecycle.Finish_disposed -> false
      | Observer_lifecycle.Finish_invalid_scope -> true);
    invalid_scope_error = `Invalid_scope;
  }

let finish_hook ~queue ~policy reason =
  if policy.is_invalid_scope reason then
    Queue.close_with_error queue policy.invalid_scope_error
  else Queue.close queue

let observer_finish_hook ~queue reason =
  finish_hook ~queue ~policy:observer_finish_policy reason

let report_dropped_update ~on_drop ~after_drop_before_ack
    ~after_drop_acknowledged ~acknowledge_drop update =
  let drop_published = ref false in
  let drop_acknowledged = ref false in
  let acknowledge_published_drop () =
    if (not !drop_acknowledged) && !drop_published then
      acknowledge_drop ~after_ack:[ after_drop_acknowledged ] update
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

let offer ~queue ~observer_delivery ~hooks ~on_drop =
  Delivery_handle.current_token observer_delivery ()
  |> Effect.bind (function
       | None -> Effect.unit
       | Some token ->
           let update = Delivery_handle.update observer_delivery in
           Effect.sync (fun () -> Queue.sent_token queue)
           |> Effect.bind (fun sent_before ->
                  let sent_published = ref false in
                  let sent_acknowledged = ref false in
                  let acknowledge_sent_once () =
                    if !sent_acknowledged then Effect.unit
                    else
                      Delivery_handle.acknowledge_sent observer_delivery token
                        update
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
                            hooks.after_try_send_before_ack ()
                            |> Effect.bind (fun () ->
                                   Effect.sync (fun () ->
                                       sent_published := true))
                            |> Effect.bind (fun () ->
                                   acknowledge_published_sent ())
                        | `Closed -> Effect.unit
                        | `Dropped | `Full ->
                            report_dropped_update ~on_drop
                              ~after_drop_before_ack:
                                hooks.after_drop_before_ack
                              ~after_drop_acknowledged:
                                hooks.after_drop_acknowledged
                              ~acknowledge_drop:
                                (fun ~after_ack update ->
                                  Delivery_handle.acknowledge_drop
                                    observer_delivery ~after_ack token update)
                              update
                        | `Closed_with_error err ->
                            hooks.on_closed_with_error err))
                  |> Effect.on_exit (fun _exit -> acknowledge_published_sent ())))

let observe ~capacity ?on_drop ?equal ~hooks ~map_observe_error
    ~observe_delivery signal =
  Effect.sync (fun () -> create_stream ~capacity)
  |> Effect.flatten_result
  |> Effect.bind (fun (queue, stream) ->
         observe_delivery ?equal
           ~on_finish:[ observer_finish_hook ~queue ]
           signal
           (fun observer_delivery ->
             offer ~queue ~observer_delivery ~hooks ~on_drop)
         |> Effect.map_error map_observe_error
         |> Effect.map (fun observer -> (observer, stream)))
