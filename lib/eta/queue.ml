type 'err close_reason = Clean | Error of 'err

type strategy =
  | Unbounded
  | Dropping of { capacity : int }
  | Sliding of { capacity : int }
  | Backpressure of { capacity : int }

type 'err offer_result =
  [ `Sent | `Dropped | `Full | `Closed | `Closed_with_error of 'err ]

type sent_token = unit ref

type 'a receiver = {
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable active : bool;
  mutable notified : bool;
  mutable reserved : 'a option;
}

type ('a, 'err) sender = {
  value : 'a;
  contract : Runtime_contract.t;
  resolver : 'err offer_result Runtime_contract.resolver;
  mutable active : bool;
  mutable result : 'err offer_result option;
  mutable notified : bool;
}

type shutdown_waiter = {
  shutdown_contract : Runtime_contract.t;
  shutdown_resolver : unit Runtime_contract.resolver;
  mutable shutdown_active : bool;
  mutable shutdown_notified : bool;
}

type ('a, 'err) t = {
  owner_domain : Domain.id;
  mutex : Sync_lock.t;
  strategy : strategy;
  values : 'a Stdlib.Queue.t;
  senders : ('a, 'err) sender Stdlib.Queue.t;
  receivers : 'a receiver Stdlib.Queue.t;
  shutdown_waiters : shutdown_waiter Stdlib.Queue.t;
  mutable closed : 'err close_reason option;
  mutable shutdown : bool;
  mutable sent : int;
  mutable received : int;
  mutable dropped : int;
  mutable waiting_senders : int;
  mutable waiting_receivers : int;
  mutable waiting_shutdown : int;
  mutable cancelled_senders : int;
  mutable cancelled_receivers : int;
  mutable cancelled_shutdown : int;
  mutable cancelled_sender_debt : int;
  mutable cancelled_receiver_debt : int;
  mutable cancelled_shutdown_debt : int;
  mutable sent_token : sent_token;
}

type ('a, 'err) enqueue = Enqueue of ('a, 'err) t
type ('a, 'err) dequeue = Dequeue of ('a, 'err) t

type ('a, 'err) wakeup =
  | Wake_sender of ('a, 'err) sender * 'err offer_result
  | Wake_receiver of 'a receiver
  | Wake_shutdown of shutdown_waiter

type stats = {
  capacity : int option;
  depth : int;
  size : int;
  sent : int;
  received : int;
  dropped : int;
  closed : bool;
  shutdown : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
  cancelled_receivers : int;
}

type ('a, 'err) poll_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

let validate_strategy constructor = function
  | Unbounded -> ()
  | Dropping { capacity } | Sliding { capacity } | Backpressure { capacity } ->
      if capacity <= 0 then
        invalid_arg ("Eta.Queue." ^ constructor ^ ": capacity must be > 0")

let saturating_succ value =
  if value = max_int then max_int else value + 1

let new_sent_token () = ref ()

let invariant_failed message =
  invalid_arg ("Eta.Queue invariant failed: " ^ message)

let create_with_strategy constructor strategy =
  validate_strategy constructor strategy;
  {
    owner_domain = Domain.self ();
    mutex = Sync_lock.create ();
    strategy;
    values = Stdlib.Queue.create ();
    senders = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    shutdown_waiters = Stdlib.Queue.create ();
    closed = None;
    shutdown = false;
    sent = 0;
    received = 0;
    dropped = 0;
    waiting_senders = 0;
    waiting_receivers = 0;
    waiting_shutdown = 0;
    cancelled_senders = 0;
    cancelled_receivers = 0;
    cancelled_shutdown = 0;
    cancelled_sender_debt = 0;
    cancelled_receiver_debt = 0;
    cancelled_shutdown_debt = 0;
    sent_token = new_sent_token ();
  }

let unbounded () = create_with_strategy "unbounded" Unbounded
let bounded ~capacity () =
  create_with_strategy "bounded" (Backpressure { capacity })

let dropping ~capacity () =
  create_with_strategy "dropping" (Dropping { capacity })

let sliding ~capacity () =
  create_with_strategy "sliding" (Sliding { capacity })

let enqueue t = Enqueue t
let dequeue t = Dequeue t

let context_error_message =
  "Eta.Queue: queue APIs must be called on the domain that created the queue"

let ensure_owner_domain t =
  if Domain.self () <> t.owner_domain then invalid_arg context_error_message

let with_lock (t : ('a, 'err) t) f =
  ensure_owner_domain t;
  Sync_lock.use t.mutex f

let with_lock_during_cancel contract t f =
  contract.Runtime_contract.protect (fun () -> with_lock t f)

let close_result = function
  | Clean -> `Closed
  | Error error -> `Closed_with_error error

let add_wakeup wakeups wakeup = Stdlib.Queue.add wakeup wakeups

let resolve_sender
    (sender : ('a, 'err) sender)
    (result : 'err offer_result) =
  if not sender.notified then
    sender.contract.Runtime_contract.protect (fun () ->
        sender.contract.Runtime_contract.resolve_promise sender.resolver result;
        sender.notified <- true)

let wake_receiver (receiver : 'a receiver) =
  if not receiver.notified then
    receiver.contract.Runtime_contract.protect (fun () ->
        receiver.contract.Runtime_contract.resolve_promise receiver.resolver ();
        receiver.notified <- true)

let wake_shutdown_waiter waiter =
  if not waiter.shutdown_notified then
    waiter.shutdown_contract.Runtime_contract.protect (fun () ->
        waiter.shutdown_contract.Runtime_contract.resolve_promise
          waiter.shutdown_resolver ();
        waiter.shutdown_notified <- true)

let resolve_wakeup = function
  | Wake_sender (sender, result) -> resolve_sender sender result
  | Wake_receiver receiver -> wake_receiver receiver
  | Wake_shutdown waiter -> wake_shutdown_waiter waiter

let wakeup_notified = function
  | Wake_sender (sender, _) -> sender.notified
  | Wake_receiver receiver -> receiver.notified
  | Wake_shutdown waiter -> waiter.shutdown_notified

(* Waiter wakeups are post-commit bookkeeping. Runtime_contract requires
   resolver notification to fail only for non-transient programmer/runtime
   boundary errors. Once queue state has changed, such failures belong to the
   waiter boundary and must not replace the active operation's result. *)
let rec resolve_wakeup_best_effort remaining wakeup =
  try
    resolve_wakeup wakeup;
    true
  with _exn ->
    wakeup_notified wakeup
    || (remaining > 0 && resolve_wakeup_best_effort (remaining - 1) wakeup)

let resolve_pending_wakeups pending =
  let rec loop () =
    if not (Stdlib.Queue.is_empty pending) then (
      let wakeup = Stdlib.Queue.take pending in
      ignore (resolve_wakeup_best_effort 1 wakeup : bool);
      loop ())
  in
  loop ()

let with_committed_wakeups_locked lock f =
  let pending_wakeups = Stdlib.Queue.create () in
  Fun.protect
    ~finally:(fun () -> resolve_pending_wakeups pending_wakeups)
    (fun () ->
      let result = lock (fun () -> f pending_wakeups) in
      resolve_pending_wakeups pending_wakeups;
      result)

let with_committed_wakeups_sync t f =
  with_committed_wakeups_locked (with_lock t) f

let with_committed_wakeups_during_cancel contract t f =
  with_committed_wakeups_locked (with_lock_during_cancel contract t) f

let with_committed_wakeups_effect t f =
  Effect.sync (fun () -> with_committed_wakeups_sync t f)

let settle_sender wakeups sender result =
  sender.result <- Some result;
  add_wakeup wakeups (Wake_sender (sender, result))

let strategy_capacity = function
  | Unbounded -> None
  | Dropping { capacity }
  | Sliding { capacity }
  | Backpressure { capacity } ->
      Some capacity

let capacity_sync (t : ('a, 'err) t) = strategy_capacity t.strategy

let size_locked (t : ('a, 'err) t) =
  if t.shutdown then 0
  else Stdlib.Queue.length t.values - t.waiting_receivers + t.waiting_senders

let capacity_available (t : ('a, 'err) t) =
  match t.strategy with
  | Unbounded -> true
  | Dropping { capacity } | Sliding { capacity } | Backpressure { capacity } ->
      Stdlib.Queue.length t.values < capacity

let rec take_active_receiver_locked (t : ('a, 'err) t) : 'a receiver option =
  if Stdlib.Queue.is_empty t.receivers then None
  else
    let receiver = Stdlib.Queue.take t.receivers in
    if receiver.active then Some receiver
    else (
      if t.cancelled_receiver_debt > 0 then
        t.cancelled_receiver_debt <- t.cancelled_receiver_debt - 1;
      take_active_receiver_locked t)

let rec take_active_sender_locked t =
  if Stdlib.Queue.is_empty t.senders then None
  else
    let sender = Stdlib.Queue.take t.senders in
    if sender.active then Some sender
    else (
      if t.cancelled_sender_debt > 0 then
        t.cancelled_sender_debt <- t.cancelled_sender_debt - 1;
      take_active_sender_locked t)

let take_sender_locked (t : ('a, 'err) t) =
  match take_active_sender_locked t with
  | None -> None
  | Some sender ->
      sender.active <- false;
      t.waiting_senders <- t.waiting_senders - 1;
      Some sender

let reserve_receiver_value_locked
    wakeups
    (t : ('a, 'err) t)
    (receiver : 'a receiver)
    value =
  t.waiting_receivers <- t.waiting_receivers - 1;
  receiver.active <- false;
  receiver.reserved <- Some value;
  t.sent <- saturating_succ t.sent;
  t.received <- saturating_succ t.received;
  t.sent_token <- new_sent_token ();
  add_wakeup wakeups (Wake_receiver receiver)

let enqueue_value_locked wakeups (t : ('a, 'err) t) value =
  match take_active_receiver_locked t with
  | Some receiver -> reserve_receiver_value_locked wakeups t receiver value
  | None ->
      Stdlib.Queue.add value t.values;
      t.sent <- saturating_succ t.sent;
      t.sent_token <- new_sent_token ()

let wake_one_receiver_locked wakeups (t : ('a, 'err) t) =
  match take_active_receiver_locked t with
  | None -> ()
  | Some receiver ->
      t.waiting_receivers <- t.waiting_receivers - 1;
      receiver.active <- false;
      add_wakeup wakeups (Wake_receiver receiver)

let rec admit_waiting_senders_locked wakeups (t : ('a, 'err) t) =
  match t.strategy with
  | Unbounded | Dropping _ | Sliding _ -> ()
  | Backpressure _ ->
      if (not t.shutdown) && Option.is_none t.closed && capacity_available t
      then
        match take_sender_locked t with
        | None -> ()
        | Some sender ->
            enqueue_value_locked wakeups t sender.value;
            settle_sender wakeups sender `Sent;
            admit_waiting_senders_locked wakeups t

let wake_all_receivers_locked wakeups (t : ('a, 'err) t) =
  let rec loop () =
    match take_active_receiver_locked t with
    | None -> ()
    | Some receiver ->
        t.waiting_receivers <- t.waiting_receivers - 1;
        receiver.active <- false;
        add_wakeup wakeups (Wake_receiver receiver);
        loop ()
  in
  loop ()

let wake_all_senders_locked wakeups (t : ('a, 'err) t) reason =
  let rec loop () =
    match take_sender_locked t with
    | None -> ()
    | Some sender ->
        settle_sender wakeups sender (close_result reason);
        loop ()
  in
  loop ()

let rec take_active_shutdown_waiter_locked (t : ('a, 'err) t) =
  if Stdlib.Queue.is_empty t.shutdown_waiters then None
  else
    let waiter = Stdlib.Queue.take t.shutdown_waiters in
    if waiter.shutdown_active then Some waiter
    else (
      if t.cancelled_shutdown_debt > 0 then
        t.cancelled_shutdown_debt <- t.cancelled_shutdown_debt - 1;
      take_active_shutdown_waiter_locked t)

let wake_all_shutdown_waiters_locked wakeups (t : ('a, 'err) t) =
  let rec loop () =
    match take_active_shutdown_waiter_locked t with
    | None -> ()
    | Some waiter ->
        t.waiting_shutdown <- t.waiting_shutdown - 1;
        waiter.shutdown_active <- false;
        add_wakeup wakeups (Wake_shutdown waiter);
        loop ()
  in
  loop ()

let should_compact_cancelled retained_cancelled queue_length =
  if retained_cancelled <= 0 || queue_length <= 0 then false
  else
    let half_rounded_up = (queue_length / 2) + (queue_length mod 2) in
    retained_cancelled >= max 1 half_rounded_up

let compact_cancelled_senders_locked (t : ('a, 'err) t) =
  if
    should_compact_cancelled t.cancelled_sender_debt
      (Stdlib.Queue.length t.senders)
  then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun (sender : ('a, 'err) sender) ->
        if sender.active then Stdlib.Queue.push sender live)
      t.senders;
    Stdlib.Queue.clear t.senders;
    Stdlib.Queue.iter
      (fun sender -> Stdlib.Queue.push sender t.senders)
      live;
    t.cancelled_sender_debt <- 0)

let compact_cancelled_receivers_locked (t : ('a, 'err) t) =
  if
    should_compact_cancelled t.cancelled_receiver_debt
      (Stdlib.Queue.length t.receivers)
  then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun (receiver : 'a receiver) ->
        if receiver.active then Stdlib.Queue.push receiver live)
      t.receivers;
    Stdlib.Queue.clear t.receivers;
    Stdlib.Queue.iter
      (fun receiver -> Stdlib.Queue.push receiver t.receivers)
      live;
    t.cancelled_receiver_debt <- 0)

let compact_cancelled_shutdown_waiters_locked (t : ('a, 'err) t) =
  if
    should_compact_cancelled t.cancelled_shutdown_debt
      (Stdlib.Queue.length t.shutdown_waiters)
  then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun waiter ->
        if waiter.shutdown_active then Stdlib.Queue.push waiter live)
      t.shutdown_waiters;
    Stdlib.Queue.clear t.shutdown_waiters;
    Stdlib.Queue.iter
      (fun waiter -> Stdlib.Queue.push waiter t.shutdown_waiters)
      live;
    t.cancelled_shutdown_debt <- 0)

let cancel_receiver (t : ('a, 'err) t) (receiver : 'a receiver) =
  if receiver.active then (
    receiver.active <- false;
    t.waiting_receivers <- t.waiting_receivers - 1;
    t.cancelled_receivers <- saturating_succ t.cancelled_receivers;
    t.cancelled_receiver_debt <- saturating_succ t.cancelled_receiver_debt;
    compact_cancelled_receivers_locked t)

let cancel_sender wakeups (t : ('a, 'err) t) sender =
  if sender.active then (
    sender.active <- false;
    t.waiting_senders <- t.waiting_senders - 1;
    t.cancelled_senders <- saturating_succ t.cancelled_senders;
    t.cancelled_sender_debt <- saturating_succ t.cancelled_sender_debt;
    compact_cancelled_senders_locked t;
    admit_waiting_senders_locked wakeups t)

let cancel_shutdown_waiter (t : ('a, 'err) t) waiter =
  if waiter.shutdown_active then (
    waiter.shutdown_active <- false;
    t.waiting_shutdown <- t.waiting_shutdown - 1;
    t.cancelled_shutdown <- saturating_succ t.cancelled_shutdown;
    t.cancelled_shutdown_debt <- saturating_succ t.cancelled_shutdown_debt;
    compact_cancelled_shutdown_waiters_locked t)

let enqueue_sender contract (t : ('a, 'err) t) value =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let sender =
    { value; contract; resolver; active = true; result = None; notified = false }
  in
  Stdlib.Queue.add sender t.senders;
  t.waiting_senders <- t.waiting_senders + 1;
  (promise, sender)

let drop_oldest_locked t =
  ignore (Stdlib.Queue.take t.values : _);
  t.dropped <- saturating_succ t.dropped

let try_offer_sync t value =
  with_committed_wakeups_sync t @@ fun wakeups ->
    match (t.shutdown, t.closed) with
    | true, _ -> `Closed
    | false, Some reason -> close_result reason
    | false, None ->
        if capacity_available t then (
          enqueue_value_locked wakeups t value;
          `Sent)
        else
          match t.strategy with
          | Unbounded ->
              invariant_failed "unbounded queue reported no capacity"
          | Dropping _ ->
              t.dropped <- saturating_succ t.dropped;
              `Dropped
          | Sliding _ ->
              drop_oldest_locked t;
              enqueue_value_locked wakeups t value;
              `Sent
          | Backpressure _ -> `Full

let offer_sync contract t value =
  match
    with_committed_wakeups_sync t @@ fun wakeups ->
      match (t.shutdown, t.closed) with
      | true, _ -> `Ready `Closed
      | false, Some reason -> `Ready (close_result reason)
      | false, None ->
          if capacity_available t then (
            enqueue_value_locked wakeups t value;
            `Ready `Sent)
          else
            match t.strategy with
            | Unbounded ->
                invariant_failed "unbounded queue reported no capacity"
            | Dropping _ ->
                t.dropped <- saturating_succ t.dropped;
                `Ready `Dropped
            | Sliding _ ->
                drop_oldest_locked t;
                enqueue_value_locked wakeups t value;
                `Ready `Sent
            | Backpressure _ ->
                let promise, sender = enqueue_sender contract t value in
                `Wait (promise, sender)
  with
  | `Ready result -> result
  | `Wait (promise, sender) -> (
      try contract.Runtime_contract.await_promise promise
      with exn
        when Option.is_some
               (contract.Runtime_contract.cancellation_reason exn) ->
        let cancellation =
          with_committed_wakeups_during_cancel contract t (fun cancel_wakeups ->
              match sender.result with
              | Some result -> `Settled result
              | None ->
                  cancel_sender cancel_wakeups t sender;
                  `Cancelled)
        in
        match cancellation with
        | `Settled result -> result
        | `Cancelled -> raise exn)

let try_offer t value = Effect.sync (fun () -> try_offer_sync t value)

let sent_token t = with_lock t @@ fun () -> t.sent_token
let same_sent_token left right = left == right

let offer t value =
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         offer_sync frame.Effect_core.runtime.Runtime_core.contract t value))
  |> Effect.bind (function
       | `Sent -> Effect.pure true
       | `Dropped -> Effect.pure false
       | `Full -> invariant_failed "blocking offer returned Full"
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let fail_if_closed t =
  Effect.sync (fun () -> with_lock t @@ fun () -> (t.shutdown, t.closed))
  |> Effect.bind (function
       | true, _ -> Effect.fail `Closed
       | false, None -> Effect.unit
       | false, Some Clean -> Effect.fail `Closed
       | false, Some (Error error) -> Effect.fail (`Closed_with_error error))

let offer_all t values =
  let rec loop dropped = function
    | [] -> Effect.pure (List.rev dropped)
    | value :: rest ->
        offer t value
        |> Effect.bind (function
             | true -> loop dropped rest
             | false -> loop (value :: dropped) rest)
  in
  fail_if_closed t |> Effect.bind (fun () -> loop [] values)

let send t value =
  offer t value
  |> Effect.bind (function
       | true -> Effect.unit
       | false -> Effect.fail `Dropped)

let take_value wakeups t =
  let value = Stdlib.Queue.take t.values in
  t.received <- saturating_succ t.received;
  admit_waiting_senders_locked wakeups t;
  `Item value

let poll t =
  with_committed_wakeups_effect t @@ fun wakeups ->
    if t.shutdown then `Closed
    else if not (Stdlib.Queue.is_empty t.values) then take_value wakeups t
    else
      match t.closed with
      | None -> `Empty
      | Some reason -> close_result reason

let drain_locked wakeups t max =
  let rec loop remaining acc =
    if remaining = 0 || Stdlib.Queue.is_empty t.values then List.rev acc
    else
      let value = Stdlib.Queue.take t.values in
      t.received <- saturating_succ t.received;
      loop (remaining - 1) (value :: acc)
  in
  let values = loop max [] in
  if values <> [] then admit_waiting_senders_locked wakeups t;
  values

let drain_result_locked wakeups (t : ('a, 'err) t) max =
  if t.shutdown then `Closed
  else
    let values = drain_locked wakeups t max in
    match values with
    | _ :: _ -> `Items values
    | [] -> (
        match t.closed with
        | None -> `Items []
        | Some reason -> close_result reason)

let drain_result_effect t max =
  with_committed_wakeups_effect t (fun wakeups ->
      drain_result_locked wakeups t max)

let drain_all_result_effect t =
  with_committed_wakeups_effect t (fun wakeups ->
      drain_result_locked wakeups t (Stdlib.Queue.length t.values))

let take_all t =
  drain_all_result_effect t
  |> Effect.bind (function
       | `Items values -> Effect.pure values
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let take_up_to t ~max =
  if max < 0 then invalid_arg "Eta.Queue.take_up_to: max must be >= 0";
  drain_result_effect t max
  |> Effect.bind (function
       | `Items values -> Effect.pure values
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let enqueue_receiver contract t =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let receiver =
    { contract; resolver; active = true; notified = false; reserved = None }
  in
  Stdlib.Queue.add receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let take_receiver_reservation (receiver : 'a receiver) =
  match receiver.reserved with
  | None -> None
  | Some value ->
      receiver.reserved <- None;
      Some value

let enqueue_shutdown_waiter contract t =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let waiter =
    {
      shutdown_contract = contract;
      shutdown_resolver = resolver;
      shutdown_active = true;
      shutdown_notified = false;
    }
  in
  Stdlib.Queue.add waiter t.shutdown_waiters;
  t.waiting_shutdown <- t.waiting_shutdown + 1;
  (promise, waiter)

let await_shutdown_sync contract t =
  match
    with_committed_wakeups_sync t @@ fun _wakeups ->
      if t.shutdown then `Ready
      else
        let promise, waiter = enqueue_shutdown_waiter contract t in
        `Wait (promise, waiter)
  with
  | `Ready -> ()
  | `Wait (promise, waiter) -> (
      try contract.Runtime_contract.await_promise promise
      with exn
        when Option.is_some
               (contract.Runtime_contract.cancellation_reason exn) ->
        if waiter.shutdown_notified then ()
        else (
          with_lock_during_cancel contract t (fun () ->
              cancel_shutdown_waiter t waiter);
          raise exn))

let take_sync contract t =
  let rec loop () =
    match
      with_committed_wakeups_sync t @@ fun wakeups ->
        if t.shutdown then `Ready `Closed
        else if not (Stdlib.Queue.is_empty t.values) then
          `Ready (take_value wakeups t)
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
          match take_receiver_reservation receiver with
          | Some value -> `Item value
          | None -> loop ()
        with exn
          when Option.is_some
                 (contract.Runtime_contract.cancellation_reason exn) ->
          match take_receiver_reservation receiver with
          | Some value -> `Item value
          | None ->
              with_lock_during_cancel contract t (fun () ->
                  cancel_receiver t receiver);
              raise exn)
  in
  loop ()

let take t =
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         take_sync frame.Effect_core.runtime.Runtime_core.contract t))
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> invariant_failed "blocking take returned Empty"
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let close_with reason t =
  with_committed_wakeups_sync t
    (fun wakeups ->
      match (t.shutdown, t.closed) with
      | true, _ | false, Some _ -> ()
      | false, None ->
          t.closed <- Some reason;
          wake_all_senders_locked wakeups t reason;
          wake_all_receivers_locked wakeups t)

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let shutdown t =
  with_committed_wakeups_sync t
    (fun wakeups ->
      if not t.shutdown then (
        t.shutdown <- true;
        if Option.is_none t.closed then t.closed <- Some Clean;
        let buffered = Stdlib.Queue.length t.values in
        Stdlib.Queue.clear t.values;
        for _ = 1 to buffered do
          t.dropped <- saturating_succ t.dropped
        done;
        wake_all_senders_locked wakeups t Clean;
        wake_all_receivers_locked wakeups t;
        wake_all_shutdown_waiters_locked wakeups t))

let close_effect t = Effect.sync (fun () -> close t)
let close_with_error_effect t error =
  Effect.sync (fun () -> close_with_error t error)

let shutdown_effect t = Effect.sync (fun () -> shutdown t)

let await_shutdown t =
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         await_shutdown_sync frame.Effect_core.runtime.Runtime_core.contract t))

let capacity t = with_lock t @@ fun () -> capacity_sync t
let size t = with_lock t @@ fun () -> size_locked t
let is_shutdown t = with_lock t @@ fun () -> t.shutdown

let is_empty t =
  with_lock t @@ fun () -> size_locked t <= 0

let is_full t =
  with_lock t @@ fun () ->
  match capacity_sync t with
  | None -> false
  | Some capacity -> size_locked t >= capacity

let stats t =
  with_lock t @@ fun () ->
  {
    capacity = capacity_sync t;
    depth = Stdlib.Queue.length t.values;
    size = size_locked t;
    sent = t.sent;
    received = t.received;
    dropped = t.dropped;
    closed = Option.is_some t.closed;
    shutdown = t.shutdown;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
    cancelled_receivers = t.cancelled_receivers;
  }

module Enqueue = struct
  type nonrec ('a, 'err) t = ('a, 'err) enqueue

  let offer (Enqueue queue) value = offer queue value
  let offer_all (Enqueue queue) values = offer_all queue values
  let send (Enqueue queue) value = send queue value
  let try_offer (Enqueue queue) value = try_offer queue value
  let capacity (Enqueue queue) = capacity queue
  let size (Enqueue queue) = size queue
  let is_empty (Enqueue queue) = is_empty queue
  let is_full (Enqueue queue) = is_full queue
  let is_shutdown (Enqueue queue) = is_shutdown queue
  let shutdown (Enqueue queue) = shutdown queue
  let shutdown_effect (Enqueue queue) = shutdown_effect queue
  let await_shutdown (Enqueue queue) = await_shutdown queue
end

module Dequeue = struct
  type nonrec ('a, 'err) t = ('a, 'err) dequeue

  let take (Dequeue queue) = take queue
  let poll (Dequeue queue) = poll queue
  let take_all (Dequeue queue) = take_all queue
  let take_up_to (Dequeue queue) ~max = take_up_to queue ~max
  let capacity (Dequeue queue) = capacity queue
  let size (Dequeue queue) = size queue
  let is_empty (Dequeue queue) = is_empty queue
  let is_full (Dequeue queue) = is_full queue
  let is_shutdown (Dequeue queue) = is_shutdown queue
  let shutdown (Dequeue queue) = shutdown queue
  let shutdown_effect (Dequeue queue) = shutdown_effect queue
  let await_shutdown (Dequeue queue) = await_shutdown queue
end
