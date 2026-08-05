let repeat n f =
  for i = 1 to n do
    f i
  done

let workloads =
  [
    Bench_lib.workload ~ops:100_000 "ppx.runtime.placeholder" (fun () ->
        repeat 100_000 ignore);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
