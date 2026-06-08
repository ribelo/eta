open! Portable

type report : immutable_data = {
  cancelled : bool;
  iterations : int;
  latency_us : int;
  checksum : int;
}

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let rec wait_until predicate =
  if predicate () then () else wait_until predicate

let rec burn_without_poll started total i acc =
  if i = total then { cancelled = false; iterations = i; latency_us = 0; checksum = acc }
  else (
    if i = 0 then Atomic.set started true;
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn_without_poll started total (i + 1) acc)

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_sample sample =
  let cancel = Atomic.make false in
  let started = Atomic.make false in
  let cancel_set_us = Atomic.make 0 in
  let total = 80_000_000 + (sample * 4096) in
  let report =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(worker, ()) =
          Parallel.fork_join2 parallel
            (fun _ ->
              let report = burn_without_poll started total 0 (19 + sample) in
              {
                report with
                latency_us = max 0 (now_us () - Atomic.get cancel_set_us);
              })
            (fun _ ->
              wait_until (fun () -> Atomic.get started);
              Atomic.set cancel_set_us (now_us ());
              Atomic.set cancel true)
        in
        worker))
  in
  if not (Atomic.get cancel) then failwith "canceller did not run";
  if report.cancelled then failwith "non-polling thunk reported cancellation";
  report

let () =
  let reports = List.init 3 run_sample in
  let max_latency =
    List.fold_left (fun acc report -> max acc report.latency_us) 0 reports
  in
  if max_latency <= 50_000 then
    failwith "machine was too fast to demonstrate non-preemptible thunk risk";
  Printf.printf
    "candidate=A cooperative_only arbitrary_thunk_preemptible=false samples=%d max_deadline_to_exit_us=%d slo_applies_to_arbitrary_thunk=false\n%!"
    (List.length reports) max_latency

