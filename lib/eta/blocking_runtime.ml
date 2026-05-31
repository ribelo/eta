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

type kind = Systhread | Domain_isolated

type runner = {
  run_in_systhread : 'a. label:string -> (unit -> 'a) -> 'a;
}

let default_runner =
  { run_in_systhread = (fun ~label f -> Eio_unix.run_in_systhread ~label f) }

type t = {
  name : string;
  config : config;
  kind : kind;
  runner : runner;
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
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

exception Callback_raised of exn * Printexc.raw_backtrace
exception Pool_full of string
exception Pool_shutting_down of string
exception Blocking_worker_invariant_violation of string

let eio_context_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let has_eio_fiber_context () =
  try
    ignore (Eio.Fiber.get eio_context_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let mutex_use_rw t f = Eio.Mutex.use_rw ~protect:(has_eio_fiber_context ()) t f

let cancel_protect f =
  if has_eio_fiber_context () then Eio.Cancel.protect f else f ()

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let default_config =
  {
    max_threads = 128;
    max_queued = 64;
    queue_policy = Wait;
    shutdown_policy = Drain;
  }

let validate_config config =
  if config.max_threads <= 0 then
    invalid_arg "Effect.Blocking.Pool.create: max_threads must be > 0";
  if config.max_queued < 0 then
    invalid_arg "Effect.Blocking.Pool.create: max_queued must be >= 0"

let create_with_kind kind ?(runner = default_runner) ?(name = "blocking") config =
  validate_config config;
  {
    name;
    config;
    kind;
    runner;
    mutex = Eio.Mutex.create ();
    condition = Eio.Condition.create ();
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

module Worker_context = struct
  let mutex = Mutex.create ()
  let workers : (int, int) Hashtbl.t = Hashtbl.create 16

  let current_id () = Thread.id (Thread.self ())

  let enter () =
    let id = current_id () in
    Mutex.lock mutex;
    let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
    Hashtbl.replace workers id (count + 1);
    Mutex.unlock mutex;
    id

  let leave id =
    Mutex.lock mutex;
    let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
    if count <= 1 then Hashtbl.remove workers id
    else Hashtbl.replace workers id (count - 1);
    Mutex.unlock mutex

  let run f =
    let id = enter () in
    Fun.protect ~finally:(fun () -> leave id) f

  let active () =
    let id = current_id () in
    Mutex.lock mutex;
    let result = Hashtbl.mem workers id in
    Mutex.unlock mutex;
    result
end

let in_worker = Worker_context.active

let check_not_worker operation =
  if in_worker () then
    raise
      (Blocking_worker_invariant_violation
         (operation
        ^ " must not be called from inside an Effect.Blocking worker callback"))

let name t = t.name

let stats t =
  mutex_use_rw t.mutex @@ fun () ->
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

let raise_pool_full t name emit submitted_at =
  let ts = now_ms () in
  emit_event emit t name submitted_at ts ts Blocking_rejected;
  raise (Pool_full t.name)

let raise_pool_shutting_down t name emit submitted_at =
  let ts = now_ms () in
  emit_event emit t name submitted_at ts ts Blocking_shutdown_rejected;
  raise (Pool_shutting_down t.name)

let rec reserve_slot t name emit submitted_at =
  match
    mutex_use_rw t.mutex @@ fun () ->
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
      | Wait -> `Wait_full
  with
  | `Started job_id -> `Started job_id
  | `Queued -> `Queued
  | `Shutdown -> raise_pool_shutting_down t name emit submitted_at
  | `Reject -> raise_pool_full t name emit submitted_at
  | `Wait_full ->
      Eio.Mutex.lock t.mutex;
      Fun.protect
        ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
        (fun () ->
          while
            (not t.shutdown)
            && t.active >= t.config.max_threads
            && t.queued >= t.config.max_queued
          do
            Eio.Condition.await t.condition t.mutex
          done);
      reserve_slot t name emit submitted_at

let wait_queued_slot t name emit submitted_at =
  try
    let state =
      Eio.Mutex.lock t.mutex;
      Fun.protect
        ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
        (fun () ->
          while
            (not (t.shutdown && t.config.shutdown_policy = Detach_started))
            && t.active >= t.config.max_threads
          do
            Eio.Condition.await t.condition t.mutex
          done;
          if t.shutdown && t.config.shutdown_policy = Detach_started then (
            decr_queued_locked t;
            Eio.Condition.broadcast t.condition;
            `Shutdown)
          else if t.active < t.config.max_threads then (
            decr_queued_locked t;
            t.active <- t.active + 1;
            Eio.Condition.broadcast t.condition;
            let job_id = t.next_job_id in
            t.next_job_id <- t.next_job_id + 1;
            Hashtbl.replace t.active_jobs job_id ();
            `Started job_id)
          else assert false)
    in
    match state with
    | `Started job_id -> job_id
    | `Shutdown -> raise_pool_shutting_down t name emit submitted_at
  with Eio.Cancel.Cancelled _ as exn ->
    let ts = now_ms () in
    mutex_use_rw t.mutex (fun () ->
        decr_queued_locked t;
        t.cancelled_before_start <- t.cancelled_before_start + 1;
        Eio.Condition.broadcast t.condition);
    emit_event emit t name submitted_at ts ts Blocking_cancelled;
    raise exn

let release_started t job_id =
  mutex_use_rw t.mutex @@ fun () ->
  if not (Hashtbl.mem t.active_jobs job_id) then
    invalid_arg "Eta.Blocking.Pool invariant violated: unknown active job";
  decr_active_locked t;
  t.completed <- t.completed + 1;
  Hashtbl.remove t.active_jobs job_id;
  Hashtbl.remove t.detached_jobs job_id;
  Eio.Condition.broadcast t.condition

let mark_detached t job_id =
  mutex_use_rw t.mutex @@ fun () ->
  if
    Hashtbl.mem t.active_jobs job_id
    && not (Hashtbl.mem t.detached_jobs job_id)
  then (
    Hashtbl.replace t.detached_jobs job_id ();
    t.detached <- t.detached + 1);
  Eio.Condition.broadcast t.condition

let run_callback f =
  Worker_context.run @@ fun () ->
  try Packed_ok (Obj.repr (f ())) with exn ->
    Packed_error (exn, Printexc.get_raw_backtrace ())

let run_systhread t name f =
  t.runner.run_in_systhread ~label:name (fun () -> run_callback f)

(* [Domain_isolated] is an opt-in blocking-runtime mode that deliberately
   pays the cost of a fresh domain per job to fully isolate the callback
   from the calling fiber's domain. The OxCaml [do_not_spawn_domains] /
   [unsafe_multidomain] alerts are the right default for application code;
   this primitive is the lower-level escape hatch users opted into via the
   kind=Domain_isolated pool config, so the alerts are suppressed locally.
   [Domain.Safe.spawn] is not used because it would require the callback
   to be portable, which the public Blocking API does not enforce. *)
let run_domain f =
  let finished = Atomic.make false in
  let result = Atomic.make None in
  let domain =
    (Domain.spawn
       [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () ->
        let r = run_callback f in
        Atomic.set result (Some r);
        Atomic.set finished true)
  in
  while not (Atomic.get finished) do
    Eio_unix.sleep 0.001
  done;
  Domain.join domain;
  match Atomic.get result with Some r -> r | None -> assert false

let run_worker t name f =
  match t.kind with
  | Systhread -> run_systhread t name f
  | Domain_isolated -> run_domain f

let finish_result t release name emit submitted_at started_at outcome =
  let ended_at = now_ms () in
  release ();
  match outcome with
  | Packed_ok value ->
      emit_event emit t name submitted_at started_at ended_at Blocking_ok;
      Obj.obj value
  | Packed_error (exn, bt) ->
      emit_event emit t name submitted_at started_at ended_at
        (Blocking_error (Printexc.to_string exn));
      raise (Callback_raised (exn, bt))

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

let run_worker_with_cancel_hook t name f on_cancel =
  match on_cancel with
  | None -> cancel_protect @@ fun () -> run_worker t name f
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
        Eio.Switch.run @@ fun sw ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            (try Eio.Fiber.await_cancel () with
            | Eio.Cancel.Cancelled _ ->
                if Atomic.get running then
                  set_hook_error (run_cancel_hook on_cancel)
            | exn -> set_hook_error (Some (exn, Printexc.get_raw_backtrace ())));
            `Stop_daemon);
        cancel_protect @@ fun () ->
        Fun.protect ~finally:(fun () -> Atomic.set running false) (fun () ->
            run_worker t name f)
      in
      (match Atomic.get hook_error with
      | None -> outcome
      | Some (exn, bt) -> Packed_error (exn, bt))

let submit ~sw ~emit t name ?on_cancel f =
  check_not_worker "Effect.Blocking.submit";
  let submitted_at = now_ms () in
  let job_id =
    try
      match reserve_slot t name emit submitted_at with
      | `Started job_id -> job_id
      | `Queued -> wait_queued_slot t name emit submitted_at
    with Exit -> raise Exit
  in
  let released = ref false in
  let release_once () =
    if not !released then (
      released := true;
      release_started t job_id)
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
      let outcome = run_worker_with_cancel_hook t name f on_cancel in
      finish_result t release_once name emit submitted_at started_at outcome
  | Detach_started ->
      let promise =
        protect_started @@ fun () ->
        Eio.Fiber.fork_promise ~sw (fun () ->
            protect_started @@ fun () ->
            let outcome = run_worker t name f in
            finish_result t release_once name emit submitted_at started_at outcome)
      in
      (try Eio.Promise.await_exn promise with
      | Eio.Cancel.Cancelled _ as exn ->
          let hook_error = run_cancel_hook on_cancel in
          mark_detached t job_id;
          let ts = now_ms () in
          emit_event emit t name submitted_at started_at ts Blocking_detached;
          maybe_raise_cancel_hook_error hook_error;
          raise exn
      | exn ->
          let bt = Printexc.get_raw_backtrace () in
          release_once ();
          Printexc.raise_with_backtrace exn bt)

let shutdown ~emit t =
  let detached =
    mutex_use_rw t.mutex @@ fun () ->
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
    Eio.Condition.broadcast t.condition;
    detached
  in
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
      mutex_use_rw t.mutex @@ fun () ->
      while t.active > 0 || t.queued > 0 do
        Eio.Condition.await t.condition t.mutex
      done

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
    run_in_systhread : 'a. label:string -> (unit -> 'a) -> 'a;
  }

  module type EIO_UNIX = sig
    val run_in_systhread : ?label:string -> (unit -> 'a) -> 'a
  end

  let default_runner = default_runner
  let runner_of_eio_unix (module Host : EIO_UNIX) =
    { run_in_systhread = (fun ~label f -> Host.run_in_systhread ~label f) }

  let create ?name ?runner config = create_with_kind Systhread ?name ?runner config
  let create_domain_isolated ?name config =
    create_with_kind Domain_isolated ?name config

  let stats = stats
end
