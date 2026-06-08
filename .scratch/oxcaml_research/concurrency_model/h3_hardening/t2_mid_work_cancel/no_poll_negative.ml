open! Portable

type report : immutable_data = {
  cancelled : bool;
  iterations : int;
  checksum : int;
}

let rec wait_until predicate =
  if predicate () then () else wait_until predicate

let rec burn_without_poll started total i acc =
  if i = total then { cancelled = false; iterations = i; checksum = acc }
  else (
    if i = 0 then Atomic.set started true;
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn_without_poll started total (i + 1) acc)

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let cancel = Atomic.make false in
  let started = Atomic.make false in
  let report =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(worker, ()) =
          Parallel.fork_join2 parallel
            (fun _ -> burn_without_poll started 900_000 0 23)
            (fun _ ->
              wait_until (fun () -> Atomic.get started);
              Atomic.set cancel true)
        in
        worker))
  in
  if Atomic.get cancel && (not report.cancelled) && report.iterations = 900_000
  then
    Printf.printf
      "detected_no_poll_ignores_cancel iterations=%d checksum=%d\n%!"
      report.iterations report.checksum
  else failwith "negative fixture did not prove polling is load-bearing"

