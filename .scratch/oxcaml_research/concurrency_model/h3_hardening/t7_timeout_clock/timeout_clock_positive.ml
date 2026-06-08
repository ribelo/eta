open! Portable

type deadline : immutable_data = {
  monotonic_ns : int64;
  poll_every : int;
}

type outcome : immutable_data =
  | Success of string
  | Failed of string
  | Interrupted of { polls : int; latency_us : int }

let now_ns () = Int64.of_float (Unix.gettimeofday () *. 1_000_000_000.0)
let ns_to_us ns = Int64.to_int (Int64.div ns 1_000L)

let rec burn_until_deadline deadline total i polls acc =
  if i >= total then Success (string_of_int acc)
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    if i > 0 && i mod deadline.poll_every = 0 then
      let now = now_ns () in
      if Int64.compare now deadline.monotonic_ns >= 0 then
        Interrupted
          {
            polls;
            latency_us = max 0 (ns_to_us (Int64.sub now deadline.monotonic_ns));
          }
      else burn_until_deadline deadline total (i + 1) (polls + 1) acc
    else burn_until_deadline deadline total (i + 1) polls acc

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let deadline_after_us us =
  { monotonic_ns = Int64.add (now_ns ()) (Int64.of_int (us * 1_000)); poll_every = 4_096 }

let run_pair left right =
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left, right) = Parallel.fork_join2 parallel left right in
      (left, right)))

let timeout_vs_success () =
  let deadline = deadline_after_us 1_000 in
  run_pair
    (fun _ -> burn_until_deadline deadline 8_000_000 0 0 17)
    (fun _ -> Success "sibling-ok")

let timeout_vs_failure () =
  let deadline = deadline_after_us 1_000 in
  run_pair
    (fun _ -> burn_until_deadline deadline 8_000_000 0 0 23)
    (fun _ -> Failed "sibling-failed")

let timeout_mid_loop () =
  let deadline = deadline_after_us 1_000 in
  run_pair
    (fun _ -> burn_until_deadline deadline 12_000_000 0 0 31)
    (fun _ -> Success "short")

let require_interrupt label = function
  | Interrupted { polls; latency_us }, sibling ->
      if polls > 4_096 then failwith (label ^ ": too many polls");
      (latency_us, sibling)
  | _ -> failwith (label ^ ": expected timeout interrupt")

let () =
  let latency_success, sibling_success = require_interrupt "timeout_vs_success" (timeout_vs_success ()) in
  let latency_failure, sibling_failure = require_interrupt "timeout_vs_failure" (timeout_vs_failure ()) in
  let latency_mid, sibling_mid = require_interrupt "timeout_mid_loop" (timeout_mid_loop ()) in
  if sibling_success <> Success "sibling-ok" then failwith "success sibling changed";
  if sibling_failure <> Failed "sibling-failed" then failwith "failure sibling changed";
  if sibling_mid <> Success "short" then failwith "mid-loop sibling changed";
  let max_latency = max latency_success (max latency_failure latency_mid) in
  Printf.printf
    "timeout_clock_positive payload=int64_ns poll_every=%d max_deadline_to_exit_us=%d sibling_success=true sibling_failure=true mid_loop=true\n%!"
    4096 max_latency

