open! Portable

type task : immutable_data = { id : int; loops : int; seed : int }

type aggregate : immutable_data = {
  count : int;
  checksum : int;
  work : int;
  steals_attempted : int;
  steals_hit : int;
  latencies_us : int list;
}

let zero =
  {
    count = 0;
    checksum = 0;
    work = 0;
    steals_attempted = 0;
    steals_hit = 0;
    latencies_us = [];
  }

let combine left right =
  {
    count = left.count + right.count;
    checksum = left.checksum lxor right.checksum;
    work = left.work + right.work;
    steals_attempted = left.steals_attempted + right.steals_attempted;
    steals_hit = left.steals_hit + right.steals_hit;
    latencies_us = left.latencies_us @ right.latencies_us;
  }

let rec burn i acc =
  if i <= 0
  then acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn (i - 1) acc

let run_task task =
  let start = Unix.gettimeofday () in
  let checksum = burn task.loops task.seed in
  let finish = Unix.gettimeofday () in
  let latency_us = int_of_float ((finish -. start) *. 1_000_000.0) in
  {
    count = 1;
    checksum;
    work = task.loops;
    steals_attempted = 0;
    steals_hit = 0;
    latencies_us = [ latency_us ];
  }

let run_tasks tasks =
  List.fold_left (fun acc task -> combine acc (run_task task)) zero tasks

let make_tasks ~count ~loops =
  List.init count (fun id -> { id; loops; seed = 17 + (id * 7919) })

let split_even tasks =
  let rec loop i left right = function
    | [] -> (List.rev left, List.rev right)
    | task :: rest ->
        if i land 1 = 0
        then loop (i + 1) (task :: left) right rest
        else loop (i + 1) left (task :: right) rest
  in
  loop 0 [] [] tasks

let workload = make_tasks ~count:80 ~loops:450_000
let expected = run_tasks workload

module Portable_queue = struct
  type ('a : immutable_data) t = { items : 'a list Atomic.t }

  let create () = { items = Atomic.make [] }

  let push t item =
    Atomic.update t.items ~pure_f:(fun items -> item :: items)

  let drain t = Atomic.exchange t.items []
end

let with_scheduler max_domains f =
  let scheduler = Parallel_scheduler.create ~max_domains () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let mark_steal_attempt acc =
  { acc with steals_attempted = acc.steals_attempted + 1 }

let mark_steal_hit acc =
  {
    acc with
    steals_attempted = acc.steals_attempted + 1;
    steals_hit = acc.steals_hit + 1;
  }

let rec h2_worker primary peer acc =
  match Portable_ws_deque.steal_opt primary with
  | Some task -> h2_worker primary peer (combine acc (run_task task))
  | None -> (
      let acc = mark_steal_attempt acc in
      match Portable_ws_deque.steal_opt peer with
      | Some task -> h2_worker primary peer (combine (mark_steal_hit acc) (run_task task))
      | None -> acc)

let h2_work_stealing () =
  let left, right = split_even workload in
  let q0 = Portable_ws_deque.of_list left in
  let q1 = Portable_ws_deque.of_list right in
  with_scheduler 2 (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left_result, right_result) =
        Parallel.fork_join2
          parallel
          (fun _ -> h2_worker q0 q1 zero)
          (fun _ -> h2_worker q1 q0 zero)
      in
      combine left_result right_result))

let h3_push () =
  let q0 = Portable_queue.create () in
  let q1 = Portable_queue.create () in
  List.iteri
    (fun i task ->
      if i land 1 = 0 then Portable_queue.push q0 task else Portable_queue.push q1 task)
    workload;
  with_scheduler 2 (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left_result, right_result) =
        Parallel.fork_join2
          parallel
          (fun _ -> run_tasks (Portable_queue.drain q0))
          (fun _ -> run_tasks (Portable_queue.drain q1))
      in
      combine left_result right_result))

let measure label f =
  Gc.full_major ();
  let start = Unix.gettimeofday () in
  let result = f () in
  let finish = Unix.gettimeofday () in
  let ms = (finish -. start) *. 1000.0 in
  let sorted = List.sort compare result.latencies_us in
  let percentile pct =
    match sorted with
    | [] -> 0
    | _ ->
        let n = List.length sorted in
        let index = min (n - 1) (max 0 ((pct * n) / 100)) in
        List.nth sorted index
  in
  Printf.printf
    "%s wall_ms=%.3f count=%d work=%d checksum=%d p50_us=%d p95_us=%d steals_attempted=%d steals_hit=%d\n%!"
    label ms result.count result.work result.checksum (percentile 50)
    (percentile 95) result.steals_attempted result.steals_hit;
  (ms, result)

let require_expected label result =
  if result.count <> expected.count
     || result.work <> expected.work
     || result.checksum <> expected.checksum
  then failwith (label ^ " changed workload output")

let () =
  let h2_ms, h2 = measure "h2_work_stealing" h2_work_stealing in
  let h3_ms, h3 = measure "h3_explicit_push" h3_push in
  require_expected "h2" h2;
  require_expected "h3" h3;
  let ratio = h2_ms /. h3_ms in
  Printf.printf "h2_over_h3_time_ratio=%.3f\n%!" ratio;
  Printf.printf "h2_primitives=ws_deque+atomic_seed_queue+peer_steal\n%!";
  Printf.printf "h3_primitives=portable_atomic_inbox+coordinator_assignment\n%!";
  if ratio < 0.90
  then failwith "H2 has a large throughput win on the H7 workload"
