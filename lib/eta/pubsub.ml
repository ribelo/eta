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
  [ `Published of publish_result | `Closed | `Closed_with_error of 'err ]

type receiver = {
  resolver : unit Eio.Promise.u;
  mutable active : bool;
}

type ('a, 'err) publisher = {
  value : 'a;
  resolver : 'err publish_out Eio.Promise.u;
  mutable active : bool;
}

type ('a, 'err) entry = {
  seq : int;
  value : 'a;
  mutable remaining : int;
}

type ('a, 'err) t = {
  mutex : Eio.Mutex.t;
  overflow : overflow;
  entries : ('a, 'err) entry Stdlib.Queue.t;
  publishers : ('a, 'err) publisher Stdlib.Queue.t;
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
  receivers : receiver Stdlib.Queue.t;
}

let create ~overflow () =
  (match overflow with
  | Unbounded -> ()
  | Drop_new { capacity } | Backpressure { capacity } ->
      if capacity <= 0 then
        invalid_arg "Eta.Pubsub.create: bounded capacity must be > 0");
  {
    mutex = Eio.Mutex.create ();
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

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let close_result = function
  | Clean -> `Closed
  | Failed err -> `Closed_with_error err

let capacity_available t =
  match t.overflow with
  | Unbounded -> true
  | Drop_new { capacity } | Backpressure { capacity } -> t.depth < capacity

let active_subscriber_count t =
  List.fold_left
    (fun count sub -> if sub.active then count + 1 else count)
    0 t.subscribers

let rec take_active_publisher
    (q : ('a, 'err) publisher Stdlib.Queue.t) :
    ('a, 'err) publisher option =
  if Stdlib.Queue.is_empty q then None
  else
    let publisher = Stdlib.Queue.take q in
    if publisher.active then Some publisher else take_active_publisher q

let wake_receiver t (receiver : receiver) =
  if receiver.active then (
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    Eio.Promise.resolve receiver.resolver ())

let wake_subscription_receivers t (sub : ('a, 'err) subscription) =
  while not (Stdlib.Queue.is_empty sub.receivers) do
    wake_receiver t (Stdlib.Queue.take sub.receivers)
  done

let wake_all_receivers t =
  List.iter
    (fun sub -> if sub.active then wake_subscription_receivers t sub)
    t.subscribers

let decrement_entry (entry : ('a, 'err) entry) =
  if entry.remaining <= 0 then
    invalid_arg "Eta.Pubsub: negative remaining subscriber count";
  entry.remaining <- entry.remaining - 1

let rec drop_drained_head_entries t =
  if not (Stdlib.Queue.is_empty t.entries) then
    let entry = Stdlib.Queue.peek t.entries in
    if entry.remaining = 0 then (
      ignore (Stdlib.Queue.take t.entries);
      t.depth <- t.depth - 1;
      drop_drained_head_entries t)

let find_entry t seq =
  let found = ref None in
  Stdlib.Queue.iter
    (fun entry -> if entry.seq = seq then found := Some entry)
    t.entries;
  !found

let rec admit_value_locked t value =
  let subscriber_count = active_subscriber_count t in
  if subscriber_count = 0 then { subscriber_count = 0; dropped = 0 }
  else (
    let entry =
      { seq = t.next_seq; value; remaining = subscriber_count }
    in
    t.next_seq <- t.next_seq + 1;
    Stdlib.Queue.add entry t.entries;
    t.depth <- t.depth + 1;
    t.published <- t.published + 1;
    wake_all_receivers t;
    { subscriber_count; dropped = 0 })

and admit_waiting_publishers_locked t =
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
              let result = admit_value_locked t publisher.value in
              Eio.Promise.resolve publisher.resolver (`Published result);
              loop ()
      in
      loop ()

let cleanup_locked t =
  drop_drained_head_entries t;
  admit_waiting_publishers_locked t

let enqueue_publisher t value =
  let promise, resolver = Eio.Promise.create () in
  let publisher = { value; resolver; active = true } in
  Stdlib.Queue.add publisher t.publishers;
  t.waiting_publishers <- t.waiting_publishers + 1;
  (promise, publisher)

let cancel_publisher t (publisher : ('a, 'err) publisher) =
  if publisher.active then (
    publisher.active <- false;
    t.waiting_publishers <- t.waiting_publishers - 1;
    t.cancelled_publishers <- t.cancelled_publishers + 1;
    admit_waiting_publishers_locked t)

let publish_sync t value =
  match
    with_lock t @@ fun () ->
    match t.closed with
    | Some reason -> `Ready (close_result reason)
    | None -> (
        let subscriber_count = active_subscriber_count t in
        match t.overflow with
        | Drop_new _ when subscriber_count > 0 && not (capacity_available t) ->
            t.dropped <- t.dropped + subscriber_count;
            `Ready (`Published { subscriber_count; dropped = subscriber_count })
        | Backpressure _ when subscriber_count > 0 && not (capacity_available t)
          ->
            let promise, publisher = enqueue_publisher t value in
            `Wait (promise, publisher)
        | Unbounded | Drop_new _ | Backpressure _ ->
            `Ready (`Published (admit_value_locked t value)))
  with
  | `Ready result -> result
  | `Wait (promise, publisher) -> (
      try Eio.Promise.await promise
      with Eio.Cancel.Cancelled _ as exn ->
        with_lock t (fun () -> cancel_publisher t publisher);
        raise exn)

let publish t value =
  Effect.sync (fun () -> publish_sync t value)
  |> Effect.bind (function
       | `Published result -> Effect.pure result
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error err -> Effect.fail (`Closed_with_error err))

let add_subscription t =
  Effect.sync (fun () ->
      with_lock t @@ fun () ->
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
          Ok sub)
  |> Effect.bind Effect.from_result

let release_subscription sub =
  let t = sub.hub in
  with_lock t @@ fun () ->
  if sub.active then (
    sub.active <- false;
    t.subscribers <- List.filter (fun other -> other.id <> sub.id) t.subscribers;
    Stdlib.Queue.iter
      (fun entry -> if entry.seq >= sub.cursor then decrement_entry entry)
      t.entries;
    wake_subscription_receivers t sub;
    cleanup_locked t)

let subscribe t f =
  Effect.scoped
    (Effect.acquire_release ~acquire:(add_subscription t)
       ~release:(fun sub -> Effect.sync (fun () -> release_subscription sub))
    |> Effect.bind f)

let consume_available_locked sub =
  let t = sub.hub in
  if not sub.active then `Closed
  else
    match find_entry t sub.cursor with
    | Some entry ->
        let value = entry.value in
        sub.cursor <- sub.cursor + 1;
        decrement_entry entry;
        t.received <- t.received + 1;
        cleanup_locked t;
        `Item value
    | None ->
        if sub.cursor < t.next_seq then
          invalid_arg "Eta.Pubsub: subscriber cursor points behind buffer";
        (match t.closed with
        | None -> `Empty
        | Some reason -> close_result reason)

let enqueue_receiver sub =
  let promise, resolver = Eio.Promise.create () in
  let receiver = { resolver; active = true } in
  Stdlib.Queue.add receiver sub.receivers;
  sub.hub.waiting_receivers <- sub.hub.waiting_receivers + 1;
  (promise, receiver)

let cancel_receiver sub (receiver : receiver) =
  let t = sub.hub in
  if receiver.active then (
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    t.cancelled_receivers <- t.cancelled_receivers + 1)

let recv_sync sub =
  let rec loop () =
    match
      with_lock sub.hub @@ fun () ->
      match consume_available_locked sub with
      | `Empty ->
          let promise, receiver = enqueue_receiver sub in
          `Wait (promise, receiver)
      | ((`Item _ | `Closed | `Closed_with_error _) as result) -> `Ready result
    with
    | `Ready result -> result
    | `Wait (promise, receiver) -> (
        try
          Eio.Promise.await promise;
          loop ()
        with Eio.Cancel.Cancelled _ as exn ->
          with_lock sub.hub (fun () -> cancel_receiver sub receiver);
          raise exn)
  in
  loop ()

let recv sub =
  Effect.sync (fun () -> recv_sync sub)
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error err -> Effect.fail (`Closed_with_error err))

let try_recv sub =
  Effect.sync (fun () -> with_lock sub.hub (fun () -> consume_available_locked sub))

let close_locked t reason =
  if Option.is_none t.closed then (
    t.closed <- Some reason;
    while not (Stdlib.Queue.is_empty t.publishers) do
      match take_active_publisher t.publishers with
      | None -> ()
      | Some publisher ->
          publisher.active <- false;
          t.waiting_publishers <- t.waiting_publishers - 1;
          Eio.Promise.resolve publisher.resolver (close_result reason)
    done;
    wake_all_receivers t)

let close t = with_lock t @@ fun () -> close_locked t Clean

let close_with_error t err =
  with_lock t @@ fun () -> close_locked t (Failed err)

let stats t =
  Eio.Mutex.use_ro t.mutex @@ fun () ->
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
