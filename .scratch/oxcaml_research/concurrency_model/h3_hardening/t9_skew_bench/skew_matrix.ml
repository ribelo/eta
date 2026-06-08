open! Portable

type shape : immutable_data = Flat | Nested
type policy : immutable_data = Round_robin | Least_loaded | Skew_aware
type task : immutable_data = { id : int; loops : int; seed : int }

type aggregate : immutable_data = {
  count : int;
  checksum : int;
  work : int;
  worker_us : int list;
  latencies_us : int list;
}

let zero = { count = 0; checksum = 0; work = 0; worker_us = []; latencies_us = [] }

let combine left right =
  {
    count = left.count + right.count;
    checksum = left.checksum lxor right.checksum;
    work = left.work + right.work;
    worker_us = left.worker_us @ right.worker_us;
    latencies_us = left.latencies_us @ right.latencies_us;
  }

let rec burn i acc =
  if i <= 0 then acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn (i - 1) acc

let run_task task =
  let checksum = burn task.loops task.seed in
  { zero with count = 1; checksum; work = task.loops; latencies_us = [ task.loops ] }

let run_bucket tasks =
  let start = Unix.gettimeofday () in
  let result = List.fold_left (fun acc task -> combine acc (run_task task)) zero tasks in
  let finish = Unix.gettimeofday () in
  let worker_us = int_of_float ((finish -. start) *. 1_000_000.0) in
  { result with worker_us = [ worker_us ] }

let label_shape = function Flat -> "flat" | Nested -> "nested"
let label_policy = function
  | Round_robin -> "round_robin"
  | Least_loaded -> "least_loaded"
  | Skew_aware -> "skew_aware"

module Bucket = struct
  type t = { items : task list Atomic.t }

  let create () = { items = Atomic.make [] }

  let push t task =
    Atomic.update t.items ~pure_f:(fun bucket -> task :: bucket)

  let items t = List.rev (Atomic.get t.items)
end

type buckets = {
  b0 : Bucket.t;
  b1 : Bucket.t;
  b2 : Bucket.t;
  b3 : Bucket.t;
  b4 : Bucket.t;
  b5 : Bucket.t;
  b6 : Bucket.t;
  b7 : Bucket.t;
}

let create_buckets () =
  {
    b0 = Bucket.create ();
    b1 = Bucket.create ();
    b2 = Bucket.create ();
    b3 = Bucket.create ();
    b4 = Bucket.create ();
    b5 = Bucket.create ();
    b6 = Bucket.create ();
    b7 = Bucket.create ();
  }

let bucket_at buckets = function
  | 0 -> buckets.b0
  | 1 -> buckets.b1
  | 2 -> buckets.b2
  | 3 -> buckets.b3
  | 4 -> buckets.b4
  | 5 -> buckets.b5
  | 6 -> buckets.b6
  | 7 -> buckets.b7
  | _ -> invalid_arg "bucket_at"

let task_count = function Flat -> 36 | Nested -> 48

let make_task ~skew ~shape id =
  let base = match shape with Flat -> 22_000 | Nested -> 18_000 in
  let heavy =
    match shape with
    | Flat -> id < 4
    | Nested -> id < 8 || id mod 17 = 0
  in
  let nested_multiplier = match shape with Flat -> 1 | Nested -> 2 in
  let loops = base * nested_multiplier * (if heavy then skew else 1) in
  { id; loops; seed = 97 + (id * 7919) }

let make_workload ~skew ~shape =
  let count = match shape with Flat -> 36 | Nested -> 48 in
  List.init count (fun id -> make_task ~skew ~shape id)

let min_load_index loads =
  let best = ref 0 in
  for i = 1 to Array.length loads - 1 do
    if loads.(i) < loads.(!best) then best := i
  done;
  !best

let assign ~domains ~policy ~skew ~shape =
  let buckets = create_buckets () in
  let loads = Array.make domains 0 in
  let ids = List.init (task_count shape) Fun.id in
  let ordered_ids =
    match policy with
    | Round_robin | Least_loaded -> ids
    | Skew_aware ->
        List.sort
          (fun a b ->
            compare
              (make_task ~skew ~shape b).loops
              (make_task ~skew ~shape a).loops)
          ids
  in
  List.iteri
    (fun position id ->
      let task = make_task ~skew ~shape id in
      let worker =
        match policy with
        | Round_robin -> position mod domains
        | Least_loaded | Skew_aware -> min_load_index loads
      in
      Bucket.push (bucket_at buckets worker) task;
      loads.(worker) <- loads.(worker) + task.loops)
    ordered_ids;
  buckets

let with_scheduler max_domains f =
  let scheduler = Parallel_scheduler.create ~max_domains () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_parallel domains buckets =
  match domains with
  | 2 ->
      let b0 = buckets.b0 in
      let b1 = buckets.b1 in
      with_scheduler domains (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(a, b) =
            Parallel.fork_join2 parallel
              (fun _ -> run_bucket (Bucket.items b0))
              (fun _ -> run_bucket (Bucket.items b1))
          in
          combine a b))
  | 4 ->
      let b0 = buckets.b0 in
      let b1 = buckets.b1 in
      let b2 = buckets.b2 in
      let b3 = buckets.b3 in
      with_scheduler domains (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(left, right) =
            Parallel.fork_join2 parallel
              (fun p ->
                let #(a, b) =
                  Parallel.fork_join2 p
                    (fun _ -> run_bucket (Bucket.items b0))
                    (fun _ -> run_bucket (Bucket.items b1))
                in
                combine a b)
              (fun p ->
                let #(c, d) =
                  Parallel.fork_join2 p
                    (fun _ -> run_bucket (Bucket.items b2))
                    (fun _ -> run_bucket (Bucket.items b3))
                in
                combine c d)
          in
          combine left right))
  | 8 ->
      let b0 = buckets.b0 in
      let b1 = buckets.b1 in
      let b2 = buckets.b2 in
      let b3 = buckets.b3 in
      let b4 = buckets.b4 in
      let b5 = buckets.b5 in
      let b6 = buckets.b6 in
      let b7 = buckets.b7 in
      with_scheduler domains (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(left, right) =
            Parallel.fork_join2 parallel
              (fun p ->
                let #(a, b) =
                  Parallel.fork_join2 p
                    (fun q ->
                      let #(x, y) =
                        Parallel.fork_join2 q
                          (fun _ -> run_bucket (Bucket.items b0))
                          (fun _ -> run_bucket (Bucket.items b1))
                      in
                      combine x y)
                    (fun q ->
                      let #(x, y) =
                        Parallel.fork_join2 q
                          (fun _ -> run_bucket (Bucket.items b2))
                          (fun _ -> run_bucket (Bucket.items b3))
                      in
                      combine x y)
                in
                combine a b)
              (fun p ->
                let #(c, d) =
                  Parallel.fork_join2 p
                    (fun q ->
                      let #(x, y) =
                        Parallel.fork_join2 q
                          (fun _ -> run_bucket (Bucket.items b4))
                          (fun _ -> run_bucket (Bucket.items b5))
                      in
                      combine x y)
                    (fun q ->
                      let #(x, y) =
                        Parallel.fork_join2 q
                          (fun _ -> run_bucket (Bucket.items b6))
                          (fun _ -> run_bucket (Bucket.items b7))
                      in
                      combine x y)
                in
                combine c d)
          in
          combine left right))
  | _ -> invalid_arg "unsupported domain count"

let measure f =
  Gc.full_major ();
  let start = Unix.gettimeofday () in
  let result = f () in
  let finish = Unix.gettimeofday () in
  (int_of_float ((finish -. start) *. 1_000_000.0), result)

let measure_best attempts f =
  let rec loop remaining best =
    if remaining = 0 then
      match best with
      | Some best -> best
      | None -> invalid_arg "measure_best: attempts must be positive"
    else
      let candidate = measure f in
      let best =
        match best with
        | None -> Some candidate
        | Some (best_us, _) when fst candidate < best_us -> Some candidate
        | Some _ as best -> best
      in
      loop (remaining - 1) best
  in
  loop attempts None

let percentile pct values =
  match List.sort compare values with
  | [] -> 0
  | sorted ->
      let n = List.length sorted in
      let index = min (n - 1) (max 0 ((pct * n) / 100)) in
      List.nth sorted index

let idle_us worker_us =
  match worker_us with
  | [] -> 0
  | _ ->
      let max_worker = List.fold_left max 0 worker_us in
      List.fold_left (fun acc us -> acc + max 0 (max_worker - us)) 0 worker_us

let require_same label expected actual =
  if expected.count <> actual.count || expected.work <> actual.work
     || expected.checksum <> actual.checksum
  then failwith (label ^ " changed workload output")

let policies = [ Round_robin; Least_loaded; Skew_aware ]
let shapes = [ Flat; Nested ]
let skews = [ 1; 2; 4; 8 ]
let domains = [ 2; 4; 8 ]

let () =
  let rr_pathology = ref false in
  let least_loaded_ok = ref true in
  let skew_aware_ok = ref true in
  let policy_totals = Hashtbl.create 3 in
  List.iter
    (fun skew ->
      List.iter
        (fun shape ->
          let tasks = make_workload ~skew ~shape in
          let single_us, single = measure_best 3 (fun () -> run_bucket tasks) in
          List.iter
            (fun domain_count ->
              List.iter
                (fun policy ->
                  let buckets = assign ~domains:domain_count ~policy ~skew ~shape in
                  let wall_us, result =
                    measure_best 3 (fun () -> run_parallel domain_count buckets)
                  in
                  require_same (label_policy policy) single result;
                  let speedup = float_of_int single_us /. float_of_int wall_us in
                  let idle = idle_us result.worker_us in
                  let p95 = percentile 95 result.latencies_us in
                  Hashtbl.replace policy_totals (label_policy policy)
                    (wall_us
                     + Option.value
                         (Hashtbl.find_opt policy_totals (label_policy policy))
                         ~default:0);
                  if
                    policy = Round_robin && shape = Nested && skew > 1
                    && wall_us > (2 * single_us)
                  then rr_pathology := true;
                  if policy = Least_loaded && wall_us > (single_us * 3 / 2) then
                    least_loaded_ok := false;
                  if policy = Skew_aware && wall_us > (single_us * 3 / 2) then
                    skew_aware_ok := false;
                  Printf.printf
                    "matrix skew=%d shape=%s domains=%d policy=%s single_us=%d parallel_us=%d speedup=%.3f idle_us=%d p95_task_work=%d\n%!"
                    skew (label_shape shape) domain_count (label_policy policy)
                    single_us wall_us speedup idle p95)
                policies)
            domains)
        shapes)
    skews;
  let chosen =
    Hashtbl.fold
      (fun policy total acc ->
        match acc with
        | None -> Some (policy, total)
        | Some (_, best_total) when total < best_total -> Some (policy, total)
        | Some _ as acc -> acc)
      policy_totals None
  in
  let chosen_policy = match chosen with Some (policy, _) -> policy | None -> "least_loaded" in
  let h4_reopen = ((not !least_loaded_ok) && (not !skew_aware_ok)) || !rr_pathology in
  let chosen_policy =
    if !least_loaded_ok then "least_loaded"
    else if !skew_aware_ok then "skew_aware"
    else chosen_policy
  in
  Printf.printf
    "verdict chosen_policy=%s h4_reopen=%b round_robin_pathology=%b least_loaded_within_1_5x_single=%b skew_aware_within_1_5x_single=%b\n%!"
    chosen_policy h4_reopen !rr_pathology !least_loaded_ok !skew_aware_ok
