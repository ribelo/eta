open! Portable

type report : immutable_data = {
  cancelled : bool;
  polls : int;
  iterations : int;
  latency_us : int;
  checksum : int;
}

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let rec wait_until predicate =
  if predicate () then () else wait_until predicate

let rec burn_with_poll cancel started polls_seen cancel_set_us total every i acc =
  if i = total then
    {
      cancelled = false;
      polls = Atomic.get polls_seen;
      iterations = i;
      latency_us = 0;
      checksum = acc;
    }
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    if i = 0 then Atomic.set started true;
    if i mod every = 0 && i > 0 then (
      Atomic.incr polls_seen;
      if Atomic.get cancel then
        {
          cancelled = true;
          polls = Atomic.get polls_seen;
          iterations = i;
          latency_us = max 0 (now_us () - Atomic.get cancel_set_us);
          checksum = acc;
        }
      else burn_with_poll cancel started polls_seen cancel_set_us total every
             (i + 1) acc)
    else burn_with_poll cancel started polls_seen cancel_set_us total every
           (i + 1) acc

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_sample sample =
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
              burn_with_poll cancel started polls_seen cancel_set_us
                60_000_000 4_096 0 (17 + sample))
            (fun _ ->
              wait_until (fun () -> Atomic.get started && Atomic.get polls_seen >= 4);
              Atomic.set cancel_set_us (now_us ());
              Atomic.set cancel true)
        in
        worker))
  in
  if not report.cancelled then failwith "worker completed instead of cancelling";
  if report.iterations >= 60_000_000 then failwith "worker cancelled too late";
  if report.polls > 2_048 then failwith "worker exceeded bounded poll budget";
  report

let percentile pct values =
  let sorted = List.sort compare values in
  let n = List.length sorted in
  let index = min (n - 1) (max 0 ((pct * n) / 100)) in
  List.nth sorted index

let () =
  let reports = List.init 7 (fun sample -> run_sample sample) in
  let latencies = List.map (fun report -> report.latency_us) reports in
  let max_polls =
    List.fold_left (fun acc report -> max acc report.polls) 0 reports
  in
  let p95_us = percentile 95 latencies in
  Printf.printf
    "polling_positive samples=%d poll_every_ast_nodes=%d max_polls=%d p95_cancel_latency_us=%d\n%!"
    (List.length reports) 4096 max_polls p95_us
