type overflow =
  | Unbounded
  | Drop_new of { capacity : int }
  | Backpressure of { capacity : int }

type publish_result = {
  subscriber_count : int;
  dropped : int;
}

type stats = {
  depth : int;
  subscribers : int;
  published : int;
  received : int;
  dropped : int;
  closed : bool;
  waiting_publishers : int;
  waiting_receivers : int;
  cancelled_publishers : int;
  cancelled_receivers : int;
}

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type 'err close_reason =
  | Clean
  | Failed of 'err

type 'err publish_out =
  [
    `Published of publish_result
  | `Closed
  | `Closed_with_error of 'err
  | `Full
  ]

type ('a, 'err) entry = {
  seq : int;
  value : 'a;
  mutable remaining : int;
}

type ('a, 'err) publisher = {
  value : 'a;
  mutable active : bool;
  resume : 'err publish_out -> unit;
}

type ('a, 'err) receiver = {
  mutable active : bool;
  resume : ('a, 'err) recv_result -> unit;
}

type ('a, 'err) t = {
  overflow : overflow;
  entries : ('a, 'err) entry Stdlib.Queue.t;
  mutable publishers : ('a, 'err) publisher Stdlib.Queue.t;
  mutable subscribers : ('a, 'err) subscription list;
  mutable next_subscriber_id : int;
  mutable next_seq : int;
  mutable closed : 'err close_reason option;
  mutable depth : int;
  mutable published : int;
  mutable received : int;
  mutable dropped : int;
  mutable waiting_publishers : int;
  mutable waiting_receivers : int;
  mutable cancelled_publishers : int;
  mutable cancelled_receivers : int;
}

and ('a, 'err) subscription = {
  hub : ('a, 'err) t;
  id : int;
  mutable cursor : int;
  mutable active : bool;
  receivers : ('a, 'err) receiver Stdlib.Queue.t;
}

let create ~overflow () =
  (match overflow with
  | Unbounded -> ()
  | Drop_new { capacity } | Backpressure { capacity } ->
      if capacity <= 0 then
        invalid_arg "Eta_js.Pubsub.create: bounded capacity must be > 0");
  {
    overflow;
    entries = Stdlib.Queue.create ();
    publishers = Stdlib.Queue.create ();
    subscribers = [];
    next_subscriber_id = 0;
    next_seq = 0;
    closed = None;
    depth = 0;
    published = 0;
    received = 0;
    dropped = 0;
    waiting_publishers = 0;
    waiting_receivers = 0;
    cancelled_publishers = 0;
    cancelled_receivers = 0;
  }

let close_result = function
  | Clean -> `Closed
  | Failed error -> `Closed_with_error error

let active_subscriber_count t =
  List.fold_left
    (fun count sub -> if sub.active then count + 1 else count)
    0 t.subscribers

let capacity_available t =
  match t.overflow with
  | Unbounded -> true
  | Drop_new { capacity } | Backpressure { capacity } -> t.depth < capacity

let decrement_entry entry =
  if entry.remaining <= 0 then
    invalid_arg "Eta_js.Pubsub: negative remaining subscriber count";
  entry.remaining <- entry.remaining - 1

let rec drop_drained_head_entries t =
  if not (Stdlib.Queue.is_empty t.entries) then
    let entry = Stdlib.Queue.peek t.entries in
    if entry.remaining = 0 then begin
      ignore (Stdlib.Queue.take t.entries);
      t.depth <- t.depth - 1;
      drop_drained_head_entries t
    end

let find_entry t seq =
  let found = ref None in
  Stdlib.Queue.iter
    (fun entry -> if entry.seq = seq then found := Some entry)
    t.entries;
  !found

let rec take_active_publisher
    (queue : ('a, 'err) publisher Stdlib.Queue.t) :
    ('a, 'err) publisher option =
  if Stdlib.Queue.is_empty queue then None
  else
    let waiter = Stdlib.Queue.take queue in
    if waiter.active then Some waiter else take_active_publisher queue

let wake_receiver (t : ('a, 'err) t) (receiver : ('a, 'err) receiver) result =
  if receiver.active then begin
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    receiver.resume result
  end

let admit_value t value =
  let subscriber_count = active_subscriber_count t in
  if subscriber_count = 0 then { subscriber_count = 0; dropped = 0 }
  else begin
    let entry = { seq = t.next_seq; value; remaining = subscriber_count } in
    t.next_seq <- t.next_seq + 1;
    Stdlib.Queue.add entry t.entries;
    t.depth <- t.depth + 1;
    t.published <- t.published + 1;
    { subscriber_count; dropped = 0 }
  end

let rec admit_waiting_publishers t =
  match t.overflow with
  | Unbounded | Drop_new _ -> ()
  | Backpressure _ ->
      let rec loop () =
        if Option.is_none t.closed
           && (capacity_available t || active_subscriber_count t = 0)
        then
          match take_active_publisher t.publishers with
          | None -> ()
          | Some publisher ->
              publisher.active <- false;
              t.waiting_publishers <- t.waiting_publishers - 1;
              let result = admit_value t publisher.value in
              wake_all_receivers t;
              publisher.resume (`Published result);
              loop ()
      in
      loop ()

and cleanup t =
  drop_drained_head_entries t;
  admit_waiting_publishers t

and consume_available sub =
  let t = sub.hub in
  if not sub.active then `Closed
  else
    match find_entry t sub.cursor with
    | Some entry ->
        let value = entry.value in
        sub.cursor <- sub.cursor + 1;
        decrement_entry entry;
        t.received <- t.received + 1;
        cleanup t;
        `Item value
    | None ->
        if sub.cursor < t.next_seq then
          invalid_arg "Eta_js.Pubsub: subscriber cursor points behind buffer";
        (match t.closed with
        | None -> `Empty
        | Some reason -> close_result reason)

and wake_subscription_receivers t sub =
  let continue = ref true in
  while !continue && not (Stdlib.Queue.is_empty sub.receivers) do
    let receiver = Stdlib.Queue.take sub.receivers in
    if receiver.active then
      match consume_available sub with
      | `Empty ->
          Stdlib.Queue.add receiver sub.receivers;
          continue := false
      | result -> wake_receiver t receiver result
  done

and wake_all_receivers t =
  List.iter
    (fun sub -> if sub.active then wake_subscription_receivers t sub)
    t.subscribers

let enqueue_publisher t value resume =
  let publisher = { value; active = true; resume } in
  Stdlib.Queue.add publisher t.publishers;
  t.waiting_publishers <- t.waiting_publishers + 1;
  publisher

let cancel_publisher (t : ('a, 'err) t) (publisher : ('a, 'err) publisher) =
  if publisher.active then begin
    publisher.active <- false;
    t.waiting_publishers <- t.waiting_publishers - 1;
    t.cancelled_publishers <- t.cancelled_publishers + 1;
    admit_waiting_publishers t
  end

let publish_ready t value =
  match t.closed with
  | Some reason -> close_result reason
  | None ->
      let subscriber_count = active_subscriber_count t in
      match t.overflow with
      | Drop_new _ when subscriber_count > 0 && not (capacity_available t) ->
          t.dropped <- t.dropped + subscriber_count;
          `Published { subscriber_count; dropped = subscriber_count }
      | Backpressure _ when subscriber_count > 0 && not (capacity_available t) ->
          `Full
      | Unbounded | Drop_new _ | Backpressure _ ->
          let result = admit_value t value in
          wake_all_receivers t;
          `Published result

let publish t value =
  match publish_ready t value with
  | `Published result -> Effect.pure result
  | `Closed -> Effect.fail `Closed
  | `Closed_with_error error -> Effect.fail (`Closed_with_error error)
  | `Full ->
      Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
          let publisher =
            enqueue_publisher t value (function
              | `Published result -> resume (Exit.ok result)
              | `Closed -> resume (Exit.error (Cause.fail `Closed))
              | `Closed_with_error error ->
                  resume (Exit.error (Cause.fail (`Closed_with_error error)))
              | `Full -> assert false)
          in
          on_cancel (fun () -> cancel_publisher t publisher))

let add_subscription t =
  match t.closed with
  | Some reason -> Error (close_result reason)
  | None ->
      let sub =
        {
          hub = t;
          id = t.next_subscriber_id;
          cursor = t.next_seq;
          active = true;
          receivers = Stdlib.Queue.create ();
        }
      in
      t.next_subscriber_id <- t.next_subscriber_id + 1;
      t.subscribers <- sub :: t.subscribers;
      Ok sub

let release_subscription sub =
  let t = sub.hub in
  if sub.active then begin
    sub.active <- false;
    t.subscribers <- List.filter (fun other -> other.id <> sub.id) t.subscribers;
    Stdlib.Queue.iter
      (fun entry -> if entry.seq >= sub.cursor then decrement_entry entry)
      t.entries;
    while not (Stdlib.Queue.is_empty sub.receivers) do
      let receiver = Stdlib.Queue.take sub.receivers in
      wake_receiver t receiver `Closed
    done;
    cleanup t
  end

let subscribe t f =
  Effect.acquire_use_release
    ~acquire:
      (Effect.bind
         (function
           | Ok sub -> Effect.pure sub
           | Error `Closed -> Effect.fail `Closed
           | Error (`Closed_with_error error) ->
               Effect.fail (`Closed_with_error error)
           | Error `Empty | Error (`Item _) -> assert false)
         (Effect.sync (fun () -> add_subscription t)))
    ~release:(fun sub -> Effect.sync (fun () -> release_subscription sub))
    f

let try_recv sub = Effect.sync (fun () -> consume_available sub)

let recv_wait sub =
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
      Stdlib.Queue.add receiver sub.receivers;
      sub.hub.waiting_receivers <- sub.hub.waiting_receivers + 1;
      on_cancel (fun () ->
          if receiver.active then begin
            receiver.active <- false;
            sub.hub.waiting_receivers <- sub.hub.waiting_receivers - 1;
            sub.hub.cancelled_receivers <- sub.hub.cancelled_receivers + 1
          end))

let recv sub =
  Effect.bind
    (function
      | `Item value -> Effect.pure value
      | `Empty -> recv_wait sub
      | `Closed -> Effect.fail `Closed
      | `Closed_with_error error -> Effect.fail (`Closed_with_error error))
    (try_recv sub)

let close_with reason t =
  match t.closed with
  | Some _ -> ()
  | None ->
      t.closed <- Some reason;
      while not (Stdlib.Queue.is_empty t.publishers) do
        match take_active_publisher t.publishers with
        | None -> ()
        | Some publisher ->
            publisher.active <- false;
            t.waiting_publishers <- t.waiting_publishers - 1;
            publisher.resume (close_result reason)
      done;
      wake_all_receivers t

let close t = close_with Clean t
let close_with_error t error = close_with (Failed error) t

let stats t =
  {
    depth = t.depth;
    subscribers = active_subscriber_count t;
    published = t.published;
    received = t.received;
    dropped = t.dropped;
    closed = Option.is_some t.closed;
    waiting_publishers = t.waiting_publishers;
    waiting_receivers = t.waiting_receivers;
    cancelled_publishers = t.cancelled_publishers;
    cancelled_receivers = t.cancelled_receivers;
  }
