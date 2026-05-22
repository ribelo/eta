open! Portable

type task : immutable_data = { id : int; loops : int; seed : int }
type aggregate : immutable_data = { count : int; checksum : int; work : int }

let zero = { count = 0; checksum = 0; work = 0 }

let combine left right =
  {
    count = left.count + right.count;
    checksum = left.checksum lxor right.checksum;
    work = left.work + right.work;
  }

let rec burn i acc =
  if i <= 0
  then acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn (i - 1) acc

let run_task task =
  let checksum = burn task.loops task.seed in
  { count = 1; checksum; work = task.loops }

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

let with_scheduler max_domains f =
  let scheduler = Parallel_scheduler.create ~max_domains () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let h7_tasks = make_tasks ~count:80 ~loops:450_000
let h7_left, h7_right = split_even h7_tasks

let run_two_domain () =
  with_scheduler 2 (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left_result, right_result) =
        Parallel.fork_join2
          parallel
          (fun _ -> run_tasks h7_left)
          (fun _ -> run_tasks h7_right)
      in
      combine left_result right_result))

let measure label f =
  Gc.full_major ();
  let start = Unix.gettimeofday () in
  let result = f () in
  let finish = Unix.gettimeofday () in
  let ms = (finish -. start) *. 1000.0 in
  Printf.printf "%s wall_ms=%.3f count=%d work=%d checksum=%d\n%!"
    label ms result.count result.work result.checksum;
  (ms, result)

let () =
  let single_ms, single = measure "single_domain" (fun () -> run_tasks h7_tasks) in
  let parallel_ms, parallel = measure "two_domain_parallel" run_two_domain in
  if single <> parallel then failwith "parallel result changed workload output";
  let speedup = single_ms /. parallel_ms in
  Printf.printf "h7_speedup=%.3f\n%!" speedup;
  if speedup <= 1.25 then failwith "H7 not disproved by this workload"
