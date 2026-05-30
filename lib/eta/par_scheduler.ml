(** Heartbeat-style fork/join scheduler primitives. *)

(* --------------------------------------------------------------------------- *)
(* Result channel allocated only for promoted jobs. *)

type exec_state = {
  mutex  : Mutex.t;
  cond   : Condition.t;
  mutable done_  : bool;
  (* Result is type-erased by the job harness and unboxed by the joiner. *)
  mutable result : Obj.t;
  mutable exn    : exn option;
}

let make_exec_state () =
  {
    mutex = Mutex.create ();
    cond = Condition.create ();
    done_ = false;
    result = Obj.repr 0;
    exn = None;
  }

let signal_done (e : exec_state) : unit =
  Mutex.lock e.mutex;
  e.done_ <- true;
  Condition.broadcast e.cond;
  Mutex.unlock e.mutex

(* --------------------------------------------------------------------------- *)
(* Job state for a join frame. [Reclaimed] means the owner took back a promoted
   job before another worker started it. *)

type job_state =
  | Queued
  | Executing
  | Reclaimed

type job = {
  mutable state   : job_state;
  mutable handler : worker -> job -> unit;
  mutable prev    : job;
  mutable next    : job;
  mutable exec    : exec_state;
}

and worker = {
  id : int;
  pool : pool;
  job_head : job;                 (* Sentinel. *)
  mutable job_tail : job;         (* Newest queued job. *)
  mutable shared_job : job option;
  (* Promotion timestamp used to pick the oldest shared job. *)
  mutable job_time : int;
  heartbeat : bool Atomic.t;
  (* Slow-path sampler for heartbeat-aware joins. *)
  mutable join_count : int;
  (* Queued jobs on this worker's stack. Shallow stacks force slow-path joins so
     heartbeat ticks have a promotable job. *)
  mutable queue_len : int;
}

and pool = {
  (* Guards worker registry, scheduler time, stop state, and shared jobs. *)
  mutex : Mutex.t;
  job_ready : Condition.t;
  (* Dense live prefix [workers.(0 .. n_active - 1)]. *)
  mutable workers : worker array;
  mutable n_active : int;
  mutable time : int;
  mutable is_stopping : bool;
  heartbeat_interval_ns : int;
}

(* --------------------------------------------------------------------------- *)
(* Sentinels.

   [null_job] is a single self-referential dummy used wherever code
   would otherwise want a [job option]. The end-of-list and "no
   shared job" tests use physical equality with this value. Valid
   code checks [is_null_job] before following [prev]/[next]/[exec];
   live jobs overwrite those fields before linking. *)

let dummy_handler : worker -> job -> unit = fun _ _ -> ()

let null_exec : exec_state =
  { mutex = Mutex.create ();
    cond = Condition.create ();
    done_ = true;
    result = Obj.repr 0;
    exn = None }

let null_job : job =
  let rec j = {
    state = Reclaimed;
    handler = dummy_handler;
    prev = j;
    next = j;
    exec = null_exec;
  } in
  j

let is_null_job (j : job) = j == null_job

(* --------------------------------------------------------------------------- *)
(* Job-list operations.

   Layout: [job_head] is a per-worker sentinel. The list is
   [job_head] → j1 → ... → jn = [job_tail], where → is [next]. The
   list is empty iff [job_tail == job_head]. *)

let list_push_back (w : worker) (j : job) : unit =
  let tail = w.job_tail in
  tail.next <- j;
  j.prev <- tail;
  j.next <- null_job;
  w.job_tail <- j;
  w.queue_len <- w.queue_len + 1

let list_pop_back (w : worker) (j : job) : unit =
  (* Caller asserts [j == w.job_tail] and [j.state = Queued]. *)
  let prev = j.prev in
  prev.next <- null_job;
  w.job_tail <- prev;
  j.prev <- null_job;
  j.next <- null_job;
  w.queue_len <- w.queue_len - 1

(* Pop the OLDEST queued job (head.next). The job transitions to
   [Executing] with a freshly allocated [exec_state]. Returns
   [None] when the list is empty. *)
let list_pop_front_for_promotion (w : worker) : job option =
  let first = w.job_head.next in
  if is_null_job first then None
  else begin
    let next = first.next in
    if is_null_job next then begin
      (* Singleton list: becomes empty. *)
      w.job_head.next <- null_job;
      w.job_tail <- w.job_head
    end else begin
      w.job_head.next <- next;
      next.prev <- w.job_head
    end;
    first.state <- Executing;
    first.exec <- make_exec_state ();
    first.prev <- null_job;
    first.next <- null_job;
    w.queue_len <- w.queue_len - 1;
    Some first
  end

(* --------------------------------------------------------------------------- *)
(* Worker construction. *)

let make_worker_head () : job =
  let rec h = {
    state = Reclaimed;
    handler = dummy_handler;
    prev = h;
    next = null_job;
    exec = null_exec;
  } in
  h

let make_worker ~pool ~id : worker =
  let head = make_worker_head () in
  {
    id;
    pool;
    job_head = head;
    job_tail = head;
    shared_job = None;
    job_time = 0;
    heartbeat = Atomic.make false;
    join_count = 0;
    queue_len = 0;
  }

(* A placeholder used to clear vacated array slots so that the GC
   can collect the worker promptly. Pool scans are bounded by
   [n_active], and [register_worker] overwrites the next active slot
   before incrementing [n_active], so this value is never read as a
   worker. *)
let null_worker : worker = Obj.magic 0

(* --------------------------------------------------------------------------- *)
(* Pool registration. *)

let register_worker (pool : pool) (w : worker) : unit =
  Mutex.lock pool.mutex;
  let cap = Array.length pool.workers in
  if pool.n_active = cap then begin
    let new_cap = max 4 (cap * 2) in
    let new_arr = Array.make new_cap null_worker in
    Array.blit pool.workers 0 new_arr 0 pool.n_active;
    pool.workers <- new_arr
  end;
  pool.workers.(pool.n_active) <- w;
  pool.n_active <- pool.n_active + 1;
  Mutex.unlock pool.mutex

let unregister_worker (pool : pool) (w : worker) : unit =
  Mutex.lock pool.mutex;
  let arr = pool.workers in
  let n = pool.n_active in
  let found = ref (-1) in
  for i = 0 to n - 1 do
    if !found < 0 && arr.(i) == w then found := i
  done;
  if !found >= 0 then begin
    let last = n - 1 in
    if !found <> last then arr.(!found) <- arr.(last);
    arr.(last) <- null_worker;
    pool.n_active <- last
  end;
  w.shared_job <- None;
  Mutex.unlock pool.mutex

(* --------------------------------------------------------------------------- *)
(* Promotion: the cold path of [join]. Caller has just observed
   [w.heartbeat] = true. *)

let[@cold] heartbeat (w : worker) : unit =
  let pool = w.pool in
  Mutex.lock pool.mutex;
  (match w.shared_job with
   | Some _ -> ()  (* already have one waiting to be stolen *)
   | None ->
     match list_pop_front_for_promotion w with
     | None -> ()
     | Some j ->
       w.shared_job <- Some j;
       w.job_time <- pool.time;
       pool.time <- pool.time + 1;
       Condition.signal pool.job_ready);
  Atomic.set w.heartbeat false;
  Mutex.unlock pool.mutex

(* --------------------------------------------------------------------------- *)
(* Stealing.

   Caller MUST hold [pool.mutex]. Scans all workers and removes the
   shared_job with the smallest [job_time]. *)

let pop_oldest_shared_job (pool : pool) : job option =
  let arr = pool.workers in
  let n = pool.n_active in
  let best = ref (-1) in
  let best_time = ref max_int in
  for i = 0 to n - 1 do
    let w = arr.(i) in
    match w.shared_job with
    | None -> ()
    | Some _ ->
      if w.job_time < !best_time then begin
        best := i;
        best_time := w.job_time
      end
  done;
  if !best < 0 then None
  else begin
    let w = arr.(!best) in
    let j = w.shared_job in
    w.shared_job <- None;
    j
  end

(* --------------------------------------------------------------------------- *)
(* Run a stolen job. The handler is responsible for writing the
   result into [j.exec] and calling {!signal_done}. *)

let run_promoted_job (w : worker) (j : job) : unit =
  j.handler w j

(* --------------------------------------------------------------------------- *)
(* Joiner-side wait for a promoted job.

   Returns [true] when the job ran on some other worker (caller
   reads [j.exec]); [false] when the joiner reclaimed it before
   anyone picked it up (caller runs the body inline).

   While we wait, we help by running other workers' shared jobs.
   This is required to avoid deadlock: there is no separate "idle
   worker" pool that could rescue us; if we go to sleep without
   helping, and other workers are also waiting for their joins, no
   progress is made. *)

let wait_for_job (w : worker) (j : job) : bool =
  let pool = w.pool in
  Mutex.lock pool.mutex;
  let reclaimed =
    match w.shared_job with
    | Some j' when j' == j -> w.shared_job <- None; true
    | _ -> false
  in
  if reclaimed then begin
    Mutex.unlock pool.mutex;
    j.state <- Reclaimed;
    false
  end else begin
    let exec = j.exec in
    let helping = ref true in
    while !helping do
      (* Opportunistic done-check: if the executor finished in the
         time we held [pool.mutex], skip helping entirely. *)
      Mutex.lock exec.mutex;
      let already_done = exec.done_ in
      Mutex.unlock exec.mutex;
      if already_done then helping := false
      else
        match pop_oldest_shared_job pool with
        | None -> helping := false
        | Some other_job ->
          Mutex.unlock pool.mutex;
          run_promoted_job w other_job;
          Mutex.lock pool.mutex
    done;
    Mutex.unlock pool.mutex;
    Mutex.lock exec.mutex;
    while not exec.done_ do
      Condition.wait exec.cond exec.mutex
    done;
    Mutex.unlock exec.mutex;
    true
  end

(* --------------------------------------------------------------------------- *)
(* Driver loops. *)

(* Long-lived background workers sit here. They wake on [job_ready]
   and execute one shared job at a time. *)
let drive_until_shutdown (w : worker) : unit =
  let pool = w.pool in
  let stop = ref false in
  while not !stop do
    Mutex.lock pool.mutex;
    if pool.is_stopping then begin
      stop := true;
      Mutex.unlock pool.mutex
    end else begin
      match pop_oldest_shared_job pool with
      | None ->
        Condition.wait pool.job_ready pool.mutex;
        Mutex.unlock pool.mutex
      | Some j ->
        Mutex.unlock pool.mutex;
        run_promoted_job w j
    end
  done

(* Heartbeat thread: round-robin, sleeps [interval/n] between flips. *)
let drive_heartbeat (pool : pool) : unit =
  let i = ref 0 in
  let stop = ref false in
  while not !stop do
    let to_sleep_ns = ref pool.heartbeat_interval_ns in
    Mutex.lock pool.mutex;
    if pool.is_stopping then stop := true
    else begin
      let n = pool.n_active in
      if n > 0 then begin
        let idx = !i mod n in
        let w = pool.workers.(idx) in
        Atomic.set w.heartbeat true;
        i := !i + 1;
        to_sleep_ns :=
          let s = pool.heartbeat_interval_ns / n in
          if s < 1 then 1 else s
      end
    end;
    Mutex.unlock pool.mutex;
    if not !stop then
      Unix.sleepf (float_of_int !to_sleep_ns /. 1.0e9)
  done

(* --------------------------------------------------------------------------- *)
(* Pool construction. *)

let make_pool ~heartbeat_interval_ns : pool =
  {
    mutex = Mutex.create ();
    job_ready = Condition.create ();
    workers = [||];
    n_active = 0;
    time = 0;
    is_stopping = false;
    heartbeat_interval_ns;
  }

let request_shutdown (pool : pool) : unit =
  Mutex.lock pool.mutex;
  pool.is_stopping <- true;
  Condition.broadcast pool.job_ready;
  Mutex.unlock pool.mutex
