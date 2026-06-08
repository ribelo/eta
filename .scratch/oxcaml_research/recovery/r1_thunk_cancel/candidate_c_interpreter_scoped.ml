open! Portable

type report : immutable_data = {
  cancelled : bool;
  nodes : int;
  poll_every : int;
  latency_us : int;
  checksum : int;
}

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let rec wait_until predicate =
  if predicate () then () else wait_until predicate

let rec eval_interpreter_loop cancel started polls_seen cancel_set_us total every node acc =
  if node = total then
    { cancelled = false; nodes = node; poll_every = every; latency_us = 0; checksum = acc }
  else (
    if node = 0 then Atomic.set started true;
    let acc = ((acc * 1_664_525) lxor (node * 1_013_904_223)) land 0x3fffffff in
    if node > 0 && node mod every = 0 then (
      Atomic.incr polls_seen;
      if Atomic.get cancel then
        {
          cancelled = true;
          nodes = node;
          poll_every = every;
          latency_us = max 0 (now_us () - Atomic.get cancel_set_us);
          checksum = acc;
        }
      else eval_interpreter_loop cancel started polls_seen cancel_set_us total every
             (node + 1) acc)
    else eval_interpreter_loop cancel started polls_seen cancel_set_us total every
           (node + 1) acc)

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_sample every sample =
  let cancel = Atomic.make false in
  let started = Atomic.make false in
  let polls_seen = Atomic.make 0 in
  let cancel_set_us = Atomic.make 0 in
  let report =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(worker, ()) =
          Parallel.fork_join2 parallel
            (fun _ ->
              eval_interpreter_loop cancel started polls_seen cancel_set_us 80_000_000
                every 0 (43 + sample))
            (fun _ ->
              wait_until (fun () -> Atomic.get started && Atomic.get polls_seen >= 4);
              Atomic.set cancel_set_us (now_us ());
              Atomic.set cancel true)
        in
        worker))
  in
  if not report.cancelled then failwith "interpreter loop completed instead of cancelling";
  report

let () =
  let reports = List.init 5 (fun sample -> run_sample 4096 sample) in
  let max_latency =
    List.fold_left (fun acc report -> max acc report.latency_us) 0 reports
  in
  if max_latency > 50_000 then failwith "interpreter-scoped polling exceeded SLO";
  Printf.printf
    "candidate=C interpreter_scoped arbitrary_thunks_outside_slo=true samples=%d poll_every=%d max_deadline_to_exit_us=%d\n%!"
    (List.length reports) 4096 max_latency
