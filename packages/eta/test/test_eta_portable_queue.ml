open Eta
open Test
open Test_eta_support

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


