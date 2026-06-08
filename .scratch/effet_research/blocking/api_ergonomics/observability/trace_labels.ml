module C = Blocking_research_common
module Pool = Blocking_research_pool

let config =
  {
    Pool.max_threads = 2;
    max_queued = 8;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Reject;
  }

let () =
  C.run_eio @@ fun () ->
  let pool = Pool.create ~name:"labels" config in
  ignore (Pool.submit ~label:"pg.query" pool (fun () -> C.sleep_blocking 0.001; 1) ());
  ignore (Pool.submit ~label:"legacy.fs.read" pool (fun () -> C.sleep_blocking 0.001; 2) ());
  ignore (Pool.submit ~label:"aws-sdk.put" pool (fun () -> C.sleep_blocking 0.001; 3) ());
  let labels = Pool.timings pool |> List.map (fun t -> t.Pool.label) |> String.concat "," in
  C.print_summary "trace_labels" [ ("verdict", "ok"); ("labels", labels) ]

