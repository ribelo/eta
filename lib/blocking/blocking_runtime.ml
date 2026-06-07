module Runtime_contract = Eta.Runtime_contract
module Sync_lock = Eta.Sync_lock

type queue_policy = Wait | Reject
type shutdown_policy = Drain | Detach_started

type config = {
  max_threads : int;
  max_queued : int;
  queue_policy : queue_policy;
  shutdown_policy : shutdown_policy;
}

type stats = {
  active : int;
  queued : int;
  completed : int;
  rejected : int;
  cancelled_before_start : int;
  detached : int;
}

type outcome =
  | Blocking_ok
  | Blocking_error of string
  | Blocking_cancelled
  | Blocking_rejected
  | Blocking_shutdown_rejected
  | Blocking_detached

type event = {
  pool : string;
  name : string;
  queue_wait_ms : int;
  run_ms : int;
  outcome : outcome;
}

type runner = {
  run_worker : 'a. label:string -> (unit -> 'a) -> 'a;
}

type waiter = {
  resolver : unit Runtime_contract.resolver;
  mutable active : bool;
}

type t = {
  name : string;
  config : config;
  runner : runner option;
  mutex : Sync_lock.t;
  mutable waiters : waiter list;
  mutable active : int;
  mutable queued : int;
  mutable completed : int;
  mutable rejected : int;
  mutable cancelled_before_start : int;
  mutable detached : int;
  mutable next_job_id : int;
  active_jobs : (int, unit) Hashtbl.t;
  detached_jobs : (int, unit) Hashtbl.t;
  mutable shutdown : bool;
}

type packed_result = Packed_ok of Obj.t | Packed_error of exn * Printexc.raw_backtrace

exception Pool_full of string
exception Pool_shutting_down of string
exception Blocking_worker_invariant_violation of string

let default_config =
  {
    max_threads = 128;
    max_queued = 64;
    queue_policy = Wait;
    shutdown_policy = Drain;
  }

let validate_config config =
  if config.max_threads <= 0 then
    invalid_arg "Eta_blocking.Pool.create: max_threads must be > 0";
  if config.max_queued < 0 then
    invalid_arg "Eta_blocking.Pool.create: max_queued must be >= 0"

let create ?runner ?(name = "blocking") config =
  validate_config config;
  {
    name;
    config;
    runner;
    mutex = Sync_lock.create ();
    waiters = [];
    active = 0;
    queued = 0;
    completed = 0;
    rejected = 0;
    cancelled_before_start = 0;
    detached = 0;
    next_job_id = 0;
    active_jobs = Hashtbl.create 16;
    detached_jobs = Hashtbl.create 16;
    shutdown = false;
  }

let compact_waiters_locked t =
  t.waiters <- List.filter (fun (waiter : waiter) -> waiter.active) t.waiters

let wake_waiters_locked t =
  let waiters = t.waiters in
  t.waiters <- [];
  waiters

let resolve_waiters contract waiters =
  List.iter
    (fun (waiter : waiter) ->
      if waiter.active then (
        waiter.active <- false;
        contract.Runtime_contract.resolve_promise waiter.resolver ()))
    waiters

(* Register a waiter while already holding [t.mutex]. Folding the registration
   into the same critical section that observed the unavailable state closes
   the lost-wakeup window: a release that wakes the waiter list cannot slip
   between "observed full" and "registered waiter". *)
let register_waiter_locked contract t =
  compact_waiters_locked t;
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let waiter = { resolver; active = true } in
  t.waiters <- waiter :: t.waiters;
  (promise, waiter)

let await_waiter contract t promise (waiter : waiter) =
  try contract.Runtime_contract.await_promise promise
  with exn
    when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
    contract.Runtime_contract.protect (fun () ->
        Sync_lock.use t.mutex @@ fun () -> waiter.active <- false);
    raise exn

let runner_for t runtime_runner =
  match t.runner with
  | Some runner -> runner
  | None -> (
      match runtime_runner with
      | Some runner -> runner
      | None ->
          invalid_arg
            "Eta_blocking: no blocking runner configured for this pool or runtime")

let check_not_worker ~in_worker operation =
  if in_worker then
    raise
      (Blocking_worker_invariant_violation
         (operation
        ^ " must not be called from inside an Eta_blocking worker callback"))

let name t = t.name

let stats t =
  Sync_lock.use t.mutex @@ fun () ->
  {
    active = t.active;
    queued = t.queued;
    completed = t.completed;
    rejected = t.rejected;
    cancelled_before_start = t.cancelled_before_start;
    detached = t.detached;
  }

let emit_event emit t name submitted_at started_at ended_at outcome =
  emit
    {
      pool = t.name;
      name;
      queue_wait_ms = max 0 (started_at - submitted_at);
      run_ms = max 0 (ended_at - started_at);
      outcome;
    }

let invariant_violation field =
  invalid_arg ("Eta.Blocking.Pool invariant violated: " ^ field ^ " underflow")

let decr_active_locked t =
  if t.active <= 0 then invariant_violation "active";
  t.active <- t.active - 1

let decr_queued_locked t =
  if t.queued <= 0 then invariant_violation "queued";
  t.queued <- t.queued - 1

let raise_pool_full ~now_ms t name emit submitted_at =
  let ts = now_ms () in
  emit_event emit t name submitted_at ts ts Blocking_rejected;
  raise (Pool_full t.name)

let raise_pool_shutting_down ~now_ms t name emit submitted_at =
  let ts = now_ms () in
  emit_event emit t name submitted_at ts ts Blocking_shutdown_rejected;
  raise (Pool_shutting_down t.name)

let rec reserve_slot ~now_ms contract t name emit submitted_at =
  match
    Sync_lock.use t.mutex @@ fun () ->
    if t.shutdown then `Shutdown
    else if t.active < t.config.max_threads then (
      let job_id = t.next_job_id in
      t.next_job_id <- t.next_job_id + 1;
      t.active <- t.active + 1;
      Hashtbl.replace t.active_jobs job_id ();
      `Started job_id)
    else if t.queued < t.config.max_queued then (
      t.queued <- t.queued + 1;
      `Queued)
    else
      match t.config.queue_policy with
      | Reject ->
          t.rejected <- t.rejected + 1;
          `Reject
      | Wait ->
          let promise, waiter = register_waiter_locked contract t in
          `Wait_full (promise, waiter)
  with
  | `Started job_id -> `Started job_id
  | `Queued -> `Queued
  | `Shutdown -> raise_pool_shutting_down ~now_ms t name emit submitted_at
  | `Reject -> raise_pool_full ~now_ms t name emit submitted_at
  | `Wait_full (promise, waiter) ->
      await_waiter contract t promise waiter;
      reserve_slot ~now_ms contract t name emit submitted_at

let wait_queued_slot ~now_ms contract t name emit submitted_at =
  try
    let rec loop () =
      let state =
        Sync_lock.use t.mutex @@ fun () ->
        if t.shutdown && t.config.shutdown_policy = Detach_started then (
          decr_queued_locked t;
          let waiters = wake_waiters_locked t in
          `Shutdown waiters)
        else if t.active < t.config.max_threads then (
          decr_queued_locked t;
          t.active <- t.active + 1;
          let job_id = t.next_job_id in
          t.next_job_id <- t.next_job_id + 1;
          Hashtbl.replace t.active_jobs job_id ();
          let waiters = wake_waiters_locked t in
          `Started (job_id, waiters))
        else
          let promise, waiter = register_waiter_locked contract t in
          `Wait (promise, waiter)
      in
      match state with
      | `Started (job_id, waiters) ->
          resolve_waiters contract waiters;
          job_id
      | `Shutdown waiters ->
          resolve_waiters contract waiters;
          raise_pool_shutting_down ~now_ms t name emit submitted_at
      | `Wait (promise, waiter) ->
          await_waiter contract t promise waiter;
          loop ()
    in
    loop ()
  with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
    let ts = now_ms () in
    let waiters =
      Sync_lock.use t.mutex @@ fun () ->
      decr_queued_locked t;
      t.cancelled_before_start <- t.cancelled_before_start + 1;
      wake_waiters_locked t
    in
    resolve_waiters contract waiters;
    emit_event emit t name submitted_at ts ts Blocking_cancelled;
    raise exn

let release_started contract t job_id =
  let waiters =
    Sync_lock.use t.mutex @@ fun () ->
    if not (Hashtbl.mem t.active_jobs job_id) then
      invalid_arg "Eta.Blocking.Pool invariant violated: unknown active job";
    decr_active_locked t;
    t.completed <- t.completed + 1;
    Hashtbl.remove t.active_jobs job_id;
    Hashtbl.remove t.detached_jobs job_id;
    wake_waiters_locked t
  in
  resolve_waiters contract waiters

let mark_detached contract t job_id =
  let waiters =
    Sync_lock.use t.mutex @@ fun () ->
    if
      Hashtbl.mem t.active_jobs job_id
      && not (Hashtbl.mem t.detached_jobs job_id)
    then (
      Hashtbl.replace t.detached_jobs job_id ();
      t.detached <- t.detached + 1);
    wake_waiters_locked t
  in
  resolve_waiters contract waiters

let run_callback f =
  try Packed_ok (Obj.repr (f ())) with exn ->
    Packed_error (exn, Printexc.get_raw_backtrace ())

let run_worker contract runner t name f =
  let runner = runner_for t runner in
  runner.run_worker ~label:name (fun () ->
      contract.Runtime_contract.with_worker_context (fun () -> run_callback f))

let finish_result ~now_ms t release name emit submitted_at started_at outcome =
  let ended_at = now_ms () in
  release ();
  match outcome with
  | Packed_ok value ->
      emit_event emit t name submitted_at started_at ended_at Blocking_ok;
      Obj.obj value
  | Packed_error (exn, bt) ->
      emit_event emit t name submitted_at started_at ended_at
        (Blocking_error (Printexc.to_string exn));
      Printexc.raise_with_backtrace exn bt

let run_cancel_hook = function
  | None -> None
  | Some hook -> (
      try
        hook ();
        None
      with exn -> Some (exn, Printexc.get_raw_backtrace ()))

let maybe_raise_cancel_hook_error = function
  | None -> ()
  | Some (exn, bt) -> Printexc.raise_with_backtrace exn bt

let run_worker_with_cancel_hook contract runner t name f on_cancel =
  match on_cancel with
  | None ->
      contract.Runtime_contract.protect @@ fun () ->
      run_worker contract runner t name f
  | Some _ ->
      let hook_error = Atomic.make None in
      let running = Atomic.make true in
      let set_hook_error error =
        match error with
        | None -> ()
        | Some _ ->
            let current = Atomic.get hook_error in
            if Option.is_none current then Atomic.set hook_error error
      in
      let outcome =
        contract.Runtime_contract.run_scope @@ fun sw ->
        contract.Runtime_contract.fork_daemon sw (fun () ->
            (try contract.Runtime_contract.await_cancel () with
            | exn
              when Option.is_some
                     (contract.Runtime_contract.cancellation_reason exn) ->
                if Atomic.get running then
                  set_hook_error (run_cancel_hook on_cancel)
            | exn -> set_hook_error (Some (exn, Printexc.get_raw_backtrace ())));
            `Stop_daemon);
        contract.Runtime_contract.protect @@ fun () ->
        Fun.protect ~finally:(fun () -> Atomic.set running false) (fun () ->
            run_worker contract runner t name f)
      in
      (match Atomic.get hook_error with
      | None -> outcome
      | Some (exn, bt) -> Packed_error (exn, bt))

let submit ~scope ~contract ~runner ~emit t name ?on_cancel f =
  check_not_worker ~in_worker:(contract.Runtime_contract.in_worker_context ())
    "Eta_blocking.run";
  let now_ms = contract.Runtime_contract.now_ms in
  let submitted_at = now_ms () in
  let job_id =
    try
      match reserve_slot ~now_ms contract t name emit submitted_at with
      | `Started job_id -> job_id
      | `Queued -> wait_queued_slot ~now_ms contract t name emit submitted_at
    with Exit -> raise Exit
  in
  let released = ref false in
  let release_once () =
    if not !released then (
      released := true;
      release_started contract t job_id)
  in
  let protect_started f =
    try f () with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release_once ();
      Printexc.raise_with_backtrace exn bt
  in
  let started_at = now_ms () in
  match t.config.shutdown_policy with
  | Drain ->
      protect_started @@ fun () ->
      let outcome = run_worker_with_cancel_hook contract runner t name f on_cancel in
      finish_result ~now_ms t release_once name emit submitted_at started_at outcome
  | Detach_started ->
      let promise =
        protect_started @@ fun () ->
        let promise, resolver = contract.Runtime_contract.create_promise () in
        contract.Runtime_contract.fork scope (fun () ->
            try
              let value =
                protect_started @@ fun () ->
                let outcome = run_worker contract runner t name f in
                finish_result ~now_ms t release_once name emit submitted_at started_at
                  outcome
              in
              contract.Runtime_contract.resolve_promise resolver (Ok value)
            with exn ->
              let bt = Printexc.get_raw_backtrace () in
              contract.Runtime_contract.resolve_promise resolver
                (Error (exn, bt)));
        promise
      in
      (try
         match contract.Runtime_contract.await_promise promise with
         | Ok value -> value
         | Error (exn, bt) ->
             release_once ();
             Printexc.raise_with_backtrace exn bt
       with
      | exn
        when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
          let hook_error = run_cancel_hook on_cancel in
          mark_detached contract t job_id;
          let ts = now_ms () in
          emit_event emit t name submitted_at started_at ts Blocking_detached;
          maybe_raise_cancel_hook_error hook_error;
          raise exn
      | exn ->
          let bt = Printexc.get_raw_backtrace () in
          release_once ();
          Printexc.raise_with_backtrace exn bt)

let shutdown ~contract ~emit t =
  let detached, waiters =
    Sync_lock.use t.mutex @@ fun () ->
    t.shutdown <- true;
    let detached =
      match t.config.shutdown_policy with
      | Drain -> 0
      | Detach_started ->
          let count = ref 0 in
          Hashtbl.iter
            (fun job_id () ->
              if not (Hashtbl.mem t.detached_jobs job_id) then (
                incr count;
                Hashtbl.replace t.detached_jobs job_id ()))
            t.active_jobs;
          !count
    in
    t.detached <- t.detached + detached;
    (detached, wake_waiters_locked t)
  in
  resolve_waiters contract waiters;
  if detached > 0 then
    emit
      {
        pool = t.name;
        name = "blocking.shutdown";
        queue_wait_ms = 0;
        run_ms = 0;
        outcome = Blocking_detached;
      };
  match t.config.shutdown_policy with
  | Detach_started -> ()
  | Drain ->
      let rec loop () =
        match
          Sync_lock.use t.mutex @@ fun () ->
          if t.active = 0 && t.queued = 0 then `Done
          else
            let promise, waiter = register_waiter_locked contract t in
            `Wait (promise, waiter)
        with
        | `Done -> ()
        | `Wait (promise, waiter) ->
            await_waiter contract t promise waiter;
            loop ()
      in
      loop ()

module Pool = struct
  type nonrec t = t
  type nonrec queue_policy = queue_policy = Wait | Reject
  type nonrec shutdown_policy = shutdown_policy = Drain | Detach_started

  type nonrec config = config = {
    max_threads : int;
    max_queued : int;
    queue_policy : queue_policy;
    shutdown_policy : shutdown_policy;
  }

  type nonrec stats = stats = {
    active : int;
    queued : int;
    completed : int;
    rejected : int;
    cancelled_before_start : int;
    detached : int;
  }

  type nonrec runner = runner = {
    run_worker : 'a. label:string -> (unit -> 'a) -> 'a;
  }

  let create ?name ?runner config = create ?name ?runner config

  let shutdown_policy t = t.config.shutdown_policy

  let stats = stats
end
