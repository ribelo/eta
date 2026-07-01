type 'err close_reason = Clean | Error of 'err

type overflow =
  | Unbounded
  | Drop_new of { capacity : int }
  | Backpressure of { capacity : int }

type 'err send_result =
  [ `Sent | `Dropped | `Full | `Closed | `Closed_with_error of 'err ]

type receiver = {
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable active : bool;
  mutable notified : bool;
}

type ('a, 'err) sender = {
  value : 'a;
  contract : Runtime_contract.t;
  resolver : 'err send_result Runtime_contract.resolver;
  mutable active : bool;
  mutable result : 'err send_result option;
  mutable notified : bool;
}

type ('a, 'err) t = {
  owner_domain : Domain.id;
  mutex : Sync_lock.t;
  overflow : overflow;
  values : 'a Stdlib.Queue.t;
  senders : ('a, 'err) sender Stdlib.Queue.t;
  receivers : receiver Stdlib.Queue.t;
  mutable closed : 'err close_reason option;
  mutable sent : int;
  mutable received : int;
  mutable dropped : int;
  mutable waiting_senders : int;
  mutable waiting_receivers : int;
  mutable cancelled_senders : int;
  mutable cancelled_receivers : int;
  mutable cancelled_sender_debt : int;
  mutable cancelled_receiver_debt : int;
}

type ('a, 'err) wakeup =
  | Wake_sender of ('a, 'err) sender * 'err send_result
  | Wake_receiver of receiver

type stats = {
  depth : int;
  sent : int;
  received : int;
  dropped : int;
  closed : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
  cancelled_receivers : int;
}

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

let validate_overflow = function
  | Unbounded -> ()
  | Drop_new { capacity } | Backpressure { capacity } ->
      if capacity <= 0 then
        invalid_arg "Eta.Queue.create: bounded capacity must be > 0"

let saturating_succ value =
  if value = max_int then max_int else value + 1

let invariant_failed message =
  invalid_arg ("Eta.Queue invariant failed: " ^ message)

let create ?(overflow = Unbounded) () =
  validate_overflow overflow;
  {
    owner_domain = Domain.self ();
    mutex = Sync_lock.create ();
    overflow;
    values = Stdlib.Queue.create ();
    senders = Stdlib.Queue.create ();
    receivers = Stdlib.Queue.create ();
    closed = None;
    sent = 0;
    received = 0;
    dropped = 0;
    waiting_senders = 0;
    waiting_receivers = 0;
    cancelled_senders = 0;
    cancelled_receivers = 0;
    cancelled_sender_debt = 0;
    cancelled_receiver_debt = 0;
  }

let unbounded () = create ~overflow:Unbounded ()

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

let add_wakeup wakeups wakeup = wakeups := wakeup :: !wakeups

let resolve_sender
    (sender : ('a, 'err) sender)
    (result : 'err send_result) =
  if not sender.notified then
    sender.contract.Runtime_contract.protect (fun () ->
        sender.contract.Runtime_contract.resolve_promise sender.resolver result;
        sender.notified <- true)

let wake_receiver (receiver : receiver) =
  if not receiver.notified then
    receiver.contract.Runtime_contract.protect (fun () ->
        receiver.contract.Runtime_contract.resolve_promise receiver.resolver ();
        receiver.notified <- true)

let resolve_wakeup = function
  | Wake_sender (sender, result) -> resolve_sender sender result
  | Wake_receiver receiver -> wake_receiver receiver

let resolve_wakeups wakeups =
  List.iter resolve_wakeup (List.rev wakeups)

let wakeup_notified = function
  | Wake_sender (sender, _) -> sender.notified
  | Wake_receiver receiver -> receiver.notified

let resolve_pending_wakeups pending =
  let rec loop () =
    match !pending with
    | [] -> ()
    | wakeup :: rest -> (
        try
          resolve_wakeup wakeup;
          pending := rest;
          loop ()
        with exn ->
          if wakeup_notified wakeup then pending := rest;
          raise exn)
  in
  loop ()

let settle_sender wakeups sender result =
  sender.result <- Some result;
  add_wakeup wakeups (Wake_sender (sender, result))

let capacity_available (t : ('a, 'err) t) =
  match t.overflow with
  | Unbounded -> true
  | Drop_new { capacity } | Backpressure { capacity } ->
      Stdlib.Queue.length t.values < capacity

let rec take_active_receiver_locked t =
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

let wake_one_receiver_locked wakeups (t : ('a, 'err) t) =
  match take_active_receiver_locked t with
  | None -> ()
  | Some receiver ->
      t.waiting_receivers <- t.waiting_receivers - 1;
      receiver.active <- false;
      add_wakeup wakeups (Wake_receiver receiver)

let enqueue_value_locked wakeups (t : ('a, 'err) t) value =
  Stdlib.Queue.add value t.values;
  t.sent <- saturating_succ t.sent;
  wake_one_receiver_locked wakeups t

let rec admit_waiting_senders_locked wakeups (t : ('a, 'err) t) =
  match t.overflow with
  | Unbounded | Drop_new _ -> ()
  | Backpressure _ ->
      if Option.is_none t.closed && capacity_available t then
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
      (fun (receiver : receiver) ->
        if receiver.active then Stdlib.Queue.push receiver live)
      t.receivers;
    Stdlib.Queue.clear t.receivers;
    Stdlib.Queue.iter
      (fun receiver -> Stdlib.Queue.push receiver t.receivers)
      live;
    t.cancelled_receiver_debt <- 0)

let cancel_receiver (t : ('a, 'err) t) (receiver : receiver) =
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

let enqueue_sender contract (t : ('a, 'err) t) value =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let sender =
    { value; contract; resolver; active = true; result = None; notified = false }
  in
  Stdlib.Queue.add sender t.senders;
  t.waiting_senders <- t.waiting_senders + 1;
  (promise, sender)

let try_send_sync t value =
  let wakeups = ref [] in
  let result =
    with_lock t @@ fun () ->
    match t.closed with
    | Some reason -> close_result reason
    | None ->
        if capacity_available t then (
          enqueue_value_locked wakeups t value;
          `Sent)
        else
          match t.overflow with
          | Unbounded ->
              invariant_failed "unbounded queue reported no capacity"
          | Drop_new _ ->
              t.dropped <- saturating_succ t.dropped;
              `Dropped
          | Backpressure _ -> `Full
  in
  resolve_wakeups !wakeups;
  result

let offer_sync contract t value =
  let wakeups = ref [] in
  match
    with_lock t @@ fun () ->
    match t.closed with
    | Some reason -> `Ready (close_result reason)
    | None ->
        if capacity_available t then (
          enqueue_value_locked wakeups t value;
          `Ready `Sent)
        else
          match t.overflow with
          | Unbounded ->
              invariant_failed "unbounded queue reported no capacity"
          | Drop_new _ ->
              t.dropped <- saturating_succ t.dropped;
              `Ready `Dropped
          | Backpressure _ ->
              let promise, sender = enqueue_sender contract t value in
              `Wait (promise, sender)
  with
  | `Ready result ->
      resolve_wakeups !wakeups;
      result
  | `Wait (promise, sender) -> (
      try contract.Runtime_contract.await_promise promise
      with exn
        when Option.is_some
               (contract.Runtime_contract.cancellation_reason exn) ->
        let cancel_wakeups = ref [] in
        let cancellation =
          with_lock_during_cancel contract t (fun () ->
              match sender.result with
              | Some result -> `Settled result
              | None ->
                  cancel_sender cancel_wakeups t sender;
                  `Cancelled)
        in
        resolve_wakeups !cancel_wakeups;
        match cancellation with
        | `Settled result -> result
        | `Cancelled -> raise exn)

let try_send t value = Effect.sync (fun () -> try_send_sync t value)

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
  Effect.sync (fun () -> with_lock t @@ fun () -> t.closed)
  |> Effect.bind (function
       | None -> Effect.unit
       | Some Clean -> Effect.fail `Closed
       | Some (Error error) -> Effect.fail (`Closed_with_error error))

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

let try_recv t =
  Effect.sync @@ fun () ->
  let wakeups = ref [] in
  let result =
    with_lock t @@ fun () ->
    if not (Stdlib.Queue.is_empty t.values) then take_value wakeups t
    else
      match t.closed with
      | None -> `Empty
      | Some reason -> close_result reason
  in
  resolve_wakeups !wakeups;
  result

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

let drain_result_locked wakeups t max =
  let values = drain_locked wakeups t max in
  match values with
  | _ :: _ -> `Items values
  | [] -> (
      match t.closed with
      | None -> `Items []
      | Some reason -> close_result reason)

let drain_with_committed_wakeups t drain =
  let pending_wakeups = ref [] in
  Effect.sync
    (fun () ->
      let wakeups = ref [] in
      let result = with_lock t @@ fun () -> drain wakeups in
      pending_wakeups := List.rev !wakeups;
      resolve_pending_wakeups pending_wakeups;
      result)
  |> Effect.finally
       (Effect.sync (fun () -> resolve_pending_wakeups pending_wakeups))

let drain_result_effect t max =
  drain_with_committed_wakeups t (fun wakeups ->
      drain_result_locked wakeups t max)

let drain_all_result_effect t =
  drain_with_committed_wakeups t (fun wakeups ->
      drain_result_locked wakeups t (Stdlib.Queue.length t.values))

let take_all t =
  drain_all_result_effect t
  |> Effect.bind (function
       | `Items values -> Effect.pure values
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let take_batch t ~max =
  if max <= 0 then invalid_arg "Eta.Queue.take_batch: max must be > 0";
  drain_result_effect t max
  |> Effect.bind (function
       | `Items values -> Effect.pure values
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let enqueue_receiver contract t =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let receiver = { contract; resolver; active = true; notified = false } in
  Stdlib.Queue.add receiver t.receivers;
  t.waiting_receivers <- t.waiting_receivers + 1;
  (promise, receiver)

let recv_sync contract t =
  let rec loop () =
    let wakeups = ref [] in
    match
      with_lock t @@ fun () ->
      if not (Stdlib.Queue.is_empty t.values) then
        `Ready (take_value wakeups t)
      else
        match t.closed with
        | Some reason -> `Ready (close_result reason)
        | None ->
            let promise, receiver = enqueue_receiver contract t in
            `Wait (promise, receiver)
    with
    | `Ready result ->
        resolve_wakeups !wakeups;
        result
    | `Wait (promise, receiver) -> (
        try
          contract.Runtime_contract.await_promise promise;
          loop ()
        with exn
          when Option.is_some
                 (contract.Runtime_contract.cancellation_reason exn) ->
          with_lock_during_cancel contract t (fun () ->
              cancel_receiver t receiver);
          raise exn)
  in
  loop ()

let recv t =
  Effect_erasure.effect_to_public
    (Effect_core.sync_frame (fun frame ->
         recv_sync frame.Effect_core.runtime.Runtime_core.contract t))
  |> Effect.bind (function
       | `Item value -> Effect.pure value
       | `Empty -> invariant_failed "blocking recv returned Empty"
       | `Closed -> Effect.fail `Closed
       | `Closed_with_error error -> Effect.fail (`Closed_with_error error))

let close_with reason t =
  let wakeups = ref [] in
  with_lock t
    (fun () ->
      match t.closed with
      | Some _ -> ()
      | None ->
          t.closed <- Some reason;
          wake_all_senders_locked wakeups t reason;
          wake_all_receivers_locked wakeups t);
  resolve_wakeups !wakeups

let close t = close_with Clean t
let close_with_error t error = close_with (Error error) t

let close_effect t = Effect.sync (fun () -> close t)
let close_with_error_effect t error =
  Effect.sync (fun () -> close_with_error t error)

let stats t =
  with_lock t @@ fun () ->
  {
    depth = Stdlib.Queue.length t.values;
    sent = t.sent;
    received = t.received;
    dropped = t.dropped;
    closed = Option.is_some t.closed;
    waiting_senders = t.waiting_senders;
    waiting_receivers = t.waiting_receivers;
    cancelled_senders = t.cancelled_senders;
    cancelled_receivers = t.cancelled_receivers;
  }
