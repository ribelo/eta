type send_result = [ `Sent | `Full | `Closed ]
type 'a recv_result = [ `Item of 'a | `Empty | `Closed ]

type 'a sender = {
  value : 'a;
  resolver : send_result Eio.Promise.u;
  mutable active : bool;
}

type 'a receiver = {
  resolver : 'a recv_result Eio.Promise.u;
  mutable active : bool;
}

type 'a t = {
  mutex : Eio.Mutex.t;
  buffer : 'a option array;
  senders : 'a sender Queue.t;
  receivers : 'a receiver Queue.t;
  capacity : int;
  mutable head : int;
  mutable tail : int;
  mutable depth : int;
  mutable sent : int;
  mutable received : int;
  mutable closed : bool;
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
    senders = Queue.create ();
    receivers = Queue.create ();
    capacity;
    head = 0;
    tail = 0;
    depth = 0;
    sent = 0;
    received = 0;
    closed = false;
    waiting_senders = 0;
    waiting_receivers = 0;
    cancelled_senders = 0;
  }

let push t value =
  t.buffer.(t.tail) <- Some value;
  t.tail <- (t.tail + 1) mod t.capacity;
  t.depth <- t.depth + 1;
  t.sent <- t.sent + 1

let pop t =
  match t.buffer.(t.head) with
  | None -> invalid_arg "Eta.Channel.pop: empty slot"
  | Some value ->
      t.buffer.(t.head) <- None;
      t.head <- (t.head + 1) mod t.capacity;
      t.depth <- t.depth - 1;
      t.received <- t.received + 1;
      value

let rec take_active_sender (q : 'a sender Queue.t) : 'a sender option =
  if Queue.is_empty q then None
  else
    let waiter = Queue.take q in
    if waiter.active then Some waiter else take_active_sender q

let rec take_active_receiver (q : 'a receiver Queue.t) : 'a receiver option =
  if Queue.is_empty q then None
  else
    let waiter = Queue.take q in
    if waiter.active then Some waiter else take_active_receiver q

let take_sender (t : 'a t) =
  match take_active_sender t.senders with
  | None -> None
  | Some sender ->
      sender.active <- false;
      t.waiting_senders <- t.waiting_senders - 1;
      Some sender

let take_receiver (t : 'a t) =
  match take_active_receiver t.receivers with
  | None -> None
  | Some receiver ->
      receiver.active <- false;
      t.waiting_receivers <- t.waiting_receivers - 1;
      Some receiver

let rec drain_buffer_to_receivers (t : 'a t) =
  if t.depth > 0 then
    match take_receiver t with
    | None -> ()
    | Some receiver ->
        let value = pop t in
        Eio.Promise.resolve receiver.resolver (`Item value);
        drain_buffer_to_receivers t

let rec admit_waiting_senders (t : 'a t) =
  if (not t.closed) && t.depth < t.capacity then
    match take_sender t with
    | None -> ()
    | Some sender -> (
        if t.depth = 0 then
          match take_receiver t with
          | Some receiver ->
              t.sent <- t.sent + 1;
              t.received <- t.received + 1;
              Eio.Promise.resolve receiver.resolver (`Item sender.value);
              Eio.Promise.resolve sender.resolver `Sent;
              admit_waiting_senders t
          | None ->
              push t sender.value;
              Eio.Promise.resolve sender.resolver `Sent;
              admit_waiting_senders t
        else (
          push t sender.value;
          Eio.Promise.resolve sender.resolver `Sent;
          admit_waiting_senders t))

let pump (t : 'a t) =
  drain_buffer_to_receivers t;
  admit_waiting_senders t

let with_lock (t : 'a t) f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let enqueue_sender (t : 'a t) value =
  let promise, resolver = Eio.Promise.create () in
  let sender = { value; resolver; active = true } in
  Queue.push sender t.senders;
  t.waiting_senders <- t.waiting_senders + 1;
  (promise, sender)

let enqueue_receiver (t : 'a t) =
  let promise, resolver = Eio.Promise.create () in
  let receiver = { resolver; active = true } in
  Queue.push receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let cancel_sender (t : 'a t) (sender : 'a sender) =
  if sender.active then (
    sender.active <- false;
    t.waiting_senders <- t.waiting_senders - 1;
    t.cancelled_senders <- t.cancelled_senders + 1;
    pump t)

let cancel_receiver (t : 'a t) (receiver : 'a receiver) =
  if receiver.active then (
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    pump t)

let close_locked (t : 'a t) =
  if not t.closed then (
    t.closed <- true;
    let rec close_senders () =
      match take_sender t with
      | None -> ()
      | Some sender ->
          Eio.Promise.resolve sender.resolver `Closed;
          close_senders ()
    in
    let rec close_receivers () =
      match take_receiver t with
      | None -> ()
      | Some receiver ->
          Eio.Promise.resolve receiver.resolver `Closed;
          close_receivers ()
    in
    close_senders ();
    close_receivers ())

let send_sync (t : 'a t) value =
  match
    with_lock t @@ fun () ->
    if t.closed then `Ready `Closed
    else if t.depth = 0 then
      match take_receiver t with
      | Some receiver ->
          t.sent <- t.sent + 1;
          t.received <- t.received + 1;
          Eio.Promise.resolve receiver.resolver (`Item value);
          `Ready `Sent
      | None ->
          push t value;
          `Ready `Sent
    else if t.depth < t.capacity then (
      push t value;
      `Ready `Sent)
    else
      let promise, sender = enqueue_sender t value in
      `Wait (promise, sender)
  with
  | `Ready result -> result
  | `Wait (promise, sender) -> (
      try Eio.Promise.await promise
      with Eio.Cancel.Cancelled _ as exn ->
        with_lock t (fun () -> cancel_sender t sender);
        raise exn)

let recv_sync (t : 'a t) =
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
      | None ->
          if t.closed then `Ready `Closed
          else
            let promise, receiver = enqueue_receiver t in
            `Wait (promise, receiver)
  with
  | `Ready result -> result
  | `Wait (promise, receiver) -> (
      try Eio.Promise.await promise
      with Eio.Cancel.Cancelled _ as exn ->
        with_lock t (fun () -> cancel_receiver t receiver);
        raise exn)

let send t value =
  Effect.sync (fun () -> send_sync t value)
  |> Effect.bind (function
       | `Sent -> Effect.unit
       | `Full -> assert false
       | `Closed -> Effect.fail `Closed)

let recv t =
  Effect.sync (fun () -> recv_sync t)
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed)

let try_send t value =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  if t.closed then `Closed
  else if t.depth = 0 then
    match take_receiver t with
    | Some receiver ->
        t.sent <- t.sent + 1;
        t.received <- t.received + 1;
        Eio.Promise.resolve receiver.resolver (`Item value);
        `Sent
    | None ->
        push t value;
        `Sent
  else if t.depth = t.capacity then `Full
  else (
    push t value;
    `Sent)

let try_recv t =
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
    | None -> if t.closed then `Closed else `Empty

let close t = with_lock t @@ fun () -> close_locked t

let stats (t : 'a t) =
  Eio.Mutex.use_ro t.mutex @@ fun () ->
  {
    depth = t.depth;
    sent = t.sent;
    received = t.received;
    closed = t.closed;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
  }
