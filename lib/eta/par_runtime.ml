(* Eta.Par runtime internals on top of the heartbeat scheduler. *)

module S = Par_scheduler

let invariant_failed context message =
  failwith
    (Printf.sprintf "Eta.Par.%s: invariant violated: %s" context message)

(* --------------------------------------------------------------------------- *)
(* Per-domain "current worker" via DLS.

   Set when a worker thread enters its drive loop, or when the caller
   of [Pool.run] registers itself as a transient worker. *)

let default_par_threshold = 1024

type worker_context = {
  worker : S.worker;
  par_threshold : int;
}

let current_dls : worker_context option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let worker_context ~par_threshold worker = { worker; par_threshold }

let promoted_worker_context previous worker =
  let par_threshold =
    match previous with
    | Some context -> context.par_threshold
    | None -> default_par_threshold
  in
  worker_context ~par_threshold worker

let current_worker () : S.worker =
  match Domain.DLS.get current_dls with
  | Some context -> context.worker
  | None ->
    invalid_arg "Eta.Par: not running inside a pool worker (call Pool.run)"

let current_par_threshold () =
  match Domain.DLS.get current_dls with
  | Some context -> context.par_threshold
  | None -> default_par_threshold

let chunk_or_default = function
  | Some chunk -> max 1 chunk
  | None -> current_par_threshold ()

(* --------------------------------------------------------------------------- *)
(* Pool *)

module Pool = struct
  type t = {
    pool : S.pool;
    domains : unit Domain.t array;
    heartbeat_domain : unit Domain.t;
    background_workers : S.worker array;
    par_threshold : int;
  }

  (* Default heartbeat interval. Lower values improve load balancing at the
     cost of more cross-domain wakeups. *)
  let default_heartbeat_interval_ns = 100_000

  let default_n_workers () =
    max 1 (Domain.recommended_domain_count ())

  let create ?(n_workers = default_n_workers ())
             ?(heartbeat_interval_ns = default_heartbeat_interval_ns)
             ?(par_threshold = default_par_threshold)
             () =
    if n_workers < 1 then
      invalid_arg "Eta.Par.Pool.create: n_workers < 1";
    if heartbeat_interval_ns < 1 then
      invalid_arg "Eta.Par.Pool.create: heartbeat_interval_ns < 1";
    if par_threshold < 1 then
      invalid_arg "Eta.Par.Pool.create: par_threshold < 1";
    let pool = S.make_pool ~heartbeat_interval_ns in
    (* Spawn n_workers - 1 background workers. Worker 0 is the caller
       of [run] and is registered transiently in [run]. *)
    let n_bg = n_workers - 1 in
    let background_workers = Array.init n_bg (fun i ->
      S.make_worker ~pool ~id:(i + 1))
    in
    let domains = Array.init n_bg (fun i ->
      let w = background_workers.(i) in
      Domain.spawn (fun () ->
        Printexc.record_backtrace true;
        Domain.DLS.set current_dls
          (Some (worker_context ~par_threshold w));
        S.register_worker pool w;
        Fun.protect
          ~finally:(fun () -> S.unregister_worker pool w)
          (fun () -> S.drive_until_shutdown w)))
    in
    let heartbeat_domain =
      Domain.spawn (fun () -> S.drive_heartbeat pool)
    in
    { pool; domains; heartbeat_domain; background_workers; par_threshold }

  let shutdown t =
    S.request_shutdown t.pool;
    Array.iter Domain.join t.domains;
    Domain.join t.heartbeat_domain

  let with_pool ?n_workers ?heartbeat_interval_ns ?par_threshold (f @ once) =
    let t = create ?n_workers ?heartbeat_interval_ns ?par_threshold () in
    Fun.protect ~finally:(fun () -> shutdown t) (fun () -> f t)

  (* The caller of [run] becomes a transient worker (id 0) for the
     duration of the call. Other workers are already idle in
     [drive_until_shutdown] waiting for shared jobs. *)
  let run (t : t) (f @ once) =
    let prev_dls = Domain.DLS.get current_dls in
    let w = S.make_worker ~pool:t.pool ~id:0 in
    Domain.DLS.set current_dls
      (Some (worker_context ~par_threshold:t.par_threshold w));
    S.register_worker t.pool w;
    let result =
      Fun.protect
        ~finally:(fun () ->
          S.unregister_worker t.pool w;
          Domain.DLS.set current_dls prev_dls)
        (fun () -> f ())
    in
    result

  let run_many_on_workers (t : t) (jobs : (unit -> 'a) list) : 'a list =
    match jobs with
    | [] -> []
    | _ when Array.length t.domains = 0 -> List.map (fun job -> job ()) jobs
    | _ ->
        let n = List.length jobs in
        let mutex = Mutex.create () in
        let cond = Condition.create () in
        let remaining = ref n in
        let results : ('a, exn) result option array = Array.make n None in
        let next = Atomic.make 0 in
        let owner_count = min n (Array.length t.domains) in
        let owners =
          Array.init owner_count (fun i -> S.make_worker ~pool:t.pool ~id:(-(i + 1)))
        in
        let jobs_array = Array.of_list jobs in
        let publish_result i result =
          Mutex.lock mutex;
          results.(i) <- Some result;
          remaining := !remaining - 1;
          if !remaining = 0 then Condition.broadcast cond;
          Mutex.unlock mutex
        in
        let make_job () =
          let handler : S.worker -> S.job -> unit =
            fun w _job ->
              let prev_dls = Domain.DLS.get current_dls in
              Domain.DLS.set current_dls
                (Some (worker_context ~par_threshold:t.par_threshold w));
              Fun.protect
                ~finally:(fun () -> Domain.DLS.set current_dls prev_dls)
                (fun () ->
                  let rec loop () =
                    let i = Atomic.fetch_and_add next 1 in
                    if i < n then (
                      let f = Array.unsafe_get jobs_array i in
                      publish_result i (try Ok (f ()) with exn -> Error exn);
                      loop ())
                  in
                  loop ())
          in
          {
            S.state = S.Executing;
            handler;
            prev = None;
            next = None;
            exec = None;
          }
        in
        let job_array = Array.init owner_count (fun _ -> make_job ()) in
        Array.iter (S.register_worker t.pool) owners;
        Fun.protect
          ~finally:(fun () -> Array.iter (S.unregister_worker t.pool) owners)
          (fun () ->
            Mutex.lock t.pool.mutex;
            Array.iteri
              (fun i (owner : S.worker) ->
                owner.shared_job <- Some job_array.(i);
                owner.job_time <- t.pool.time;
                t.pool.time <- t.pool.time + 1)
              owners;
            Condition.broadcast t.pool.job_ready;
            Mutex.unlock t.pool.mutex;
            Mutex.lock mutex;
            while !remaining > 0 do
              Condition.wait cond mutex
            done;
            Mutex.unlock mutex;
            Array.to_list
              (Array.mapi
                 (fun index -> function
                   | Some (Ok value) -> value
                   | Some (Error exn) -> raise exn
                   | None ->
                     invariant_failed "Pool.run_many_on_workers"
                       (Printf.sprintf "missing result at index %d" index))
                 results))

  let run_on_worker (t : t) (f : unit -> 'a) : 'a =
    match run_many_on_workers t [ f ] with
    | [ value ] -> value
    | values ->
      invariant_failed "Pool.run_on_worker"
        (Printf.sprintf "expected one result, got %d" (List.length values))
end

let run ?n_workers ?heartbeat_interval_ns ?par_threshold (f @ once) =
  Pool.with_pool ?n_workers ?heartbeat_interval_ns ?par_threshold (fun p ->
      Pool.run p f)

(* --------------------------------------------------------------------------- *)
(* [join] queues [a], runs [b] inline, then either waits for [a] if another
   worker claimed it or reclaims and runs [a] inline. *)

let heartbeat_period_mask = 63

(* Shallow queues take the slow path so heartbeat ticks have a job to promote. *)
let min_queue_for_fast_path = 3

(* Cold path for jobs that may be promoted to another worker. *)
let[@inline never] join_slow
      (w : S.worker) (a : unit -> 'a) (b : unit -> 'b) : 'a * 'b =
  let r_a : ('a, exn) result ref = ref (Error Exit) in
  let handler : S.worker -> S.job -> unit =
    fun w' j ->
      let prev_dls = Domain.DLS.get current_dls in
      Domain.DLS.set current_dls (Some (promoted_worker_context prev_dls w'));
      r_a := (try Ok (a ()) with e -> Error e);
      Domain.DLS.set current_dls prev_dls;
      S.signal_job_done j
  in
  let job : S.job = {
    state = Queued;
    handler;
    prev = None;
    next = None;
    exec = None;
  } in
  S.list_push_back w job;
  if Atomic.get w.heartbeat then S.heartbeat w;
  let rb_or_exn =
    try Either.Right (b ())
    with e -> Either.Left e
  in
  let ra_or_exn : ('a, exn) result =
    match S.reclaim_or_wait_for_job "join_slow" w job with
    | S.Run_inline ->
      (try Ok (a ()) with e -> Error e)
    | S.Wait_promoted ->
      if S.wait_for_job w job then !r_a
      else (try Ok (a ()) with e -> Error e)
  in
  match ra_or_exn, rb_or_exn with
  | Ok ra, Either.Right rb -> (ra, rb)
  | Error e, _ -> raise e
  | _, Either.Left e -> raise e

(* Unit-returning variant for internal combinators that discard both results. *)
let[@inline never] join_unit_slow
      (w : S.worker) (a : unit -> unit) (b : unit -> unit) : unit =
  let exn_a : exn option ref = ref None in
  let handler : S.worker -> S.job -> unit =
    fun w' j ->
      let prev_dls = Domain.DLS.get current_dls in
      Domain.DLS.set current_dls (Some (promoted_worker_context prev_dls w'));
      (try a () with e -> exn_a := Some e);
      Domain.DLS.set current_dls prev_dls;
      S.signal_job_done j
  in
  let job : S.job = {
    state = Queued;
    handler;
    prev = None;
    next = None;
    exec = None;
  } in
  S.list_push_back w job;
  if Atomic.get w.heartbeat then S.heartbeat w;
  let exn_b = try b (); None with e -> Some e in
  (match S.reclaim_or_wait_for_job "join_unit_slow" w job with
   | S.Run_inline ->
     (try a () with e -> exn_a := Some e)
   | S.Wait_promoted ->
     if S.wait_for_job w job then ()
     else (try a () with e -> exn_a := Some e));
  (match !exn_a, exn_b with
   | None, None -> ()
   | Some e, _ | _, Some e -> raise e)

(* Sampled fast path: when no promotion is useful, run both branches inline. *)
let[@inline] join (a : unit -> 'a) (b : unit -> 'b) : 'a * 'b =
  let w = current_worker () in
  w.join_count <- w.join_count + 1;
  if w.join_count land heartbeat_period_mask <> 0
     && w.queue_len >= min_queue_for_fast_path
  then begin
    let rb = b () in
    let ra = a () in
    (ra, rb)
  end else
    join_slow w a b

(* Internal unit-returning join for combinators that discard the
   result.  Same hot-path as [join] but no tuple. *)
let[@inline] join_unit (a : unit -> unit) (b : unit -> unit) : unit =
  let w = current_worker () in
  w.join_count <- w.join_count + 1;
  if w.join_count land heartbeat_period_mask <> 0
     && w.queue_len >= min_queue_for_fast_path
  then begin
    b ();
    a ()
  end else
    join_unit_slow w a b

let join3 f g h =
  let a, (b, c) = join f (fun () -> join g h) in
  (a, b, c)
