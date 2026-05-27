let repeat n f =
  for i = 1 to n do
    f i
  done

let workloads =
  [
    {
      Bench_lib.name = "ppx.runtime.placeholder";
      run = (fun () -> repeat 100_000 ignore);
      samples = None;
    };
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
