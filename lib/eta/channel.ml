type 'err send_result =
  [ `Sent | `Full | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type 'err close_reason = Clean | Error of 'err

type ('a, 'err) sender = {
  value : 'a;
  contract : Runtime_contract.t;
  resolver : 'err send_result Runtime_contract.resolver;
  mutable active : bool;
}

type ('a, 'err) receiver = {
  contract : Runtime_contract.t;
  resolver : ('a, 'err) recv_result Runtime_contract.resolver;
  mutable state : 'a receiver_state;
}

and 'a receiver_state =
  | Waiting
  | Delivered of 'a
  | Claimed
  | Cancelled

type ('a, 'err) t = {
  mutex : Sync_lock.t;
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

type ('a, 'err) wakeup =
  | Wake_sender of ('a, 'err) sender * 'err send_result
  | Wake_receiver of ('a, 'err) receiver * ('a, 'err) recv_result

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
    mutex = Sync_lock.create ();
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

let add_wakeup wakeups wakeup = wakeups := wakeup :: !wakeups

let resolve_sender (sender : ('a, 'err) sender) (result : 'err send_result) =
  sender.contract.Runtime_contract.protect (fun () ->
      sender.contract.Runtime_contract.resolve_promise sender.resolver result)

let resolve_receiver
    (receiver : ('a, 'err) receiver)
    (result : ('a, 'err) recv_result) =
  receiver.contract.Runtime_contract.protect (fun () ->
      receiver.contract.Runtime_contract.resolve_promise receiver.resolver result)

let resolve_wakeup = function
  | Wake_sender (sender, result) -> resolve_sender sender result
  | Wake_receiver (receiver, result) -> resolve_receiver receiver result

let resolve_wakeups wakeups =
  List.iter resolve_wakeup (List.rev wakeups)

let capacity_used (t : ('a, 'err) t) =
  t.depth + t.pending_receivers

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

let compact_cancelled_senders_locked (t : ('a, 'err) t) =
  if t.cancelled_senders > 0 then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun (sender : ('a, 'err) sender) ->
        if sender.active then Stdlib.Queue.push sender live)
      t.senders;
    Stdlib.Queue.clear t.senders;
    Stdlib.Queue.iter (fun sender -> Stdlib.Queue.push sender t.senders) live)

let compact_cancelled_receivers_locked (t : ('a, 'err) t) =
  let live = Stdlib.Queue.create () in
  Stdlib.Queue.iter
    (fun (receiver : ('a, 'err) receiver) ->
      match receiver.state with
      | Waiting -> Stdlib.Queue.push receiver live
      | Delivered _ | Claimed | Cancelled -> ())
    t.receivers;
  Stdlib.Queue.clear t.receivers;
  Stdlib.Queue.iter (fun receiver -> Stdlib.Queue.push receiver t.receivers) live

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

let deliver_receiver wakeups (t : ('a, 'err) t)
    (receiver : ('a, 'err) receiver) value =
  reserve_receiver_delivery t;
  receiver.state <- Delivered value;
  add_wakeup wakeups (Wake_receiver (receiver, `Item value))

let claim_receiver (t : ('a, 'err) t) receiver =
  match receiver.state with
  | Delivered _ ->
      receiver.state <- Claimed;
      release_receiver_delivery t;
      t.received <- t.received + 1
  | Waiting | Claimed | Cancelled -> ()

let return_unclaimed_value wakeups (t : ('a, 'err) t) value =
  match take_receiver t with
  | Some receiver -> deliver_receiver wakeups t receiver value
  | None -> push_front t value

let rec drain_buffer_to_receivers wakeups (t : ('a, 'err) t) =
  if t.depth > 0 then
    match take_receiver t with
    | None -> ()
    | Some receiver ->
        let value = pop_raw t in
        deliver_receiver wakeups t receiver value;
        drain_buffer_to_receivers wakeups t

let rec admit_waiting_senders wakeups (t : ('a, 'err) t) =
  if Option.is_none t.closed && capacity_used t < t.capacity then
    match take_sender t with
    | None -> ()
    | Some sender -> (
        if t.depth = 0 then
          match take_receiver t with
          | Some receiver ->
              t.sent <- t.sent + 1;
              deliver_receiver wakeups t receiver sender.value;
              add_wakeup wakeups (Wake_sender (sender, `Sent));
              admit_waiting_senders wakeups t
          | None ->
              push_counted t sender.value;
              add_wakeup wakeups (Wake_sender (sender, `Sent));
              admit_waiting_senders wakeups t
        else (
          push_counted t sender.value;
          add_wakeup wakeups (Wake_sender (sender, `Sent));
          admit_waiting_senders wakeups t))

let pump wakeups (t : ('a, 'err) t) =
  drain_buffer_to_receivers wakeups t;
  admit_waiting_senders wakeups t

let with_lock (t : ('a, 'err) t) f =
  Sync_lock.use t.mutex f

let with_lock_during_cancel contract t f =
  contract.Runtime_contract.protect (fun () -> with_lock t f)

let enqueue_sender contract (t : ('a, 'err) t) value =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let sender = { value; contract; resolver; active = true } in
  Stdlib.Queue.push sender t.senders;
  t.waiting_senders <- t.waiting_senders + 1;
  (promise, sender)

let enqueue_receiver contract (t : ('a, 'err) t) =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let receiver = { contract; resolver; state = Waiting } in
  Stdlib.Queue.push receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let cancel_sender wakeups (t : ('a, 'err) t) (sender : ('a, 'err) sender) =
  if sender.active then (
    sender.active <- false;
    t.waiting_senders <- t.waiting_senders - 1;
    t.cancelled_senders <- t.cancelled_senders + 1;
    compact_cancelled_senders_locked t;
    pump wakeups t)

let cancel_receiver wakeups (t : ('a, 'err) t)
    (receiver : ('a, 'err) receiver) =
  match receiver.state with
  | Waiting ->
      receiver.state <- Cancelled;
      t.waiting_receivers <- t.waiting_receivers - 1;
      compact_cancelled_receivers_locked t;
      pump wakeups t
  | Delivered value ->
      receiver.state <- Cancelled;
      release_receiver_delivery t;
      return_unclaimed_value wakeups t value;
      pump wakeups t
  | Claimed | Cancelled -> ()

let close_locked wakeups (t : ('a, 'err) t) reason =
  if Option.is_none t.closed then (
    t.closed <- Some reason;
    let rec close_senders () =
      match take_sender t with
      | None -> ()
      | Some sender ->
          add_wakeup wakeups (Wake_sender (sender, close_result reason));
          close_senders ()
    in
    let rec close_receivers () =
      match take_receiver t with
      | None -> ()
      | Some receiver ->
          receiver.state <- Cancelled;
          add_wakeup wakeups (Wake_receiver (receiver, close_result reason));
          close_receivers ()
    in
    close_senders ();
    close_receivers ())

let[@inline always] send_locked wakeups (t : ('a, 'err) t) value =
  match t.closed with
  | Some reason -> close_result reason
  | None when capacity_used t < t.capacity && t.depth = 0 -> (
      match take_receiver t with
      | Some receiver ->
          t.sent <- t.sent + 1;
          deliver_receiver wakeups t receiver value;
          `Sent
      | None ->
          push_counted t value;
          `Sent)
  | None when capacity_used t < t.capacity ->
      push_counted t value;
      `Sent
  | None -> `Full

let[@inline always] recv_locked wakeups (t : ('a, 'err) t) =
  if t.depth > 0 then (
    let value = pop t in
    pump wakeups t;
    `Item value)
  else
    match take_sender t with
    | Some sender ->
        t.sent <- t.sent + 1;
        t.received <- t.received + 1;
        add_wakeup wakeups (Wake_sender (sender, `Sent));
        `Item sender.value
    | None -> (
        match t.closed with
        | Some reason -> close_result reason
        | None -> `Empty)

let send_sync contract (t : ('a, 'err) t) value =
  let wakeups = ref [] in
  match
    with_lock t @@ fun () ->
    match send_locked wakeups t value with
    | `Full ->
        let promise, sender = enqueue_sender contract t value in
        `Wait (promise, sender)
    | result -> `Ready result
  with
  | `Ready result ->
      resolve_wakeups !wakeups;
      result
  | `Wait (promise, sender) -> (
      try contract.Runtime_contract.await_promise promise
      with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
        let cancel_wakeups = ref [] in
        with_lock_during_cancel contract t (fun () ->
            cancel_sender cancel_wakeups t sender);
        resolve_wakeups !cancel_wakeups;
        raise exn)

let recv_sync contract (t : ('a, 'err) t) =
  let wakeups = ref [] in
  match
    with_lock t @@ fun () ->
    match recv_locked wakeups t with
    | `Empty ->
        let promise, receiver = enqueue_receiver contract t in
        `Wait (promise, receiver)
    | result -> `Ready result
  with
  | `Ready result ->
      resolve_wakeups !wakeups;
      result
  | `Wait (promise, receiver) -> (
      try
        match contract.Runtime_contract.await_promise promise with
        | `Item _ as result ->
            let claim_wakeups = ref [] in
            with_lock t (fun () ->
                claim_receiver t receiver;
                pump claim_wakeups t);
            resolve_wakeups !claim_wakeups;
            result
        | (`Empty | `Closed | `Closed_with_error _) as result -> result
      with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
        let cancel_wakeups = ref [] in
        with_lock_during_cancel contract t (fun () ->
            cancel_receiver cancel_wakeups t receiver);
        resolve_wakeups !cancel_wakeups;
        raise exn)

let send t value =
  Effect_erasure.public_sync ~leaf_name:"Channel.send"
    ~footprint:(Effect_core.footprint ~has_concurrency:true ()) t (fun contract t ->
      send_sync contract t value)
  |> Effect.bind (function
       | `Sent -> Effect.unit
       | `Full -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let recv t =
  Effect_erasure.public_sync ~leaf_name:"Channel.recv"
    ~footprint:(Effect_core.footprint ~has_concurrency:true ()) t recv_sync
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let try_send (t : ('a, 'err) t) value =
  Effect.sync @@ fun () ->
  let wakeups = ref [] in
  let result = with_lock t @@ fun () -> send_locked wakeups t value in
  resolve_wakeups !wakeups;
  result

let try_recv (t : ('a, 'err) t) =
  Effect.sync @@ fun () ->
  let wakeups = ref [] in
  let result = with_lock t @@ fun () -> recv_locked wakeups t in
  resolve_wakeups !wakeups;
  result

let close_with reason t =
  let wakeups = ref [] in
  with_lock t (fun () -> close_locked wakeups t reason);
  resolve_wakeups !wakeups

let close t = close_with Clean t

let close_with_error t error = close_with (Error error) t

let close_effect t = Effect.sync (fun () -> close t)

let close_with_error_effect t error =
  Effect.sync (fun () -> close_with_error t error)

let stats (t : ('a, 'err) t) =
  Sync_lock.use t.mutex @@ fun () ->
  {
    depth = t.depth;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
  }
