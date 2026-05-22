open! Portable

type task : immutable_data = {
  id : int;
  loops : int;
  seed : int;
  fail : bool;
  timeout_after : int;
  span : int;
}

type event : immutable_data = { domain : int; task_id : int; span : int; kind : int }
type portable_cause : immutable_data = { task_id : int; code : int }
type burn_result : immutable_data = Done of int | Cancelled of int

type summary : immutable_data = {
  ok : int;
  failed : int;
  cancelled : int;
  timeout : int;
  checksum : int;
  work : int;
  max_cancel_poll : int;
}

let zero =
  {
    ok = 0;
    failed = 0;
    cancelled = 0;
    timeout = 0;
    checksum = 0;
    work = 0;
    max_cancel_poll = 0;
  }

let combine left right =
  {
    ok = left.ok + right.ok;
    failed = left.failed + right.failed;
    cancelled = left.cancelled + right.cancelled;
    timeout = left.timeout + right.timeout;
    checksum = left.checksum lxor right.checksum;
    work = left.work + right.work;
    max_cancel_poll = max left.max_cancel_poll right.max_cancel_poll;
  }

module Portable_bag = struct
  type ('a : immutable_data) t = { items : 'a list Atomic.t }

  let create () = { items = Atomic.make [] }
  let push t item = Atomic.update t.items ~pure_f:(fun items -> item :: items)
  let drain t = Atomic.exchange t.items []
end

module Portable_inbox = struct
  type ('a : immutable_data) t = {
    items : 'a list Atomic.t;
    count : int Atomic.t;
    capacity : int;
  }

  let create ~capacity = { items = Atomic.make []; count = Atomic.make 0; capacity }

  let push t item =
    Atomic.incr t.count;
    Atomic.update t.items ~pure_f:(fun items -> item :: items)

  let push_bounded t item =
    if Atomic.get t.count >= t.capacity
    then false
    else (
      push t item;
      true)

  let drain t =
    Atomic.set t.count 0;
    Atomic.exchange t.items []
end

let rec burn_until_cancel cancel every i polls acc =
  if Atomic.get cancel
  then Cancelled polls
  else if i <= 0
  then Done acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    let polls = if i mod every = 0 then polls + 1 else polls in
    burn_until_cancel cancel every (i - 1) polls acc

let record_event events domain task kind =
  Portable_bag.push events { domain; task_id = task.id; span = task.span; kind }

let run_task domain cancel events failures task =
  record_event events domain task 0;
  if Atomic.get cancel
  then { zero with cancelled = 1 }
  else if task.fail
  then (
    Atomic.set cancel true;
    Portable_bag.push failures { task_id = task.id; code = 1 };
    record_event events domain task 2;
    { zero with failed = 1 })
  else if task.timeout_after > 0 && task.loops > task.timeout_after
  then (
    Portable_bag.push failures { task_id = task.id; code = 2 };
    record_event events domain task 3;
    { zero with timeout = 1; work = task.timeout_after })
  else
    match burn_until_cancel cancel 10_000 task.loops 0 task.seed with
    | Done checksum ->
        record_event events domain task 1;
        { zero with ok = 1; checksum; work = task.loops }
    | Cancelled polls ->
        record_event events domain task 4;
        { zero with cancelled = 1; max_cancel_poll = polls }

let run_worker domain cancel events failures inbox =
  Portable_inbox.drain inbox
  |> List.fold_left
       (fun acc task -> combine acc (run_task domain cancel events failures task))
       zero

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_two_inboxes q0 q1 =
  let cancel = Atomic.make false in
  let events = Portable_bag.create () in
  let failures = Portable_bag.create () in
  let summary =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2
            parallel
            (fun _ -> run_worker 0 cancel events failures q0)
            (fun _ -> run_worker 1 cancel events failures q1)
        in
        combine left right))
  in
  (summary, Portable_bag.drain events, Portable_bag.drain failures)

let make_ok_task id loops =
  { id; loops; seed = 31 + (id * 8191); fail = false; timeout_after = 0; span = 10_000 + id }

let success_smoke () =
  let q0 = Portable_inbox.create ~capacity:128 in
  let q1 = Portable_inbox.create ~capacity:128 in
  for id = 0 to 31 do
    let task = make_ok_task id 220_000 in
    if id land 1 = 0 then Portable_inbox.push q0 task else Portable_inbox.push q1 task
  done;
  run_two_inboxes q0 q1

let failure_cancel_smoke () =
  let q0 = Portable_inbox.create ~capacity:4 in
  let q1 = Portable_inbox.create ~capacity:4 in
  Portable_inbox.push q0 { (make_ok_task 100 10_000) with fail = true };
  Portable_inbox.push q1 (make_ok_task 101 20_000_000);
  run_two_inboxes q0 q1

let timeout_smoke () =
  let q0 = Portable_inbox.create ~capacity:4 in
  let q1 = Portable_inbox.create ~capacity:4 in
  Portable_inbox.push q0 { (make_ok_task 200 1_000_000) with timeout_after = 100_000 };
  Portable_inbox.push q1 (make_ok_task 201 100_000);
  run_two_inboxes q0 q1

let backpressure_smoke () =
  let q0 = Portable_inbox.create ~capacity:3 in
  let q1 = Portable_inbox.create ~capacity:3 in
  let blocked = Atomic.make 0 in
  for id = 0 to 9 do
    let task = make_ok_task (300 + id) 1_000 in
    let accepted =
      if id land 1 = 0 then Portable_inbox.push_bounded q0 task else Portable_inbox.push_bounded q1 task
    in
    if not accepted then Atomic.incr blocked
  done;
  Atomic.get blocked

let print_summary label summary events failures =
  Printf.printf
    "%s ok=%d failed=%d cancelled=%d timeout=%d work=%d checksum=%d max_cancel_poll=%d events=%d portable_failures=%d\n%!"
    label summary.ok summary.failed summary.cancelled summary.timeout summary.work
    summary.checksum summary.max_cancel_poll (List.length events) (List.length failures)

let () =
  let success, success_events, success_failures = success_smoke () in
  print_summary "h3_runtime_success" success success_events success_failures;
  if success.ok <> 32 || List.length success_events <> 64 || success_failures <> []
  then failwith "success dispatch did not preserve results and observability";

  let failed, failed_events, failed_causes = failure_cancel_smoke () in
  print_summary "h3_failure_cancel" failed failed_events failed_causes;
  if failed.failed <> 1 || failed.cancelled <> 1 || List.length failed_causes <> 1
  then failwith "failure did not aggregate and cancel sibling";

  let timed, timed_events, timed_causes = timeout_smoke () in
  print_summary "h3_timeout" timed timed_events timed_causes;
  if timed.timeout <> 1 || timed.ok <> 1 || List.length timed_causes <> 1
  then failwith "timeout did not stay worker-local and portable";

  let blocked = backpressure_smoke () in
  Printf.printf "h3_backpressure blocked_pushes=%d capacity=3 workers=2\n%!" blocked;
  if blocked = 0 then failwith "bounded inbox did not surface backpressure"

