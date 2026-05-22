open! Portable

type cancel : value mod portable contended = {
  requested : bool Atomic.t;
  requested_us : int Atomic.t;
}

type report : immutable_data = {
  cancelled : bool;
  every : int;
  iterations : int;
  latency_us : int;
  runtime_us : int;
  checksum : int;
}

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let poll cancel =
  if Atomic.get cancel.requested then Some (max 0 (now_us () - Atomic.get cancel.requested_us))
  else None

let rec wait_until predicate =
  if predicate () then () else wait_until predicate

let rec burn_with_poll cancel started polls_seen total every i acc =
  if i = total then
    {
      cancelled = false;
      every;
      iterations = i;
      latency_us = 0;
      runtime_us = 0;
      checksum = acc;
    }
  else (
    if i = 0 then Atomic.set started true;
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    if i > 0 && i mod every = 0 then (
      Atomic.incr polls_seen;
      match poll cancel with
      | Some latency_us ->
          { cancelled = true; every; iterations = i; latency_us; runtime_us = 0; checksum = acc }
      | None -> burn_with_poll cancel started polls_seen total every (i + 1) acc)
    else burn_with_poll cancel started polls_seen total every (i + 1) acc)

let rec burn_uncancelled total every i acc =
  if i = total then acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    let acc = if i > 0 && i mod every = 0 then acc lxor 0x55aa else acc in
    burn_uncancelled total every (i + 1) acc

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_cancel_sample every sample =
  let cancel = { requested = Atomic.make false; requested_us = Atomic.make 0 } in
  let started = Atomic.make false in
  let polls_seen = Atomic.make 0 in
  let started_us = Atomic.make 0 in
  let report =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(worker, ()) =
          Parallel.fork_join2 parallel
            (fun _ ->
              Atomic.set started_us (now_us ());
              burn_with_poll cancel started polls_seen 80_000_000 every 0 (31 + sample))
            (fun _ ->
              wait_until (fun () -> Atomic.get started && Atomic.get polls_seen >= 4);
              Atomic.set cancel.requested_us (now_us ());
              Atomic.set cancel.requested true)
        in
        worker))
  in
  if not report.cancelled then failwith "polling thunk completed instead of cancelling";
  { report with runtime_us = max 0 (now_us () - Atomic.get started_us) }

let measure_uncancelled every =
  let started = now_us () in
  let checksum = burn_uncancelled 12_000_000 every 0 17 in
  (max 0 (now_us () - started), checksum)

let max_latency reports =
  List.fold_left (fun acc report -> max acc report.latency_us) 0 reports

let () =
  let reports_4096 = List.init 5 (fun sample -> run_cancel_sample 4096 sample) in
  let reports_1024 = List.init 5 (fun sample -> run_cancel_sample 1024 sample) in
  let runtime_4096, checksum_4096 = measure_uncancelled 4096 in
  let runtime_1024, checksum_1024 = measure_uncancelled 1024 in
  let max_4096 = max_latency reports_4096 in
  let max_1024 = max_latency reports_1024 in
  if max_4096 > 50_000 then failwith "4096 polling exceeded the timeout-exit SLO";
  if max_1024 > 50_000 then failwith "1024 polling exceeded the timeout-exit SLO";
  Printf.printf
    "candidate=B polling_aware_thunk explicit_poll=true samples=%d max_deadline_to_exit_us_4096=%d max_deadline_to_exit_us_1024=%d uncancelled_runtime_us_4096=%d uncancelled_runtime_us_1024=%d checksum_delta=%d\n%!"
    (List.length reports_4096) max_4096 max_1024 runtime_4096 runtime_1024
    (checksum_4096 lxor checksum_1024)
