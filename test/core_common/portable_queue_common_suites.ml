open Eta

let check_push label expected actual =
  match (expected, actual) with
  | Portable_queue.Pushed, Portable_queue.Pushed
  | Portable_queue.Full, Portable_queue.Full
  | Portable_queue.Closed, Portable_queue.Closed ->
      ()
  | _ -> Alcotest.failf "%s: unexpected push result" label

let check_take_int label expected actual =
  match (expected, actual) with
  | Some expected, Portable_queue.Value actual ->
      Alcotest.(check int) label expected actual
  | None, Portable_queue.Empty | None, Portable_queue.Closed_empty -> ()
  | _ -> Alcotest.failf "%s: unexpected take result" label

let test_portable_queue_backpressure_and_close () =
  let queue = Portable_queue.create ~capacity:2 in
  check_push "push 1" Portable_queue.Pushed (Portable_queue.try_push queue 1);
  check_push "push 2" Portable_queue.Pushed (Portable_queue.try_push queue 2);
  check_push "full" Portable_queue.Full (Portable_queue.try_push queue 3);
  check_take_int "take 1" (Some 1) (Portable_queue.try_take queue);
  check_push "push after take" Portable_queue.Pushed
    (Portable_queue.try_push queue 3);
  check_take_int "take 2" (Some 2) (Portable_queue.try_take queue);
  Portable_queue.close queue;
  check_push "push after close" Portable_queue.Closed
    (Portable_queue.try_push queue 4);
  check_take_int "take 3" (Some 3) (Portable_queue.try_take queue);
  match Portable_queue.try_take queue with
  | Portable_queue.Closed_empty -> ()
  | _ -> Alcotest.fail "expected closed empty queue"

let test_portable_queue_no_false_empty_under_contention () =
  let queue = Portable_queue.create ~capacity:4 in
  let total_items = 100_000 in
  let false_empties = Atomic.make 0 in
  let produced = Atomic.make 0 in
  let consumed = Atomic.make 0 in
  let done_producing = Atomic.make false in
  let producer =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () ->
        for i = 1 to total_items do
          let rec push () =
            match Portable_queue.try_push queue i with
            | Portable_queue.Pushed -> Atomic.incr produced
            | Portable_queue.Full ->
                Domain.cpu_relax ();
                push ()
            | Portable_queue.Closed -> ()
          in
          push ()
        done;
        Atomic.set done_producing true)
  in
  let rec consume consumed_count =
    let produced_before = Atomic.get produced in
    match Portable_queue.try_take queue with
    | Portable_queue.Value _ ->
        Atomic.incr consumed;
        consume (consumed_count + 1)
    | Portable_queue.Empty ->
        if Atomic.get done_producing && Atomic.get produced = consumed_count
        then consumed_count
        else if produced_before > consumed_count then (
          Atomic.incr false_empties;
          Domain.cpu_relax ();
          consume consumed_count)
        else (
          Domain.cpu_relax ();
          consume consumed_count)
    | Portable_queue.Closed_empty -> consumed_count
  in
  let consumed_count = consume 0 in
  Domain.join producer;
  let rec drain consumed_count =
    match Portable_queue.try_take queue with
    | Portable_queue.Value _ ->
        Atomic.incr consumed;
        drain (consumed_count + 1)
    | _ -> consumed_count
  in
  let consumed_count = drain consumed_count in
  Alcotest.(check int) "all items consumed" total_items consumed_count;
  Alcotest.(check bool)
    (Printf.sprintf
       "try_take should never return false Empty (got %d false empties)"
       (Atomic.get false_empties))
    true (Atomic.get false_empties = 0)

let tests =
  [
    ( "Portable_queue",
      [
        Alcotest.test_case "backpressure and close" `Quick
          test_portable_queue_backpressure_and_close;
        Alcotest.test_case "no false empty under contention" `Quick
          test_portable_queue_no_false_empty_under_contention;
      ] );
  ]
