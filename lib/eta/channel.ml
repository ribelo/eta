type 'err send_result =
  [ `Sent | `Full | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type 'err close_reason = Clean | Error of 'err

type ('a, 'err) sender = {
  value : 'a;
  resolver : 'err send_result Eio.Promise.u;
  mutable active : bool;
}

type ('a, 'err) receiver = {
  resolver : ('a, 'err) recv_result Eio.Promise.u;
  mutable state : 'a receiver_state;
}

and 'a receiver_state =
  | Waiting
  | Delivered of 'a
  | Claimed
  | Cancelled

type ('a, 'err) t = {
  mutex : Eio.Mutex.t;
  buffer : 'a option array;
  senders : ('a, 'err) sender Stdlib.Queue.t;
  receivers : ('a, 'err) receiver Stdlib.Queue.t;
  capacity : int;
  mutable head : int;
  mutable tail : int;
  mutable depth : int;
  mutable pending_receivers : int;
  mutable sent : int;
  mutable received : int;
  mutable closed : 'err close_reason option;
  mutable waiting_senders : int;
  mutable waiting_receivers : int;
  mutable cancelled_senders : int;
}

type stats = {
  depth : int;
  sent : int;
  received : int;
  closed : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
}

let create ~capacity () =
  if capacity <= 0 then invalid_arg "Eta.Channel.create: capacity must be > 0";
  {
    mutex = Eio.Mutex.create ();
    buffer = Array.make capacity None;
    senders = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    capacity;
    head = 0;
    tail = 0;
    depth = 0;
    pending_receivers = 0;
    sent = 0;
    received = 0;
    closed = None;
    waiting_senders = 0;
    waiting_receivers = 0;
    cancelled_senders = 0;
  }

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let capacity_used (t : ('a, 'err) t) = t.depth + t.pending_receivers

let ensure_capacity (t : ('a, 'err) t) operation =
  if capacity_used t >= t.capacity then
    invalid_arg ("Eta.Channel." ^ operation ^ ": capacity exceeded")

let push (t : ('a, 'err) t) value =
  ensure_capacity t "push";
  t.buffer.(t.tail) <- Some value;
  t.tail <- (t.tail + 1) mod t.capacity;
  t.depth <- t.depth + 1

let push_counted (t : ('a, 'err) t) value =
  push t value;
  t.sent <- t.sent + 1

let push_front (t : ('a, 'err) t) value =
  ensure_capacity t "push_front";
  t.head <- (t.head + t.capacity - 1) mod t.capacity;
  t.buffer.(t.head) <- Some value;
  t.depth <- t.depth + 1

let pop_raw (t : ('a, 'err) t) =
  match t.buffer.(t.head) with
  | None -> invalid_arg "Eta.Channel.pop: empty slot"
  | Some value ->
      t.buffer.(t.head) <- None;
      t.head <- (t.head + 1) mod t.capacity;
      t.depth <- t.depth - 1;
      value

let pop (t : ('a, 'err) t) =
  let value = pop_raw t in
  t.received <- t.received + 1;
  value

let rec take_active_sender
    (q : ('a, 'err) sender Stdlib.Queue.t) :
    ('a, 'err) sender option =
  if Stdlib.Queue.is_empty q then None
  else
    let waiter = Stdlib.Queue.take q in
    if waiter.active then Some waiter else take_active_sender q

let rec take_active_receiver
    (q : ('a, 'err) receiver Stdlib.Queue.t) :
    ('a, 'err) receiver option =
  if Stdlib.Queue.is_empty q then None
  else
    let waiter = Stdlib.Queue.take q in
    match waiter.state with
    | Waiting -> Some waiter
    | Delivered _ | Claimed | Cancelled -> take_active_receiver q

let take_sender (t : ('a, 'err) t) =
  match take_active_sender t.senders with
  | None -> None
  | Some sender ->
      sender.active <- false;
      t.waiting_senders <- t.waiting_senders - 1;
      Some sender

let take_receiver (t : ('a, 'err) t) =
  match take_active_receiver t.receivers with
  | None -> None
  | Some receiver ->
      t.waiting_receivers <- t.waiting_receivers - 1;
      Some receiver

let reserve_receiver_delivery (t : ('a, 'err) t) =
  ensure_capacity t "deliver_receiver";
  t.pending_receivers <- t.pending_receivers + 1

let release_receiver_delivery (t : ('a, 'err) t) =
  if t.pending_receivers <= 0 then
    invalid_arg "Eta.Channel.deliver_receiver: pending receiver underflow";
  t.pending_receivers <- t.pending_receivers - 1

let deliver_receiver (t : ('a, 'err) t) (receiver : ('a, 'err) receiver) value =
  reserve_receiver_delivery t;
  receiver.state <- Delivered value;
  Eio.Promise.resolve receiver.resolver (`Item value)

let claim_receiver (t : ('a, 'err) t) receiver =
  match receiver.state with
  | Delivered _ ->
      receiver.state <- Claimed;
      release_receiver_delivery t;
      t.received <- t.received + 1
  | Waiting | Claimed | Cancelled -> ()

let return_unclaimed_value (t : ('a, 'err) t) value =
  match take_receiver t with
  | Some receiver -> deliver_receiver t receiver value
  | None -> push_front t value

let rec drain_buffer_to_receivers (t : ('a, 'err) t) =
  if t.depth > 0 then
    match take_receiver t with
    | None -> ()
    | Some receiver ->
        let value = pop_raw t in
        deliver_receiver t receiver value;
        drain_buffer_to_receivers t

let rec admit_waiting_senders (t : ('a, 'err) t) =
  if Option.is_none t.closed && capacity_used t < t.capacity then
    match take_sender t with
    | None -> ()
    | Some sender -> (
        if t.depth = 0 then
          match take_receiver t with
          | Some receiver ->
              t.sent <- t.sent + 1;
              deliver_receiver t receiver sender.value;
              Eio.Promise.resolve sender.resolver `Sent;
              admit_waiting_senders t
          | None ->
              push_counted t sender.value;
              Eio.Promise.resolve sender.resolver `Sent;
              admit_waiting_senders t
        else (
          push_counted t sender.value;
          Eio.Promise.resolve sender.resolver `Sent;
          admit_waiting_senders t))

let pump (t : ('a, 'err) t) =
  drain_buffer_to_receivers t;
  admit_waiting_senders t

let with_lock (t : ('a, 'err) t) f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let with_lock_during_cancel t f =
  Eio.Cancel.protect (fun () -> with_lock t f)

let enqueue_sender (t : ('a, 'err) t) value =
  let promise, resolver = Eio.Promise.create () in
  let sender = { value; resolver; active = true } in
  Stdlib.Queue.push sender t.senders;
  t.waiting_senders <- t.waiting_senders + 1;
  (promise, sender)

let enqueue_receiver (t : ('a, 'err) t) =
  let promise, resolver = Eio.Promise.create () in
  let receiver = { resolver; state = Waiting } in
  Stdlib.Queue.push receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let cancel_sender (t : ('a, 'err) t) (sender : ('a, 'err) sender) =
  if sender.active then (
    sender.active <- false;
    t.waiting_senders <- t.waiting_senders - 1;
    t.cancelled_senders <- t.cancelled_senders + 1;
    pump t)

let cancel_receiver (t : ('a, 'err) t) (receiver : ('a, 'err) receiver) =
  match receiver.state with
  | Waiting ->
      receiver.state <- Cancelled;
      t.waiting_receivers <- t.waiting_receivers - 1;
      pump t
  | Delivered value ->
      receiver.state <- Cancelled;
      release_receiver_delivery t;
      return_unclaimed_value t value;
      pump t
  | Claimed | Cancelled -> ()

let close_locked (t : ('a, 'err) t) reason =
  if Option.is_none t.closed then (
    t.closed <- Some reason;
    let rec close_senders () =
      match take_sender t with
      | None -> ()
      | Some sender ->
          Eio.Promise.resolve sender.resolver (close_result reason);
          close_senders ()
    in
    let rec close_receivers () =
      match take_receiver t with
      | None -> ()
      | Some receiver ->
          receiver.state <- Cancelled;
          Eio.Promise.resolve receiver.resolver (close_result reason);
          close_receivers ()
    in
    close_senders ();
    close_receivers ())

let send_sync (t : ('a, 'err) t) value =
  match
    with_lock t @@ fun () ->
    match t.closed with
    | Some reason -> `Ready (close_result reason)
    | None when capacity_used t < t.capacity && t.depth = 0 -> (
        match take_receiver t with
        | Some receiver ->
            t.sent <- t.sent + 1;
            deliver_receiver t receiver value;
            `Ready `Sent
        | None ->
            push_counted t value;
            `Ready `Sent)
    | None when capacity_used t < t.capacity ->
        push_counted t value;
        `Ready `Sent
    | None ->
        let promise, sender = enqueue_sender t value in
        `Wait (promise, sender)
  with
  | `Ready result -> result
  | `Wait (promise, sender) -> (
      try Eio.Promise.await promise
      with Eio.Cancel.Cancelled _ as exn ->
        with_lock_during_cancel t (fun () -> cancel_sender t sender);
        raise exn)

let recv_sync (t : ('a, 'err) t) =
  match
    with_lock t @@ fun () ->
    if t.depth > 0 then (
      let value = pop t in
      pump t;
      `Ready (`Item value))
    else
      match take_sender t with
      | Some sender ->
          t.sent <- t.sent + 1;
          t.received <- t.received + 1;
          Eio.Promise.resolve sender.resolver `Sent;
          `Ready (`Item sender.value)
      | None -> (
          match t.closed with
          | Some reason -> `Ready (close_result reason)
          | None ->
              let promise, receiver = enqueue_receiver t in
              `Wait (promise, receiver))
  with
  | `Ready result -> result
  | `Wait (promise, receiver) -> (
      try
        match Eio.Promise.await promise with
        | `Item _ as result ->
            with_lock t (fun () ->
                claim_receiver t receiver;
                pump t);
            result
        | (`Empty | `Closed | `Closed_with_error _) as result -> result
      with Eio.Cancel.Cancelled _ as exn ->
        with_lock_during_cancel t (fun () -> cancel_receiver t receiver);
        raise exn)

let send t value =
  Effect.sync (fun () -> send_sync t value)
  |> Effect.bind (function
       | `Sent -> Effect.unit
       | `Full -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let recv t =
  Effect.sync (fun () -> recv_sync t)
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let try_send (t : ('a, 'err) t) value =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  match t.closed with
  | Some reason -> close_result reason
  | None when capacity_used t < t.capacity && t.depth = 0 -> (
      match take_receiver t with
      | Some receiver ->
          t.sent <- t.sent + 1;
          deliver_receiver t receiver value;
          `Sent
      | None ->
          push_counted t value;
          `Sent)
  | None when capacity_used t = t.capacity -> `Full
  | None ->
      push_counted t value;
      `Sent

let try_recv (t : ('a, 'err) t) =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  if t.depth > 0 then (
    let value = pop t in
    pump t;
    `Item value)
  else
    match take_sender t with
    | Some sender ->
        t.sent <- t.sent + 1;
        t.received <- t.received + 1;
        Eio.Promise.resolve sender.resolver `Sent;
        `Item sender.value
    | None -> (
        match t.closed with
        | Some reason -> close_result reason
        | None -> `Empty)

let close (t : ('a, 'err) t) = with_lock t @@ fun () -> close_locked t Clean

let close_with_error (t : ('a, 'err) t) error =
  with_lock t @@ fun () -> close_locked t (Error error)

let stats (t : ('a, 'err) t) =
  Eio.Mutex.use_ro t.mutex @@ fun () ->
  {
    depth = t.depth;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
  }
