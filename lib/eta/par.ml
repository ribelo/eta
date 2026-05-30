(* Eta.Par — public API on top of the heartbeat scheduler.

   The public surface is unchanged from the previous Rayon-style
   implementation; only the internals now use heartbeat scheduling
   per the algorithm in the heartbeat paper, mirrored on Spice (Zig)
   and chili (Rust). *)

module S = Par_scheduler

(* --------------------------------------------------------------------------- *)
(* Per-domain "current worker" via DLS.

   Set when a worker thread enters its drive loop, or when the caller
   of [Pool.run] registers itself as a transient worker. *)

(* DLS sentinel only. [current_worker] compares it by physical identity before
   returning; worker entry points overwrite [current_dls] with a real worker
   before any scheduler field is read. *)
let no_worker : S.worker = Obj.magic 0

let current_dls = Domain.DLS.new_key (fun () -> no_worker)

let current_worker () : S.worker =
  let w = Domain.DLS.get current_dls in
  if w == no_worker then
    invalid_arg "Eta.Par: not running inside a pool worker (call Pool.run)";
  w

(* --------------------------------------------------------------------------- *)
(* Pool *)

module Pool = struct
  type t = {
    pool : S.pool;
    domains : unit Domain.t array;
    heartbeat_domain : unit Domain.t;
    background_workers : S.worker array;
  }

  (* Default tick rate: 100 µs is what Spice and chili both use.
     Lower → finer load balancing, higher overhead; higher → coarser. *)
  let default_heartbeat_interval_ns = 100_000

  let default_n_workers () =
    max 1 (Domain.recommended_domain_count ())

  let create ?(n_workers = default_n_workers ())
             ?(heartbeat_interval_ns = default_heartbeat_interval_ns)
             () =
    if n_workers < 1 then
      invalid_arg "Eta.Par.Pool.create: n_workers < 1";
    if heartbeat_interval_ns < 1 then
      invalid_arg "Eta.Par.Pool.create: heartbeat_interval_ns < 1";
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
        Domain.DLS.set current_dls w;
        S.register_worker pool w;
        Fun.protect
          ~finally:(fun () -> S.unregister_worker pool w)
          (fun () -> S.drive_until_shutdown w)))
    in
    let heartbeat_domain =
      Domain.spawn (fun () -> S.drive_heartbeat pool)
    in
    { pool; domains; heartbeat_domain; background_workers }

  let shutdown t =
    S.request_shutdown t.pool;
    Array.iter Domain.join t.domains;
    Domain.join t.heartbeat_domain

  let with_pool ?n_workers ?heartbeat_interval_ns f =
    let t = create ?n_workers ?heartbeat_interval_ns () in
    Fun.protect ~finally:(fun () -> shutdown t) (fun () -> f t)

  (* The caller of [run] becomes a transient worker (id 0) for the
     duration of the call. Other workers are already idle in
     [drive_until_shutdown] waiting for shared jobs. *)
  let run (t : t) (f : unit -> 'a) : 'a =
    let prev_dls = Domain.DLS.get current_dls in
    let w = S.make_worker ~pool:t.pool ~id:0 in
    Domain.DLS.set current_dls w;
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
        let owners =
          Array.init n (fun i -> S.make_worker ~pool:t.pool ~id:(-(i + 1)))
        in
        let make_job i f =
          let handler : S.worker -> S.job -> unit =
            fun w _job ->
              let prev_dls = Domain.DLS.get current_dls in
              Domain.DLS.set current_dls w;
              let result = try Ok (f ()) with exn -> Error exn in
              Domain.DLS.set current_dls prev_dls;
              Mutex.lock mutex;
              results.(i) <- Some result;
              remaining := !remaining - 1;
              if !remaining = 0 then Condition.broadcast cond;
              Mutex.unlock mutex
          in
          {
            S.state = S.Executing;
            handler;
            prev = S.null_job;
            next = S.null_job;
            exec = S.null_exec;
          }
        in
        let job_array = Array.of_list (List.mapi make_job jobs) in
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
            Array.to_list results
            |> List.map (function
                 | Some (Ok value) -> value
                 | Some (Error exn) -> raise exn
                 | None -> assert false))

  let run_on_worker (t : t) (f : unit -> 'a) : 'a =
    match run_many_on_workers t [ f ] with
    | [ value ] -> value
    | _ -> assert false
end

let run ?n_workers ?heartbeat_interval_ns f =
  Pool.with_pool ?n_workers ?heartbeat_interval_ns (fun p -> Pool.run p f)

(* --------------------------------------------------------------------------- *)
(* Heartbeat-aware [join].

   Push a job for [a] onto the worker's cactus stack; on a heartbeat
   tick, promote the OLDEST queued job (potentially [a]'s grandparent
   or higher; not necessarily [a] itself). Run [b] inline. Then:

   - If our [a] was promoted *and* picked up by another worker,
     wait on its [exec_state].
   - Otherwise pop [a] back off the stack and run it inline.

   No per-call atomic on the hot path beyond a relaxed read of
   [w.heartbeat]; no deque, no CAS, no condvar wait unless the job
   was actually shared. *)

let heartbeat_period_mask = 63

(* When the cactus stack is shallower than this, force the slow path
   regardless of [join_count].  Otherwise during the early frames of
   a recursion the heartbeat thread would have nothing to promote.
   Mirrors chili's [self.job_queue.len() < 3]. *)
let min_queue_for_fast_path = 3

(* The slow path of [join] — push a job, run [b], reckon with [a].
   Marked [@inline never] so the fast path can be inlined into
   callers (and the result tuple potentially scalarised) without
   bloating call sites with the cold heartbeat machinery. *)
let[@inline never] join_slow
      (w : S.worker) (a : unit -> 'a) (b : unit -> 'b) : 'a * 'b =
  let r_a : ('a, exn) result ref = ref (Error Exit) in
  let handler : S.worker -> S.job -> unit =
    fun w' j ->
      let prev_dls = Domain.DLS.get current_dls in
      Domain.DLS.set current_dls w';
      r_a := (try Ok (a ()) with e -> Error e);
      Domain.DLS.set current_dls prev_dls;
      S.signal_done j.exec
  in
  let job : S.job = {
    state = Queued;
    handler;
    prev = S.null_job;
    next = S.null_job;
    exec = S.null_exec;
  } in
  S.list_push_back w job;
  if Atomic.get w.heartbeat then S.heartbeat w;
  let rb_or_exn =
    try Either.Right (b ())
    with e -> Either.Left e
  in
  let ra_or_exn : ('a, exn) result =
    match job.state with
    | S.Queued ->
      assert (w.job_tail == job);
      S.list_pop_back w job;
      (try Ok (a ()) with e -> Error e)
    | S.Executing ->
      if S.wait_for_job w job then !r_a
      else (try Ok (a ()) with e -> Error e)
    | S.Reclaimed ->
      assert false
  in
  match ra_or_exn, rb_or_exn with
  | Ok ra, Either.Right rb -> (ra, rb)
  | Error e, _ -> raise e
  | _, Either.Left e -> raise e

(* Same shape as [join_slow] but returns [unit].  Used by the
   internal combinators (par_for, par_map, par_mapi, par_qsort) which
   immediately discard the tuple — avoiding the per-call allocation
   of [(ra, rb)] entirely.  At 16M joins on the tree-sum bench this
   saves ~16 MB of minor-heap traffic. *)
let[@inline never] join_unit_slow
      (w : S.worker) (a : unit -> unit) (b : unit -> unit) : unit =
  let exn_a : exn option ref = ref None in
  let handler : S.worker -> S.job -> unit =
    fun w' j ->
      let prev_dls = Domain.DLS.get current_dls in
      Domain.DLS.set current_dls w';
      (try a () with e -> exn_a := Some e);
      Domain.DLS.set current_dls prev_dls;
      S.signal_done j.exec
  in
  let job : S.job = {
    state = Queued;
    handler;
    prev = S.null_job;
    next = S.null_job;
    exec = S.null_exec;
  } in
  S.list_push_back w job;
  if Atomic.get w.heartbeat then S.heartbeat w;
  let exn_b = try b (); None with e -> Some e in
  (match job.state with
   | S.Queued ->
     assert (w.job_tail == job);
     S.list_pop_back w job;
     (try a () with e -> exn_a := Some e)
   | S.Executing ->
     if S.wait_for_job w job then ()
     else (try a () with e -> exn_a := Some e)
   | S.Reclaimed -> assert false);
  (match !exn_a, exn_b with
   | None, None -> ()
   | Some e, _ | _, Some e -> raise e)

(* Public [join].  Fast path is small enough to inline; slow path is
   marked [@inline never] above so the call site stays compact.

   With [@inline always] flambda2 inlines the fast path into the
   caller; for callers that immediately destructure the tuple
   ([let l, r = join f g in ...]) the [(ra, rb)] allocation can be
   scalarised away entirely.  This is the single biggest fast-path
   win on cheap workloads (e.g. tree_sum, micro_join). *)
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

(* --------------------------------------------------------------------------- *)
(* Tuning knob — historical name kept for compatibility.

   Under heartbeat scheduling the threshold below which combinators
   stop forking and just loop serially is much less critical than
   under eager work-stealing: extra forks are nearly free. We still
   keep a default to bound the recursion depth (and per-frame
   allocation) of the helpers. *)

let par_threshold = ref 1024

(* --------------------------------------------------------------------------- *)
(* par_for, par_iter, par_iteri, par_map, par_mapi, par_reduce.

   All implemented as recursive halving with [join]. Heartbeat
   ensures parallelism happens at the right granularity automatically;
   the [chunk] parameter only sets the leaf size below which we stop
   recursing. *)

let rec par_for_rec ~chunk ~start ~stop f =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do f i done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_for_rec ~chunk ~start ~stop:mid f)
      (fun () -> par_for_rec ~chunk ~start:mid ~stop f)
  end

let par_for ?chunk ~start ~stop f =
  let chunk = match chunk with Some c -> max 1 c | None -> !par_threshold in
  if start >= stop then ()
  else if stop - start <= chunk then
    for i = start to stop - 1 do f i done
  else
    par_for_rec ~chunk ~start ~stop f

let par_iter ?chunk arr f =
  par_for ?chunk ~start:0 ~stop:(Array.length arr) (fun i -> f arr.(i))

let par_iteri ?chunk arr f =
  par_for ?chunk ~start:0 ~stop:(Array.length arr) (fun i -> f i arr.(i))

let rec par_map_rec out (arr : 'a array) (f : 'a -> 'b) ~chunk ~start ~stop =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do out.(i) <- f arr.(i) done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_map_rec out arr f ~chunk ~start ~stop:mid)
      (fun () -> par_map_rec out arr f ~chunk ~start:mid ~stop)
  end

let par_map ?chunk (arr : 'a array) (f : 'a -> 'b) : 'b array =
  let n = Array.length arr in
  if n = 0 then [||]
  else begin
    let out = Array.make n (Obj.magic 0 : 'b) in
    let chunk = match chunk with Some c -> max 1 c | None -> !par_threshold in
    par_map_rec out arr f ~chunk ~start:0 ~stop:n;
    out
  end

let rec par_mapi_rec out (arr : 'a array) (f : int -> 'a -> 'b) ~chunk ~start ~stop =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do out.(i) <- f i arr.(i) done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_mapi_rec out arr f ~chunk ~start ~stop:mid)
      (fun () -> par_mapi_rec out arr f ~chunk ~start:mid ~stop)
  end

let par_mapi ?chunk (arr : 'a array) (f : int -> 'a -> 'b) : 'b array =
  let n = Array.length arr in
  if n = 0 then [||]
  else begin
    let out = Array.make n (Obj.magic 0 : 'b) in
    let chunk = match chunk with Some c -> max 1 c | None -> !par_threshold in
    par_mapi_rec out arr f ~chunk ~start:0 ~stop:n;
    out
  end

let rec par_reduce_rec arr ~chunk ~start ~stop ~init ~map ~combine =
  let len = stop - start in
  if len = 0 then init
  else if len <= chunk then begin
    let acc = ref init in
    for i = start to stop - 1 do
      acc := combine !acc (map arr.(i))
    done;
    !acc
  end
  else begin
    let mid = start + (len / 2) in
    let l, r =
      join
        (fun () -> par_reduce_rec arr ~chunk ~start ~stop:mid ~init ~map ~combine)
        (fun () -> par_reduce_rec arr ~chunk ~start:mid ~stop ~init ~map ~combine)
    in
    combine l r
  end

let par_reduce ?chunk arr ~init ~map ~combine =
  let chunk = match chunk with Some c -> max 1 c | None -> !par_threshold in
  par_reduce_rec arr ~chunk ~start:0 ~stop:(Array.length arr) ~init ~map ~combine

(* --------------------------------------------------------------------------- *)
(* par_sort: parallel quicksort with 3-way (Dutch national flag)
   partitioning.

   The 3-way partition collapses runs of pivot-equal elements into a
   single middle segment, so [par_sort] on an all-equal array
   degenerates to one partition + zero recursion (instead of O(N)
   recursion as Lomuto would). *)

let swap (arr : 'a array) i j =
  if i <> j then begin
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  end

let serial_isort arr cmp lo hi =
  for i = lo + 1 to hi do
    let x = arr.(i) in
    let mutable j = i - 1 in
    while j >= lo && cmp arr.(j) x > 0 do
      arr.(j + 1) <- arr.(j);
      j <- j - 1
    done;
    arr.(j + 1) <- x
  done

let median_of_three arr cmp a b c =
  if cmp arr.(a) arr.(b) < 0 then
    if cmp arr.(b) arr.(c) < 0 then b
    else if cmp arr.(a) arr.(c) < 0 then c
    else a
  else
    if cmp arr.(a) arr.(c) < 0 then a
    else if cmp arr.(b) arr.(c) < 0 then c
    else b

(* Three-way partition. Returns [(lt, gt)] such that:
   - [lo .. lt-1]  : elements < pivot
   - [lt .. gt]    : elements = pivot (no further sorting needed)
   - [gt+1 .. hi]  : elements > pivot *)
let partition3 arr cmp lo hi =
  (* Pivot = median of three; move it to [lo]. *)
  let mid = lo + ((hi - lo) / 2) in
  let p = median_of_three arr cmp lo mid hi in
  swap arr lo p;
  let pivot = arr.(lo) in
  let mutable lt = lo in
  let mutable gt = hi in
  let mutable i = lo + 1 in
  while i <= gt do
    let c = cmp arr.(i) pivot in
    if c < 0 then begin
      swap arr lt i;
      lt <- lt + 1;
      i <- i + 1
    end else if c > 0 then begin
      swap arr i gt;
      gt <- gt - 1
    end else
      i <- i + 1
  done;
  (lt, gt)

let qsort_threshold = 32

let rec par_qsort arr cmp lo hi =
  let len = hi - lo + 1 in
  if len <= qsort_threshold then serial_isort arr cmp lo hi
  else begin
    let lt, gt = partition3 arr cmp lo hi in
    join_unit
      (fun () -> par_qsort arr cmp lo (lt - 1))
      (fun () -> par_qsort arr cmp (gt + 1) hi)
  end

let par_sort arr cmp =
  let n = Array.length arr in
  if n > 1 then par_qsort arr cmp 0 (n - 1)

(* --------------------------------------------------------------------------- *)
(* Lazy parallel iterators (rayon-shaped chains over [join]).                   *)

(* Inlined here, not in a separate [par_iter.ml], because the bridge
   needs to call [join] above and dune's wrapping forbids submodules
   from depending on the library's entry module. *)
module Iter = struct
  type 'a producer = {
    len : int;
    at : int -> 'a;
  }

  type ('a, 'r) consumer = {
    split_at :
      int -> ('a, 'r) consumer * ('a, 'r) consumer * ('r -> 'r -> 'r);
    fold_seq : (int -> 'a) -> start:int -> stop:int -> 'r;
    full : unit -> bool;
  }

  type 'a t = {
    drive : 'r. ('a, 'r) consumer -> 'r;
  }

  (* Default leaf size below which fork-join recursion stops. *)
  let default_chunk = 1024

  let rec bridge : type a r.
      a producer -> (a, r) consumer ->
      chunk:int -> start:int -> stop:int -> r =
   fun p c ~chunk ~start ~stop ->
    if c.full () then
      c.fold_seq p.at ~start ~stop
    else
      let len = stop - start in
      if len <= chunk then
        c.fold_seq p.at ~start ~stop
      else
        let mid = start + (len / 2) in
        let lc, rc, reduce = c.split_at mid in
        let lr, rr =
          join
            (fun () -> bridge p lc ~chunk ~start ~stop:mid)
            (fun () -> bridge p rc ~chunk ~start:mid ~stop)
        in
        reduce lr rr

  (* Constructors. *)

  let of_array ?(chunk = default_chunk) (arr : 'a array) : 'a t =
    let p = { len = Array.length arr; at = Array.unsafe_get arr } in
    { drive = (fun c -> bridge p c ~chunk ~start:0 ~stop:p.len) }

  let of_range ?(chunk = default_chunk) ~start ~stop () : int t =
    if stop < start then invalid_arg "Eta.Par.Iter.of_range: stop < start";
    let len = stop - start in
    let p = { len; at = (fun i -> start + i) } in
    { drive = (fun c -> bridge p c ~chunk ~start:0 ~stop:p.len) }

  let of_array_sub ?(chunk = default_chunk) (arr : 'a array) ~start ~stop : 'a t =
    if start < 0 || stop > Array.length arr || stop < start then
      invalid_arg "Eta.Par.Iter.of_array_sub: bad indices";
    let len = stop - start in
    let p = { len; at = (fun i -> Array.unsafe_get arr (start + i)) } in
    { drive = (fun c -> bridge p c ~chunk ~start:0 ~stop:p.len) }

  (* Adapters. *)

  let map (f : 'a -> 'b) (it : 'a t) : 'b t =
    let drive : type r. ('b, r) consumer -> r =
     fun b_consumer ->
      let rec adapt (b : ('b, r) consumer) : ('a, r) consumer =
        {
          split_at =
            (fun mid ->
              let l, r, red = b.split_at mid in
              (adapt l, adapt r, red));
          fold_seq =
            (fun a_at ~start ~stop ->
              b.fold_seq (fun i -> f (a_at i)) ~start ~stop);
          full = b.full;
        }
      in
      it.drive (adapt b_consumer)
    in
    { drive }

  let mapi (f : int -> 'a -> 'b) (it : 'a t) : 'b t =
    let drive : type r. ('b, r) consumer -> r =
     fun b_consumer ->
      let rec adapt (b : ('b, r) consumer) : ('a, r) consumer =
        {
          split_at =
            (fun mid ->
              let l, r, red = b.split_at mid in
              (adapt l, adapt r, red));
          fold_seq =
            (fun a_at ~start ~stop ->
              b.fold_seq (fun i -> f i (a_at i)) ~start ~stop);
          full = b.full;
        }
      in
      it.drive (adapt b_consumer)
    in
    { drive }

  let filter (p : 'a -> bool) (it : 'a t) : 'a t =
    let drive : type r. ('a, r) consumer -> r =
     fun a_consumer ->
      let rec adapt (b : ('a, r) consumer) : ('a, r) consumer =
        {
          split_at =
            (fun mid ->
              let l, r, red = b.split_at mid in
              (adapt l, adapt r, red));
          fold_seq =
            (fun at ~start ~stop ->
              let n_in = stop - start in
              let kept = Array.make n_in (Obj.magic 0 : 'a) in
              let n = ref 0 in
              for i = start to stop - 1 do
                let x = at i in
                if p x then begin
                  kept.(!n) <- x;
                  incr n
                end
              done;
              b.fold_seq
                (fun i -> Array.unsafe_get kept i)
                ~start:0 ~stop:!n);
          full = b.full;
        }
      in
      it.drive (adapt a_consumer)
    in
    { drive }

  (* Consumers. *)

  let for_each (f : 'a -> unit) (it : 'a t) : unit =
    let rec consumer : ('a, unit) consumer = {
      split_at = (fun _mid -> (consumer, consumer, fun () () -> ()));
      fold_seq =
        (fun at ~start ~stop ->
          for i = start to stop - 1 do f (at i) done);
      full = (fun () -> false);
    } in
    it.drive consumer

  let iter = for_each

  let reduce ~(init : 'a) ~(combine : 'a -> 'a -> 'a) (it : 'a t) : 'a =
    let rec consumer : ('a, 'a) consumer = {
      split_at = (fun _mid -> (consumer, consumer, combine));
      fold_seq =
        (fun at ~start ~stop ->
          let acc = ref init in
          for i = start to stop - 1 do
            acc := combine !acc (at i)
          done;
          !acc);
      full = (fun () -> false);
    } in
    it.drive consumer

  let fold ~(init : 'b) ~(step : 'b -> 'a -> 'b)
      ~(combine : 'b -> 'b -> 'b) (it : 'a t) : 'b =
    let rec consumer : ('a, 'b) consumer = {
      split_at = (fun _mid -> (consumer, consumer, combine));
      fold_seq =
        (fun at ~start ~stop ->
          let acc = ref init in
          for i = start to stop - 1 do
            acc := step !acc (at i)
          done;
          !acc);
      full = (fun () -> false);
    } in
    it.drive consumer

  let sum (it : int t) : int = reduce ~init:0 ~combine:( + ) it

  let count (it : 'a t) : int =
    fold ~init:0 ~step:(fun n _ -> n + 1) ~combine:( + ) it

  let min_with ~(cmp : 'a -> 'a -> int) (it : 'a t) : 'a option =
    let combine a b =
      match a, b with
      | None, x | x, None -> x
      | Some x, Some y -> if cmp x y <= 0 then Some x else Some y
    in
    let rec consumer : ('a, 'a option) consumer = {
      split_at = (fun _mid -> (consumer, consumer, combine));
      fold_seq =
        (fun at ~start ~stop ->
          if start >= stop then None
          else begin
            let best = ref (at start) in
            for i = start + 1 to stop - 1 do
              let x = at i in
              if cmp x !best < 0 then best := x
            done;
            Some !best
          end);
      full = (fun () -> false);
    } in
    it.drive consumer

  let max_with ~cmp it =
    min_with ~cmp:(fun a b -> -(cmp a b)) it

  let min it = min_with ~cmp:compare it
  let max it = max_with ~cmp:compare it

  let collect_array (it : 'a t) : 'a array =
    let rec consumer : ('a, 'a array) consumer = {
      split_at = (fun _mid -> (consumer, consumer, Array.append));
      fold_seq =
        (fun at ~start ~stop ->
          let n = stop - start in
          if n = 0 then [||]
          else begin
            let out = Array.make n (at start) in
            for i = 1 to n - 1 do
              out.(i) <- at (start + i)
            done;
            out
          end);
      full = (fun () -> false);
    } in
    it.drive consumer

  let find_any (p : 'a -> bool) (it : 'a t) : 'a option =
    let found : 'a option Atomic.t = Atomic.make None in
    let is_full () = Atomic.get found <> None in
    let combine a b = match a with Some _ -> a | None -> b in
    let rec consumer : ('a, 'a option) consumer = {
      split_at = (fun _mid -> (consumer, consumer, combine));
      fold_seq =
        (fun at ~start ~stop ->
          let result = ref None in
          let i = ref start in
          while !result = None && !i < stop && Atomic.get found = None do
            let x = at !i in
            if p x then begin
              result := Some x;
              ignore (Atomic.compare_and_set found None (Some x))
            end;
            incr i
          done;
          !result);
      full = is_full;
    } in
    it.drive consumer

  let any (p : 'a -> bool) (it : 'a t) : bool =
    match find_any p it with
    | Some _ -> true
    | None -> false

  let all (p : 'a -> bool) (it : 'a t) : bool =
    not (any (fun x -> not (p x)) it)
end
