module C = Blocking_research_common

type queue_policy = Wait | Reject

type config = {
  max_threads : int;
  max_queued : int;
  idle_timeout : float;
  shutdown_timeout : float option;
  queue_policy : queue_policy;
}

type error =
  | Pool_full
  | Pool_shutting_down
  | Cancelled_before_start
  | Worker_raised of exn * Printexc.raw_backtrace

type stats = {
  name : string;
  active_threads : int;
  idle_threads : int;
  queued_jobs : int;
  completed_jobs : int;
  rejected_jobs : int;
  cancelled_before_start : int;
  detached_after_cancel : int;
  peak_active_threads : int;
  peak_queued_jobs : int;
  shutdown : bool;
}

type job_timing = {
  label : string;
  queue_wait_ms : int;
  run_ms : int;
  cancelled_before_start : bool;
  detached_after_cancel : bool;
}

type t = {
  name : string;
  config : config;
  semaphore : Eio.Semaphore.t;
  mutable active : int;
  mutable queued : int;
  mutable completed : int;
  mutable rejected : int;
  mutable cancelled_before_start : int;
  mutable detached_after_cancel : int;
  mutable peak_active : int;
  mutable peak_queued : int;
  mutable shutdown : bool;
  mutable timings : job_timing list;
  mutex : Eio.Mutex.t;
}

let default_config =
  {
    max_threads = min 32 8;
    max_queued = 1024;
    idle_timeout = 30.0;
    shutdown_timeout = Some 5.0;
    queue_policy = Wait;
  }

let validate_config config =
  if config.max_threads <= 0 then invalid_arg "Blocking.Pool.create: max_threads must be > 0";
  if config.max_queued < 0 then invalid_arg "Blocking.Pool.create: max_queued must be >= 0";
  if config.idle_timeout < 0.0 then invalid_arg "Blocking.Pool.create: idle_timeout must be >= 0";
  ()

let create ?(name = "blocking") config =
  validate_config config;
  {
    name;
    config;
    semaphore = Eio.Semaphore.make config.max_threads;
    active = 0;
    queued = 0;
    completed = 0;
    rejected = 0;
    cancelled_before_start = 0;
    detached_after_cancel = 0;
    peak_active = 0;
    peak_queued = 0;
    shutdown = false;
    timings = [];
    mutex = Eio.Mutex.create ();
  }

let snapshot t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  {
    name = t.name;
    active_threads = t.active;
    idle_threads = max 0 (t.config.max_threads - t.active);
    queued_jobs = t.queued;
    completed_jobs = t.completed;
    rejected_jobs = t.rejected;
    cancelled_before_start = t.cancelled_before_start;
    detached_after_cancel = t.detached_after_cancel;
    peak_active_threads = t.peak_active;
    peak_queued_jobs = t.peak_queued;
    shutdown = t.shutdown;
  }

let stats = snapshot

let timings t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () -> List.rev t.timings

let mark_rejected t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.rejected <- t.rejected + 1

let can_enqueue t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  not t.shutdown
  && t.queued < t.config.max_queued

let reserve_queue_slot t =
  let rec wait () =
    Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
    if t.shutdown then Error Pool_shutting_down
    else if t.queued < t.config.max_queued then (
      t.queued <- t.queued + 1;
      t.peak_queued <- max t.peak_queued t.queued;
      Ok ())
    else Error Pool_full
  in
  match t.config.queue_policy with
  | Reject ->
      if can_enqueue t then wait ()
      else (
        mark_rejected t;
        Error Pool_full)
  | Wait ->
      let rec loop () =
        match wait () with
        | Ok () -> Ok ()
        | Error Pool_full ->
            Eio_unix.sleep 0.0005;
            loop ()
        | Error _ as e -> e
      in
      loop ()

let release_queue_slot t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.queued <- max 0 (t.queued - 1)

let mark_started t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.active <- t.active + 1;
  t.peak_active <- max t.peak_active t.active

let mark_finished t timing =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.active <- max 0 (t.active - 1);
  t.completed <- t.completed + 1;
  t.timings <- timing :: t.timings

let mark_cancelled_before_start t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.cancelled_before_start <- t.cancelled_before_start + 1

let mark_detached_after_cancel t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
  t.detached_after_cancel <- t.detached_after_cancel + 1

let submit ?(label = "blocking") ?on_cancel t f input =
  let submitted_at = C.now_ms () in
  match reserve_queue_slot t with
  | Error e -> Error e
  | Ok () -> (
      try
        Eio.Semaphore.acquire t.semaphore;
        release_queue_slot t;
        mark_started t;
        let started_at = C.now_ms () in
        let result =
          try
            Ok
              (Eio_unix.run_in_systhread ~label (fun () ->
                   f input))
          with exn ->
            let bt = Printexc.get_raw_backtrace () in
            Error (Worker_raised (exn, bt))
        in
        let ended_at = C.now_ms () in
        mark_finished t
          {
            label;
            queue_wait_ms = max 0 (started_at - submitted_at);
            run_ms = max 0 (ended_at - started_at);
            cancelled_before_start = false;
            detached_after_cancel = false;
          };
        Eio.Semaphore.release t.semaphore;
        result
      with
      | Eio.Cancel.Cancelled _ ->
          release_queue_slot t;
          mark_cancelled_before_start t;
          Option.iter (fun f -> f ()) on_cancel;
          Error Cancelled_before_start
      | exn ->
          release_queue_slot t;
          let bt = Printexc.get_raw_backtrace () in
          Error (Worker_raised (exn, bt)))

let submit_detached ?(label = "blocking.detached") ~sw t f input =
  mark_detached_after_cancel t;
  Eio.Fiber.fork ~sw (fun () -> ignore (submit ~label t f input : (_, _) result))

let shutdown t =
  Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () -> t.shutdown <- true

let string_of_error = function
  | Pool_full -> "pool_full"
  | Pool_shutting_down -> "pool_shutting_down"
  | Cancelled_before_start -> "cancelled_before_start"
  | Worker_raised (exn, _) -> "worker_raised:" ^ Printexc.to_string exn

let stats_fields (stats : stats) =
  [
    ("pool", stats.name);
    ("active_threads", string_of_int stats.active_threads);
    ("idle_threads", string_of_int stats.idle_threads);
    ("queued_jobs", string_of_int stats.queued_jobs);
    ("completed_jobs", string_of_int stats.completed_jobs);
    ("rejected_jobs", string_of_int stats.rejected_jobs);
    ("cancelled_before_start", string_of_int stats.cancelled_before_start);
    ("detached_after_cancel", string_of_int stats.detached_after_cancel);
    ("peak_active_threads", string_of_int stats.peak_active_threads);
    ("peak_queued_jobs", string_of_int stats.peak_queued_jobs);
    ("shutdown", string_of_bool stats.shutdown);
  ]
