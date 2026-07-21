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
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable active : bool;
}

type ('a, 'err) publisher = {
  value : 'a;
  contract : Runtime_contract.t;
  resolver : 'err publish_out Runtime_contract.resolver;
  mutable active : bool;
}

type ('a, 'err) wakeup =
  | Wake_receiver of receiver
  | Wake_publisher of ('a, 'err) publisher * 'err publish_out

type ('a, 'err) entry = {
  seq : int;
  value : 'a;
  mutable remaining : int;
}

type ('a, 'err) t = {
  mutex : Sync_lock.t;
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
    mutex = Sync_lock.create ();
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
  Sync_lock.use t.mutex f

let with_lock_during_cancel contract t f =
  contract.Runtime_contract.protect (fun () -> with_lock t f)

let close_result = function
  | Clean -> `Closed
  | Failed err -> `Closed_with_error err

let add_wakeup wakeups wakeup = wakeups := wakeup :: !wakeups

let resolve_receiver (receiver : receiver) =
  receiver.contract.Runtime_contract.protect (fun () ->
      receiver.contract.Runtime_contract.resolve_promise receiver.resolver ())

let resolve_publisher
    (publisher : ('a, 'err) publisher)
    (result : 'err publish_out) =
  publisher.contract.Runtime_contract.protect (fun () ->
      publisher.contract.Runtime_contract.resolve_promise publisher.resolver
        result)

let resolve_wakeup = function
  | Wake_receiver receiver -> resolve_receiver receiver
  | Wake_publisher (publisher, result) -> resolve_publisher publisher result

let resolve_wakeups wakeups =
  List.iter resolve_wakeup (List.rev wakeups)

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

let[@inline always] deactivate_publisher_locked (t : ('a, 'err) t)
    (publisher : ('a, 'err) publisher) =
  publisher.active <- false;
  t.waiting_publishers <- t.waiting_publishers - 1

let compact_cancelled_publishers_locked (t : ('a, 'err) t) =
  if t.cancelled_publishers > 0 then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun (publisher : ('a, 'err) publisher) ->
        if publisher.active then Stdlib.Queue.push publisher live)
      t.publishers;
    Stdlib.Queue.clear t.publishers;
    Stdlib.Queue.iter
      (fun publisher -> Stdlib.Queue.push publisher t.publishers)
      live)

let compact_cancelled_receivers_locked (sub : ('a, 'err) subscription) =
  if sub.hub.cancelled_receivers > 0 then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun (receiver : receiver) ->
        if receiver.active then Stdlib.Queue.push receiver live)
      sub.receivers;
    Stdlib.Queue.clear sub.receivers;
    Stdlib.Queue.iter
      (fun receiver -> Stdlib.Queue.push receiver sub.receivers)
      live)

let[@inline always] deactivate_receiver_locked t (receiver : receiver) =
  receiver.active <- false;
  t.waiting_receivers <- t.waiting_receivers - 1

let wake_receiver wakeups t (receiver : receiver) =
  if receiver.active then (
    deactivate_receiver_locked t receiver;
    add_wakeup wakeups (Wake_receiver receiver))

let wake_subscription_receivers wakeups t (sub : ('a, 'err) subscription) =
  while not (Stdlib.Queue.is_empty sub.receivers) do
    wake_receiver wakeups t (Stdlib.Queue.take sub.receivers)
  done

let wake_all_receivers wakeups t =
  List.iter
    (fun sub -> if sub.active then wake_subscription_receivers wakeups t sub)
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

let rec admit_value_locked wakeups t value =
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
    wake_all_receivers wakeups t;
    { subscriber_count; dropped = 0 })

and admit_waiting_publishers_locked wakeups t =
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
              deactivate_publisher_locked t publisher;
              let result = admit_value_locked wakeups t publisher.value in
              add_wakeup wakeups
                (Wake_publisher (publisher, `Published result));
              loop ()
      in
      loop ()

let cleanup_locked wakeups t =
  drop_drained_head_entries t;
  admit_waiting_publishers_locked wakeups t

let enqueue_publisher contract t value =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let publisher = { value; contract; resolver; active = true } in
  Stdlib.Queue.add publisher t.publishers;
  t.waiting_publishers <- t.waiting_publishers + 1;
  (promise, publisher)

let cancel_publisher wakeups t (publisher : ('a, 'err) publisher) =
  if publisher.active then (
    deactivate_publisher_locked t publisher;
    t.cancelled_publishers <- t.cancelled_publishers + 1;
    compact_cancelled_publishers_locked t;
    admit_waiting_publishers_locked wakeups t)

let publish_sync contract t value =
  let wakeups = ref [] in
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
            let promise, publisher = enqueue_publisher contract t value in
            `Wait (promise, publisher)
        | Unbounded | Drop_new _ | Backpressure _ ->
            `Ready (`Published (admit_value_locked wakeups t value)))
  with
  | `Ready result ->
      resolve_wakeups !wakeups;
      result
  | `Wait (promise, publisher) -> (
      try contract.Runtime_contract.await_promise promise
      with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
        let cancel_wakeups = ref [] in
        with_lock_during_cancel contract t
          (fun () -> cancel_publisher cancel_wakeups t publisher);
        resolve_wakeups !cancel_wakeups;
        raise exn)

let publish t value =
  Effect_erasure.public_sync ~leaf_name:"Pubsub.publish"
    ~footprint:(Effect_core.footprint ~has_concurrency:true ()) t (fun contract t ->
      publish_sync contract t value)
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
  |> Effect.flatten_result

let release_subscription sub =
  let t = sub.hub in
  let wakeups = ref [] in
  with_lock t
    (fun () ->
      if sub.active then (
        sub.active <- false;
        t.subscribers <-
          List.filter (fun other -> other.id <> sub.id) t.subscribers;
        Stdlib.Queue.iter
          (fun entry -> if entry.seq >= sub.cursor then decrement_entry entry)
          t.entries;
        wake_subscription_receivers wakeups t sub;
        cleanup_locked wakeups t));
  resolve_wakeups !wakeups

let subscribe t f =
  Effect.with_scope
    (Effect.acquire_release ~acquire:(add_subscription t)
       ~release:(fun sub -> Effect.sync (fun () -> release_subscription sub))
    |> Effect.bind f)

let consume_available_locked wakeups sub =
  let t = sub.hub in
  if not sub.active then `Closed
  else
    match find_entry t sub.cursor with
    | Some entry ->
        let value = entry.value in
        sub.cursor <- sub.cursor + 1;
        decrement_entry entry;
        t.received <- t.received + 1;
        cleanup_locked wakeups t;
        `Item value
    | None ->
        if sub.cursor < t.next_seq then
          invalid_arg "Eta.Pubsub: subscriber cursor points behind buffer";
        (match t.closed with
        | None -> `Empty
        | Some reason -> close_result reason)

let enqueue_receiver contract sub =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let receiver = { contract; resolver; active = true } in
  Stdlib.Queue.add receiver sub.receivers;
  sub.hub.waiting_receivers <- sub.hub.waiting_receivers + 1;
  (promise, receiver)

let cancel_receiver sub (receiver : receiver) =
  let t = sub.hub in
  if receiver.active then (
    deactivate_receiver_locked t receiver;
    t.cancelled_receivers <- t.cancelled_receivers + 1;
    compact_cancelled_receivers_locked sub)

let recv_sync contract sub =
  let rec loop () =
    let wakeups = ref [] in
    match
      with_lock sub.hub @@ fun () ->
      match consume_available_locked wakeups sub with
      | `Empty ->
          let promise, receiver = enqueue_receiver contract sub in
          `Wait (promise, receiver)
      | ((`Item _ | `Closed | `Closed_with_error _) as result) -> `Ready result
    with
    | `Ready result ->
        resolve_wakeups !wakeups;
        result
    | `Wait (promise, receiver) -> (
        try
          contract.Runtime_contract.await_promise promise;
          loop ()
        with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
          with_lock_during_cancel contract sub.hub
            (fun () -> cancel_receiver sub receiver);
          raise exn)
  in
  loop ()

let recv sub =
  Effect_erasure.public_sync ~leaf_name:"Pubsub.recv"
    ~footprint:(Effect_core.footprint ~has_concurrency:true ()) sub recv_sync
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> assert false
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error err -> Effect.fail (`Closed_with_error err))

let try_recv sub =
  Effect.sync (fun () ->
      let wakeups = ref [] in
      let result =
        with_lock sub.hub (fun () -> consume_available_locked wakeups sub)
      in
      resolve_wakeups !wakeups;
      result)

let close_locked wakeups t reason =
  if Option.is_none t.closed then (
    t.closed <- Some reason;
    while not (Stdlib.Queue.is_empty t.publishers) do
      match take_active_publisher t.publishers with
      | None -> ()
      | Some publisher ->
          deactivate_publisher_locked t publisher;
          add_wakeup wakeups
            (Wake_publisher (publisher, close_result reason))
    done;
    wake_all_receivers wakeups t)

let close t =
  let wakeups = ref [] in
  with_lock t (fun () -> close_locked wakeups t Clean);
  resolve_wakeups !wakeups

let close_with_error t err =
  let wakeups = ref [] in
  with_lock t (fun () -> close_locked wakeups t (Failed err));
  resolve_wakeups !wakeups

let close_effect t = Effect.sync (fun () -> close t)
let close_with_error_effect t err =
  Effect.sync (fun () -> close_with_error t err)

let stats t =
  Sync_lock.use t.mutex @@ fun () ->
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
