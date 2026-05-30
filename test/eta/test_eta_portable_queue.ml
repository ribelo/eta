open Eta
open Eta_test
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

(* P1: Portable_queue returns false Empty under contention.
   When a producer has CAS'd tail but hasn't written the slot yet,
   try_take sees head < tail but slot = None, and incorrectly returns Empty.
   This test spawns a producer domain that pushes items with deliberate
   scheduling pressure, and a consumer that detects false Empty results
   (Empty when items are known to be in-flight). *)

let test_portable_queue_no_false_empty_under_contention () =
  (* Use a small capacity to maximize contention on slots *)
  let queue = Portable_queue.create ~capacity:4 in
  let total_items = 100_000 in
  let false_empties = Atomic.make 0 in
  let produced = Atomic.make 0 in
  let consumed = Atomic.make 0 in
  let done_producing = Atomic.make false in
  (* Producer domain: push items as fast as possible *)
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
  (* Consumer: take items. Track false empties:
     An Empty result when we KNOW items should still be available
     (produced > consumed and not done) indicates the bug. *)
  let rec consume () =
    match Portable_queue.try_take queue with
    | Portable_queue.Value _ ->
        Atomic.incr consumed;
        consume ()
    | Portable_queue.Empty ->
        if Atomic.get done_producing && Atomic.get produced = Atomic.get consumed
        then () (* Truly empty after all production is done *)
        else if Atomic.get produced > Atomic.get consumed then (
          (* Producer has pushed more than we consumed, but we got Empty.
             This is the bug: tail was incremented but slot not yet written. *)
          Atomic.incr false_empties;
          Domain.cpu_relax ();
          consume ())
        else (
          Domain.cpu_relax ();
          consume ())
    | Portable_queue.Closed_empty -> ()
  in
  consume ();
  Domain.join producer;
  (* Drain any remaining items after producer is done *)
  let rec drain () =
    match Portable_queue.try_take queue with
    | Portable_queue.Value _ ->
        Atomic.incr consumed;
        drain ()
    | _ -> ()
  in
  drain ();
  (* All items must be consumed *)
  Alcotest.(check int) "all items consumed" total_items (Atomic.get consumed);
  (* The key assertion: a correct MPSC queue should NEVER return Empty
     when items are in-flight (produced > consumed). False empties indicate
     the consumer saw a partially-committed push (tail incremented, slot
     not yet written). *)
  Alcotest.(check bool)
    (Printf.sprintf
       "try_take should never return false Empty (got %d false empties)"
       (Atomic.get false_empties))
    true (Atomic.get false_empties = 0)


