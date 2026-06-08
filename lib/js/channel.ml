type 'err close_reason =
  | Clean
  | Error of 'err

type 'err send_result =
  [ `Sent | `Full | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) sender = {
  value : 'a;
  mutable active : bool;
  resume : 'err send_result -> unit;
}

type ('a, 'err) receiver = {
  mutable active : bool;
  resume : ('a, 'err) recv_result -> unit;
}

type ('a, 'err) t = {
  capacity : int;
  values : 'a Stdlib.Queue.t;
  mutable senders : ('a, 'err) sender Stdlib.Queue.t;
  receivers : ('a, 'err) receiver Stdlib.Queue.t;
  mutable closed : 'err close_reason option;
  mutable sent : int;
  mutable received : int;
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
  if capacity <= 0 then invalid_arg "Eta_js.Channel.create: capacity must be > 0";
  {
    capacity;
    values = Stdlib.Queue.create ();
    senders = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    closed = None;
    sent = 0;
    received = 0;
    waiting_senders = 0;
    waiting_receivers = 0;
    cancelled_senders = 0;
  }

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let rec take_active queue =
  if Stdlib.Queue.is_empty queue then None
  else
    let waiter = Stdlib.Queue.take queue in
    if waiter.active then Some waiter else take_active queue

let take_value (t : ('a, 'err) t) =
  let value = Stdlib.Queue.take t.values in
  t.received <- t.received + 1;
  `Item value

let rec wake_one_receiver (t : ('a, 'err) t) =
  match take_active t.receivers with
  | None -> ()
  | Some receiver ->
      if not (Stdlib.Queue.is_empty t.values) then begin
        receiver.active <- false;
        t.waiting_receivers <- t.waiting_receivers - 1;
        receiver.resume (take_value t);
        admit_senders t
      end
      else
        match t.closed with
        | None -> ()
        | Some reason ->
            receiver.active <- false;
            t.waiting_receivers <- t.waiting_receivers - 1;
            receiver.resume (close_result reason)

and admit_senders (t : ('a, 'err) t) =
  let remaining = Stdlib.Queue.create () in
  let blocked = ref false in
  while not (Stdlib.Queue.is_empty t.senders) do
    let sender = Stdlib.Queue.take t.senders in
    if sender.active then
      match t.closed with
      | Some reason ->
          sender.active <- false;
          t.waiting_senders <- t.waiting_senders - 1;
          sender.resume (close_result reason)
      | None ->
          if (not !blocked) && Stdlib.Queue.length t.values < t.capacity then begin
            sender.active <- false;
            t.waiting_senders <- t.waiting_senders - 1;
            Stdlib.Queue.add sender.value t.values;
            t.sent <- t.sent + 1;
            sender.resume `Sent;
            wake_one_receiver t
          end
          else begin
            blocked := true;
            Stdlib.Queue.add sender remaining
          end
  done;
  t.senders <- remaining

let recv_result (t : ('a, 'err) t) =
  if not (Stdlib.Queue.is_empty t.values) then begin
    let result = take_value t in
    admit_senders t;
    result
  end
  else
    match t.closed with
    | None -> `Empty
    | Some reason -> close_result reason

let try_send_sync (t : ('a, 'err) t) value =
  match t.closed with
  | Some reason -> close_result reason
  | None ->
      if Stdlib.Queue.length t.values < t.capacity then begin
        Stdlib.Queue.add value t.values;
        t.sent <- t.sent + 1;
        wake_one_receiver t;
        `Sent
      end
      else `Full

let try_send t value = Effect.sync (fun () -> try_send_sync t value)

let send_wait (t : ('a, 'err) t) value =
  Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
      let sender =
        {
          value;
          active = true;
          resume =
            (function
            | `Sent -> resume (Exit.ok ())
            | `Closed -> resume (Exit.error (Cause.fail `Closed))
            | `Closed_with_error error ->
                resume (Exit.error (Cause.fail (`Closed_with_error error)))
            | `Full -> assert false);
        }
      in
      Stdlib.Queue.add sender t.senders;
      t.waiting_senders <- t.waiting_senders + 1;
      on_cancel (fun () ->
          if sender.active then begin
            sender.active <- false;
            t.waiting_senders <- t.waiting_senders - 1;
            t.cancelled_senders <- t.cancelled_senders + 1
          end))

let send t value =
  Effect.bind
    (function
      | `Sent -> Effect.unit
      | `Full -> send_wait t value
      | `Closed -> Effect.fail `Closed
      | `Closed_with_error error -> Effect.fail (`Closed_with_error error))
    (try_send t value)

let try_recv t = Effect.sync (fun () -> recv_result t)

let recv_wait (t : ('a, 'err) t) =
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
      on_cancel (fun () ->
          if receiver.active then begin
            receiver.active <- false;
            t.waiting_receivers <- t.waiting_receivers - 1
          end))

let recv t =
  Effect.bind
    (function
      | `Item value -> Effect.pure value
      | `Empty -> recv_wait t
      | `Closed -> Effect.fail `Closed
      | `Closed_with_error error -> Effect.fail (`Closed_with_error error))
    (try_recv t)

let wake_all_receivers (t : ('a, 'err) t) =
  while t.waiting_receivers > 0 do
    wake_one_receiver t
  done

let close_with reason (t : ('a, 'err) t) =
  match t.closed with
  | Some _ -> ()
  | None ->
      t.closed <- Some reason;
      admit_senders t;
      wake_all_receivers t

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let stats (t : ('a, 'err) t) =
  {
    depth = Stdlib.Queue.length t.values;
    sent = t.sent;
    received = t.received;
    closed = Option.is_some t.closed;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
  }
