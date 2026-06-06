(** Heartbeat-style fork/join scheduler primitives. *)

(* --------------------------------------------------------------------------- *)
(* Completion channel allocated only for promoted jobs. *)

type exec_state = {
  mutex  : Mutex.t;
  cond   : Condition.t;
  mutable done_  : bool;
}

let make_exec_state () =
  {
    mutex = Mutex.create ();
    cond = Condition.create ();
    done_ = false;
  }

let signal_done (e : exec_state) : unit =
  Mutex.lock e.mutex;
  e.done_ <- true;
  Condition.broadcast e.cond;
  Mutex.unlock e.mutex

let invariant_failed context message =
  failwith
    (Printf.sprintf "Eta.Par.Scheduler.%s: invariant violated: %s" context
       message)

(* --------------------------------------------------------------------------- *)
(* Job state for a join frame. [Reclaimed] means the owner took back a promoted
   job before another worker started it. *)

type job_state =
  | Queued
  | Executing
  | Reclaimed

type owner_join_decision =
  | Run_inline
  | Wait_promoted

type job = {
  mutable state   : job_state;
  mutable handler : worker -> job -> unit;
  mutable prev    : job option;
  mutable next    : job option;
  mutable exec    : exec_state option;
}

and worker = {
  id : int;
  pool : pool;
  mutable job_head : job option;  (* Oldest queued job. *)
  mutable job_tail : job option;  (* Newest queued job. *)
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
  mutable workers : worker option array;
  mutable n_active : int;
  mutable time : int;
  mutable is_stopping : bool;
  heartbeat_interval_ns : int;
}

let active_worker pool context index =
  match pool.workers.(index) with
  | Some worker -> worker
  | None ->
    invariant_failed context
      (Printf.sprintf "missing active worker at index %d" index)

(* --------------------------------------------------------------------------- *)
(* Job-list operations.

   Layout: [job_head] is the oldest queued job and [job_tail] is the newest.
   Both are [None] when the list is empty. *)

let list_push_back (w : worker) (j : job) : unit =
  j.prev <- w.job_tail;
  j.next <- None;
  (match w.job_tail with
   | None -> w.job_head <- Some j
   | Some tail -> tail.next <- Some j);
  w.job_tail <- Some j;
  w.queue_len <- w.queue_len + 1

let list_pop_back (w : worker) (j : job) : unit =
  (match j.prev with
   | None ->
     w.job_head <- None;
     w.job_tail <- None
   | Some prev ->
     prev.next <- None;
     w.job_tail <- Some prev);
  j.prev <- None;
  j.next <- None;
  w.queue_len <- w.queue_len - 1

let reclaim_or_wait_for_job context (w : worker) (j : job) : owner_join_decision =
  let pool = w.pool in
  Mutex.lock pool.mutex;
  let decision =
    match j.state with
    | Queued ->
        (match w.job_tail with
        | Some tail when tail == j -> ()
        | _ -> invariant_failed context "queued job is not the worker tail");
        list_pop_back w j;
        Run_inline
    | Executing -> Wait_promoted
    | Reclaimed -> invariant_failed context "owner observed a reclaimed job"
  in
  Mutex.unlock pool.mutex;
  decision

let list_pop_front_for_promotion (w : worker) : job option =
  match w.job_head with
  | None -> None
  | Some first ->
    w.job_head <- first.next;
    (match first.next with
     | None -> w.job_tail <- None
     | Some next -> next.prev <- None);
    first.state <- Executing;
    first.exec <- Some (make_exec_state ());
    first.prev <- None;
    first.next <- None;
    w.queue_len <- w.queue_len - 1;
    Some first

(* --------------------------------------------------------------------------- *)
(* Worker construction. *)

let make_worker ~pool ~id : worker =
  {
    id;
    pool;
    job_head = None;
    job_tail = None;
    shared_job = None;
    job_time = 0;
    heartbeat = Atomic.make false;
    join_count = 0;
    queue_len = 0;
  }

(* --------------------------------------------------------------------------- *)
(* Pool registration. *)

let register_worker (pool : pool) (w : worker) : unit =
  Mutex.lock pool.mutex;
  let cap = Array.length pool.workers in
  if pool.n_active = cap then begin
    let new_cap = max 4 (cap * 2) in
    let new_arr = Array.make new_cap None in
    Array.blit pool.workers 0 new_arr 0 pool.n_active;
    pool.workers <- new_arr
  end;
  pool.workers.(pool.n_active) <- Some w;
  pool.n_active <- pool.n_active + 1;
  Mutex.unlock pool.mutex

let unregister_worker (pool : pool) (w : worker) : unit =
  Mutex.lock pool.mutex;
  let arr = pool.workers in
  let n = pool.n_active in
  let found = ref (-1) in
  for i = 0 to n - 1 do
    match arr.(i) with
    | Some w' when !found < 0 && w' == w -> found := i
    | _ -> ()
  done;
  if !found >= 0 then begin
    let last = n - 1 in
    if !found <> last then arr.(!found) <- arr.(last);
    arr.(last) <- None;
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
  let n = pool.n_active in
  let best = ref (-1) in
  let best_time = ref max_int in
  for i = 0 to n - 1 do
    let w = active_worker pool "pop_oldest_shared_job" i in
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
    let w = active_worker pool "pop_oldest_shared_job" !best in
    let j = w.shared_job in
    w.shared_job <- None;
    j
  end

(* --------------------------------------------------------------------------- *)
(* Run a stolen job. The handler signals completion when it finishes. *)

let run_promoted_job (w : worker) (j : job) : unit =
  j.handler w j

let signal_job_done (j : job) : unit =
  match j.exec with
  | Some exec -> signal_done exec
  | None -> invariant_failed "signal_job_done" "job has no exec state"

(* --------------------------------------------------------------------------- *)
(* Joiner-side wait for a promoted job.

   Returns [true] when the job ran on some other worker; [false] when the
   joiner reclaimed it before anyone picked it up.

   While waiting, the joiner also runs other shared jobs. This avoids a cycle
   where all workers are blocked waiting for promoted joins. *)

let wait_for_job (w : worker) (j : job) : bool =
  let pool = w.pool in
  Mutex.lock pool.mutex;
  let reclaimed =
    match w.shared_job with
    | Some j' when j' == j -> w.shared_job <- None; true
    | _ -> false
  in
  if reclaimed then begin
    j.state <- Reclaimed;
    Mutex.unlock pool.mutex;
    false
  end else begin
    let exec =
      match j.exec with
      | Some exec -> exec
      | None -> invariant_failed "wait_for_job" "executing job has no exec state"
    in
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
        let w = active_worker pool "drive_heartbeat" idx in
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
