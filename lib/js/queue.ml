type 'err close_reason =
  | Clean
  | Error of 'err

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) receiver = {
  mutable active : bool;
  resume : ('a, 'err) recv_result -> unit;
}

type ('a, 'err) t = {
  values : 'a Stdlib.Queue.t;
  receivers : ('a, 'err) receiver Stdlib.Queue.t;
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

let create () =
  {
    values = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    closed = None;
    sent = 0;
    received = 0;
    waiting_receivers = 0;
    cancelled_receivers = 0;
  }

let unbounded = create

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let take_value (t : ('a, 'err) t) =
  let value = Stdlib.Queue.take t.values in
  t.received <- t.received + 1;
  `Item value

let recv_result (t : ('a, 'err) t) =
  if not (Stdlib.Queue.is_empty t.values) then take_value t
  else
    match t.closed with
    | None -> `Empty
    | Some reason -> close_result reason

let rec take_active_receiver receivers =
  if Stdlib.Queue.is_empty receivers then None
  else
    let receiver = Stdlib.Queue.take receivers in
    if receiver.active then Some receiver else take_active_receiver receivers

let wake_receiver (t : ('a, 'err) t) receiver =
  if receiver.active then begin
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    match recv_result t with
    | `Empty -> ()
    | result -> receiver.resume result
  end

let wake_one_receiver (t : ('a, 'err) t) =
  match take_active_receiver t.receivers with
  | None -> ()
  | Some receiver -> wake_receiver t receiver

let wake_all_receivers (t : ('a, 'err) t) =
  let rec loop () =
    match take_active_receiver t.receivers with
    | None -> ()
    | Some receiver ->
        wake_receiver t receiver;
        loop ()
  in
  loop ()

let cancel_receiver (t : ('a, 'err) t) receiver =
  if receiver.active then begin
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    t.cancelled_receivers <- t.cancelled_receivers + 1
  end

let send_sync (t : ('a, 'err) t) value =
  match t.closed with
  | Some reason -> close_result reason
  | None ->
      t.sent <- t.sent + 1;
      Stdlib.Queue.add value t.values;
      wake_one_receiver t;
      `Sent

let try_send t value = Effect.sync (fun () -> send_sync t value)

let send t value =
  Effect.bind
    (function
      | `Sent -> Effect.unit
      | `Closed -> Effect.fail `Closed
      | `Closed_with_error error -> Effect.fail (`Closed_with_error error))
    (try_send t value)

let try_recv t = Effect.sync (fun () -> recv_result t)

let recv_wait t =
  Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
      let receiver =
        {
          active = true;
          resume =
            (function
            | `Item value -> resume (Exit.ok value)
            | `Closed -> resume (Exit.error (Cause.fail `Closed))
            | `Closed_with_error error ->
                resume (Exit.error (Cause.fail (`Closed_with_error error)))
            | `Empty -> assert false);
        }
      in
      Stdlib.Queue.add receiver t.receivers;
      t.waiting_receivers <- t.waiting_receivers + 1;
      on_cancel (fun () -> cancel_receiver t receiver))

let recv t =
  Effect.bind
    (function
      | `Item value -> Effect.pure value
      | `Closed -> Effect.fail `Closed
      | `Closed_with_error error -> Effect.fail (`Closed_with_error error)
      | `Empty -> recv_wait t)
    (try_recv t)

let close_with reason (t : ('a, 'err) t) =
  match t.closed with
  | Some _ -> ()
  | None ->
      t.closed <- Some reason;
      wake_all_receivers t

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let stats (t : ('a, 'err) t) =
  {
    depth = Stdlib.Queue.length t.values;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_receivers = t.waiting_receivers;
    cancelled_receivers = t.cancelled_receivers;
  }
