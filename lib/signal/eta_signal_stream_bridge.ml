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
    ?(after_drop_acknowledged = fun () -> ())
    ~on_closed_with_error () =
  {
    after_try_send_before_ack;
    after_drop_before_ack;
    after_drop_acknowledged =
      (fun () ->
        record_drop metrics;
        after_drop_acknowledged ());
    on_closed_with_error;
  }

type ('finish_reason, 'queue_error) finish_policy = {
  is_invalid_scope : 'finish_reason -> bool;
  invalid_scope_error : 'queue_error;
}

let finish_policy ~is_invalid_scope ~invalid_scope_error =
  { is_invalid_scope; invalid_scope_error }

let observer_finish_policy =
  finish_policy
    ~is_invalid_scope:(function
      | Observer_lifecycle.Finish_disposed -> false
      | Observer_lifecycle.Finish_invalid_scope -> true)
    ~invalid_scope_error:`Invalid_scope

let finish_hook ~queue ~policy reason =
  if policy.is_invalid_scope reason then
    Queue.close_with_error queue policy.invalid_scope_error
  else Queue.close queue

let observer_finish_hook ~queue reason =
  finish_hook ~queue ~policy:observer_finish_policy reason

let acknowledge_once acknowledged acknowledge =
  if !acknowledged then Effect.unit
  else
    let open Eta.Syntax in
    let* () = acknowledge () in
    Effect.sync (fun () -> acknowledged := true)

let acknowledge_after_published ~published ~acknowledged acknowledge =
  if !acknowledged || not !published then Effect.unit
  else acknowledge_once acknowledged acknowledge

let report_dropped_update ~on_drop ~after_drop_before_ack
    ~after_drop_acknowledged ~acknowledge_drop update =
  let drop_published = ref false in
  let drop_acknowledged = ref false in
  let acknowledge_published_drop () =
    acknowledge_after_published ~published:drop_published
      ~acknowledged:drop_acknowledged (fun () ->
        acknowledge_drop ~after_ack:[ after_drop_acknowledged ] update)
  in
  let report_on_drop_failure exn =
    Effect.log_error
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
   let* () = after_drop_before_ack () in
   acknowledge_published_drop ())
  |> Effect.on_exit (fun _exit -> acknowledge_published_drop ())

let acknowledge_sent_after_published ~queue ~sent_before ~sent_published
    ~sent_acknowledged ~acknowledge_sent_once =
  let open Eta.Syntax in
  let* () =
    if !sent_published then Effect.unit
    else
      Effect.sync (fun () ->
          if
            not
              (Queue.same_sent_token
                 (Queue.sent_token queue)
                 sent_before)
          then sent_published := true)
  in
  acknowledge_after_published ~published:sent_published
    ~acknowledged:sent_acknowledged acknowledge_sent_once

let offer ~queue ~observer_delivery ~hooks ~on_drop =
  let open Eta.Syntax in
  let* current = Delivery_handle.current observer_delivery () in
  match current with
  | None -> Effect.unit
  | Some (token, update) ->
      let* sent_before = Effect.sync (fun () -> Queue.sent_token queue) in
      let sent_published = ref false in
      let sent_acknowledged = ref false in
      let acknowledge_sent_once () =
        Delivery_handle.acknowledge_sent observer_delivery token update
      in
      let acknowledge_published_sent () =
        acknowledge_sent_after_published ~queue ~sent_before ~sent_published
          ~sent_acknowledged ~acknowledge_sent_once
      in
      (let* send_result = Queue.try_send queue update in
       match send_result with
       | `Sent ->
           let* () = hooks.after_try_send_before_ack () in
           let* () = Effect.sync (fun () -> sent_published := true) in
           acknowledge_published_sent ()
       | `Closed -> Effect.unit
       | `Dropped | `Full ->
           report_dropped_update ~on_drop
             ~after_drop_before_ack:hooks.after_drop_before_ack
             ~after_drop_acknowledged:hooks.after_drop_acknowledged
             ~acknowledge_drop:(fun ~after_ack update ->
               Delivery_handle.acknowledge_drop observer_delivery ~after_ack
                 token update)
             update
       | `Closed_with_error err -> hooks.on_closed_with_error err)
      |> Effect.on_exit (fun _exit -> acknowledge_published_sent ())

let observe ~capacity ?on_drop ?equal ~metrics ~on_closed_with_error
    ~map_observe_error ~observe_delivery signal =
  let open Eta.Syntax in
  let hooks = hooks ~metrics ~on_closed_with_error () in
  let* queue, stream =
    Effect.sync (fun () -> create_stream ~capacity)
    |> Effect.flatten_result
  in
  let+ observer =
    observe_delivery ?equal
      ~on_finish:[ observer_finish_hook ~queue ]
      signal
      (fun observer_delivery ->
        offer ~queue ~observer_delivery ~hooks ~on_drop)
    |> Effect.map_error map_observe_error
  in
  (observer, stream)
