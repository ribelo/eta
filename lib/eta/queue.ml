type 'err close_reason = Clean | Error of 'err

type receiver = {
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable active : bool;
}

type ('a, 'err) t = {
  mutex : Sync_lock.t;
  values : 'a Stdlib.Queue.t;
  receivers : receiver Stdlib.Queue.t;
  mutable closed : 'err close_reason option;
  mutable sent : int;
  mutable received : int;
  mutable waiting_receivers : int;
  mutable cancelled_receivers : int;
}

type stats = {
  depth : int;
  sent : int;
  received : int;
  closed : bool;
  waiting_receivers : int;
  cancelled_receivers : int;
}

type 'err send_result = [ `Sent | `Closed | `Closed_with_error of 'err ]
type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

let create () =
  {
    mutex = Sync_lock.create ();
    values = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    closed = None;
    sent = 0;
    received = 0;
    waiting_receivers = 0;
    cancelled_receivers = 0;
  }

let unbounded = create

let with_lock (t : ('a, 'err) t) f =
  Sync_lock.use t.mutex f

let with_lock_during_cancel contract t f =
  contract.Runtime_contract.protect (fun () -> with_lock t f)

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let wake_receiver receiver =
  if receiver.active then (
    receiver.active <- false;
    receiver.contract.Runtime_contract.resolve_promise receiver.resolver ())

let rec take_active_receiver receivers =
  if Stdlib.Queue.is_empty receivers then None
  else
    let receiver = Stdlib.Queue.take receivers in
    if receiver.active then Some receiver else take_active_receiver receivers

let wake_one_receiver_locked (t : ('a, 'err) t) =
  match take_active_receiver t.receivers with
  | None -> ()
  | Some receiver ->
      t.waiting_receivers <- t.waiting_receivers - 1;
      wake_receiver receiver

let wake_all_receivers_locked (t : ('a, 'err) t) =
  let rec loop () =
    match take_active_receiver t.receivers with
    | None -> ()
    | Some receiver ->
        t.waiting_receivers <- t.waiting_receivers - 1;
        wake_receiver receiver;
        loop ()
  in
  loop ()

let compact_cancelled_receivers_locked (t : ('a, 'err) t) =
  if t.cancelled_receivers > 0 then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun receiver -> if receiver.active then Stdlib.Queue.push receiver live)
      t.receivers;
    Stdlib.Queue.clear t.receivers;
    Stdlib.Queue.iter
      (fun receiver -> Stdlib.Queue.push receiver t.receivers)
      live)

let cancel_receiver (t : ('a, 'err) t) receiver =
  if receiver.active then (
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    t.cancelled_receivers <- t.cancelled_receivers + 1;
    compact_cancelled_receivers_locked t)

let send_sync t value =
  with_lock t @@ fun () ->
  match t.closed with
  | Some reason -> close_result reason
  | None ->
      Stdlib.Queue.add value t.values;
      t.sent <- t.sent + 1;
      wake_one_receiver_locked t;
      `Sent

let try_send t value = Effect.sync (fun () -> send_sync t value)

let send t value =
  try_send t value
  |> Effect.bind (function
       | `Sent -> Effect.unit
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let take_value t =
  let value = Stdlib.Queue.take t.values in
  t.received <- t.received + 1;
  `Item value

let try_recv t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  if not (Stdlib.Queue.is_empty t.values) then take_value t
  else
    match t.closed with
    | None -> `Empty
    | Some reason -> close_result reason

let enqueue_receiver contract t =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let receiver = { contract; resolver; active = true } in
  Stdlib.Queue.add receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let recv_sync contract t =
  let rec loop () =
    match
      with_lock t @@ fun () ->
      if not (Stdlib.Queue.is_empty t.values) then `Ready (take_value t)
      else
        match t.closed with
        | Some reason -> `Ready (close_result reason)
        | None ->
            let promise, receiver = enqueue_receiver contract t in
            `Wait (promise, receiver)
    with
    | `Ready result -> result
    | `Wait (promise, receiver) -> (
        try
          contract.Runtime_contract.await_promise promise;
          loop ()
        with exn
          when Option.is_some
                 (contract.Runtime_contract.cancellation_reason exn) ->
          with_lock_during_cancel contract t (fun () ->
              cancel_receiver t receiver);
          raise exn)
  in
  loop ()

let recv t =
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         recv_sync frame.Effect_core.runtime.Runtime_core.contract t))
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let close_with reason t =
  with_lock t @@ fun () ->
  match t.closed with
  | Some _ -> ()
  | None ->
      t.closed <- Some reason;
      wake_all_receivers_locked t

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let close_effect t = Effect.sync (fun () -> close t)
let close_with_error_effect t error =
  Effect.sync (fun () -> close_with_error t error)

let stats t =
  Sync_lock.use t.mutex @@ fun () ->
  {
    depth = Stdlib.Queue.length t.values;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_receivers = t.waiting_receivers;
    cancelled_receivers = t.cancelled_receivers;
  }
