type 'err close_reason = Clean | Error of 'err

type ('a, 'err) t = {
  mutex : Eio.Mutex.t;
  cond : Eio.Condition.t;
  values : 'a Stdlib.Queue.t;
  mutable closed : 'err close_reason option;
  mutable sent : int;
  mutable received : int;
  mutable waiting_receivers : int;
  mutable cancelled_receivers : int;
}

type stats : immutable_data = {
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
    mutex = Eio.Mutex.create ();
    cond = Eio.Condition.create ();
    values = Stdlib.Queue.create ();
    closed = None;
    sent = 0;
    received = 0;
    waiting_receivers = 0;
    cancelled_receivers = 0;
  }

let unbounded = create

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let send_sync t value =
  with_lock t @@ fun () ->
  match t.closed with
  | Some reason -> close_result reason
  | None ->
      Stdlib.Queue.add value t.values;
      t.sent <- t.sent + 1;
      Eio.Condition.broadcast t.cond;
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

let recv_sync t =
  Eio.Mutex.lock t.mutex;
  let rec loop () =
    if not (Stdlib.Queue.is_empty t.values) then take_value t
    else
      match t.closed with
      | Some reason -> close_result reason
      | None ->
          t.waiting_receivers <- t.waiting_receivers + 1;
          (try Eio.Condition.await t.cond t.mutex
           with exn ->
             t.waiting_receivers <- t.waiting_receivers - 1;
             t.cancelled_receivers <- t.cancelled_receivers + 1;
             raise exn);
          t.waiting_receivers <- t.waiting_receivers - 1;
          loop ()
  in
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) loop

let recv t =
  Effect.sync (fun () -> recv_sync t)
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
      Eio.Condition.broadcast t.cond

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let stats t =
  Eio.Mutex.use_ro t.mutex @@ fun () ->
  {
    depth = Stdlib.Queue.length t.values;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_receivers = t.waiting_receivers;
    cancelled_receivers = t.cancelled_receivers;
  }
