let sink = ref 0

let checksum_array arr =
  Array.fold_left (fun acc x -> acc + x) 0 arr

let run_pool f =
  Eta.Par.Pool.with_pool ~n_workers:4 (fun pool ->
      sink := Sys.opaque_identity (f pool))

let par_map n =
  let input = Array.init n Fun.id in
  run_pool (fun pool ->
      Eta.Par.Pool.run pool (fun () ->
          Eta.Par.par_map ~chunk:1024 input (fun x -> (x * 17) lxor (x lsl 1))
          |> checksum_array))

let par_reduce n =
  let input = Array.init n (fun i -> i land 1023) in
  run_pool (fun pool ->
      Eta.Par.Pool.run pool (fun () ->
          Eta.Par.par_reduce ~chunk:1024 input ~init:0 ~map:Fun.id ~combine:( + )))

let par_for n =
  let output = Array.make n 0 in
  run_pool (fun pool ->
      Eta.Par.Pool.run pool (fun () ->
          Eta.Par.par_for ~chunk:1024 ~start:0 ~stop:n (fun i ->
              output.(i) <- (i * 31) land 0xffff);
          checksum_array output))

let iter_sum n =
  let input = Array.init n Fun.id in
  run_pool (fun pool ->
      Eta.Par.Pool.run pool (fun () ->
          input |> Eta.Par.Iter.of_array ~chunk:1024 |> Eta.Par.Iter.map (fun x -> x + 1)
          |> Eta.Par.Iter.filter (fun x -> x land 1 = 0)
          |> Eta.Par.Iter.sum))

let workloads =
  let item name run =
    { Bench_lib.name = "par." ^ name; run; samples = None }
  in
  [
    item "par_map.100k" (fun () -> par_map 100_000);
    item "par_reduce.1m" (fun () -> par_reduce 1_000_000);
    item "par_for.100k" (fun () -> par_for 100_000);
    item "iter.map_filter_sum.100k" (fun () -> iter_sum 100_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
