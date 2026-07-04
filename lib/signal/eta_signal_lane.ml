module Runtime_contract = Eta.Runtime_contract
module Effect = Eta.Effect
module Sync_lock = Eta.Sync_lock

type waiter_state =
  | Waiting
  | Granted
  | Cancelled

type access = Access of unit ref

type claim_result =
  | Grant_accepted of access
  | Grant_cancelled

type waiter = {
  contract : Runtime_contract.t;
  resolver : unit Runtime_contract.resolver;
  mutable state : waiter_state;
  mutable notified : bool;
}

type t = {
  lock : Sync_lock.t;
  waiters : waiter Stdlib.Queue.t;
  mutable busy : bool;
  mutable waiting : int;
  mutable cancelled : int;
  mutable cancelled_debt : int;
  mutable owner_fiber_id : int option;
  mutable active_access : access option;
}

type hooks = {
  note_waiter_enqueued : unit -> unit;
  note_waiter_compaction : unit -> unit;
}

let create () =
  {
    lock = Sync_lock.create ();
    waiters = Stdlib.Queue.create ();
    busy = false;
    waiting = 0;
    cancelled = 0;
    cancelled_debt = 0;
    owner_fiber_id = None;
    active_access = None;
  }

let waiting_count lane = lane.waiting
let cancelled_count lane = lane.cancelled

let saturating_succ value =
  if value = max_int then max_int else value + 1

let can_reenter ~lane_depth ~owner_fiber_id ~current_fiber_id =
  lane_depth > 0
  ||
  match owner_fiber_id with
  | Some owner_fiber_id -> owner_fiber_id = current_fiber_id
  | None -> false

let use_lock lane f = Sync_lock.use lane.lock f

let invariant_failed message =
  invalid_arg ("Eta_signal lane invariant failed: " ^ message)

let create_access () = Access (ref ())

let access_matches left right =
  match (left, right) with
  | Access left, Access right -> left == right

let validate_access lane access =
  match lane.active_access with
  | Some active when access_matches active access -> ()
  | Some _ -> invariant_failed "lane access token is not active"
  | None -> invariant_failed "lane access token is stale"

let active_access lane =
  match lane.active_access with
  | Some access -> access
  | None -> invariant_failed "lane access token is stale"

let decrement_cancelled_debt lane =
  if lane.cancelled_debt > 0 then
    lane.cancelled_debt <- lane.cancelled_debt - 1

let rec take_waiting_waiter_locked lane =
  if Stdlib.Queue.is_empty lane.waiters then None
  else
    let waiter = Stdlib.Queue.take lane.waiters in
    match waiter.state with
    | Waiting -> Some waiter
    | Granted -> take_waiting_waiter_locked lane
    | Cancelled ->
        decrement_cancelled_debt lane;
        take_waiting_waiter_locked lane

let should_compact_cancelled ~retained_cancelled ~queue_length =
  if retained_cancelled <= 0 || queue_length <= 0 then false
  else
    let half_rounded_up = (queue_length / 2) + (queue_length mod 2) in
    retained_cancelled >= max 1 half_rounded_up

let compact_cancelled_waiters_locked ~hooks lane =
  if
    should_compact_cancelled ~retained_cancelled:lane.cancelled_debt
      ~queue_length:(Stdlib.Queue.length lane.waiters)
  then (
    let live = Stdlib.Queue.create () in
    Stdlib.Queue.iter
      (fun waiter ->
        match waiter.state with
        | Waiting -> Stdlib.Queue.push waiter live
        | Granted | Cancelled -> ())
      lane.waiters;
    Stdlib.Queue.clear lane.waiters;
    Stdlib.Queue.iter
      (fun waiter -> Stdlib.Queue.push waiter lane.waiters)
      live;
    lane.cancelled_debt <- 0;
    hooks.note_waiter_compaction ())

let add_grant pending waiter = Stdlib.Queue.push waiter pending

let grant_waiter_locked pending waiter =
  waiter.state <- Granted;
  add_grant pending waiter;
  waiter

let resolve_waiter waiter =
  waiter.contract.Runtime_contract.protect (fun () ->
      waiter.contract.Runtime_contract.resolve_promise waiter.resolver ();
      waiter.notified <- true)

let rec resolve_waiter_best_effort remaining waiter =
  try
    resolve_waiter waiter;
    true
  with _exn ->
    waiter.notified
    || (remaining > 0 && resolve_waiter_best_effort (remaining - 1) waiter)

let resolve_pending_grants pending =
  let rec loop () =
    if not (Stdlib.Queue.is_empty pending) then (
      let waiter = Stdlib.Queue.take pending in
      ignore (resolve_waiter_best_effort 1 waiter : bool);
      loop ())
  in
  loop ()

let with_committed_grant lock f =
  let pending_grants = Stdlib.Queue.create () in
  Fun.protect
    ~finally:(fun () -> resolve_pending_grants pending_grants)
    (fun () ->
      let result = lock (fun () -> f pending_grants) in
      resolve_pending_grants pending_grants;
      result)

let release_locked pending_grants lane =
  lane.active_access <- None;
  match take_waiting_waiter_locked lane with
  | Some waiter ->
      lane.waiting <- lane.waiting - 1;
      ignore (grant_waiter_locked pending_grants waiter)
  | None -> lane.busy <- false

let cancel_waiter_locked ~hooks pending_grants lane waiter =
  match waiter.state with
  | Waiting ->
      waiter.state <- Cancelled;
      lane.waiting <- lane.waiting - 1;
      lane.cancelled <- saturating_succ lane.cancelled;
      lane.cancelled_debt <- saturating_succ lane.cancelled_debt;
      compact_cancelled_waiters_locked ~hooks lane
  | Granted ->
      waiter.state <- Cancelled;
      lane.cancelled <- saturating_succ lane.cancelled;
      release_locked pending_grants lane
  | Cancelled -> ()

let claim_waiter_locked waiter =
  match waiter.state with
  | Granted -> Grant_accepted (create_access ())
  | Waiting -> invariant_failed "waiter was not granted"
  | Cancelled -> Grant_cancelled

let use_lock_during_cancel contract lane f =
  contract.Runtime_contract.protect (fun () -> use_lock lane f)

let enqueue_waiter ~hooks contract lane =
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let waiter =
    { contract; resolver; state = Waiting; notified = false }
  in
  Stdlib.Queue.push waiter lane.waiters;
  hooks.note_waiter_enqueued ();
  lane.waiting <- saturating_succ lane.waiting;
  (promise, waiter)

let enter ~hooks contract lane =
  match
    use_lock lane @@ fun () ->
    if lane.busy then
      let promise, waiter = enqueue_waiter ~hooks contract lane in
      `Wait (promise, waiter)
    else (
      let access = create_access () in
      lane.busy <- true;
      lane.active_access <- Some access;
      `Ready access)
  with
  | `Ready access -> access
  | `Wait (promise, waiter) -> (
      let claimed = ref false in
      let access = ref None in
      try
        contract.Runtime_contract.await_promise promise;
        (match
           use_lock_during_cancel contract lane (fun () ->
               match claim_waiter_locked waiter with
               | Grant_accepted granted_access ->
                   claimed := true;
                   access := Some granted_access;
                   lane.active_access <- Some granted_access;
                   Grant_accepted granted_access
               | Grant_cancelled -> Grant_cancelled)
         with
        | Grant_accepted granted_access -> granted_access
        | Grant_cancelled -> contract.Runtime_contract.await_cancel ())
      with exn
        when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
        (if !claimed then
           with_committed_grant
             (fun f -> use_lock_during_cancel contract lane f)
             (fun pending_grants ->
               Option.iter (validate_access lane) !access;
               release_locked pending_grants lane)
         else
           with_committed_grant
             (fun f -> use_lock_during_cancel contract lane f)
             (fun pending_grants ->
                cancel_waiter_locked ~hooks pending_grants lane waiter));
        raise exn)

let leave lane access =
  with_committed_grant (use_lock lane) (fun pending_grants ->
      validate_access lane access;
      release_locked pending_grants lane)

let release_sync lane access_ref =
  match !access_ref with
  | None -> ()
  | Some access ->
    access_ref := None;
    lane.owner_fiber_id <- None;
    leave lane access

let with_sync ~leaf_name ~depth_local ~ensure_context ~hooks ~after_acquired
    lane f =
  Effect.Expert.make ~leaf_name @@ fun context ->
  let contract = Effect.Expert.contract context in
  let lane_depth =
    Option.value (contract.Runtime_contract.local_get depth_local) ~default:0
  in
  let current_fiber_id = contract.Runtime_contract.current_fiber_id () in
  if
    can_reenter ~lane_depth ~owner_fiber_id:lane.owner_fiber_id
      ~current_fiber_id
  then
    try
      ensure_context ();
      let access = active_access lane in
      Effect.Expert.eval context (Effect.sync (fun () -> f access))
    with exn -> Effect.Expert.exit_of_exn context exn
  else
    let access_ref = ref None in
    let release_after_interrupt () =
      contract.Runtime_contract.protect (fun () ->
          release_sync lane access_ref)
    in
    try
      ensure_context ();
      let access = enter ~hooks contract lane in
      access_ref := Some access;
      lane.owner_fiber_id <- Some current_fiber_id;
      let release_lane =
        Effect.sync (fun () -> release_sync lane access_ref)
      in
      contract.Runtime_contract.local_with_binding depth_local 1 (fun () ->
          Effect.Expert.eval context
            (after_acquired ()
            |> Effect.bind (fun () -> Effect.sync (fun () -> f access))
            |> Effect.on_exit (fun _exit -> release_lane)))
    with
    | exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn)
      ->
        release_after_interrupt ();
        raise exn
    | exn ->
        release_after_interrupt ();
        Effect.Expert.exit_of_exn context exn
