open Eta
open Eta_test
open Test_eta_support

let test_semaphore_make_available () =
  let sem = Semaphore.make ~permits:8 in
  Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

let test_semaphore_make_rejects_zero_permits () =
  Alcotest.check_raises "zero permits"
    (Invalid_argument "Eta.Semaphore.make: permits must be > 0")
    (fun () -> ignore (Semaphore.make ~permits:0))

let test_semaphore_acquire_reduces_available () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:8 in
  run_ok rt (Semaphore.acquire sem 1);
  Alcotest.(check int) "available 7" 7 (Semaphore.available sem)

let test_semaphore_release_increases_available () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:8 in
  run_ok rt (Semaphore.acquire sem 1);
  Semaphore.release sem 1;
  Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

let test_semaphore_release_rejects_negative_count () =
  let sem = Semaphore.make ~permits:2 in
  Alcotest.check_raises "negative release"
    (Invalid_argument "Eta.Semaphore.release: n must be > 0")
    (fun () -> Semaphore.release sem (-1))

let test_semaphore_release_rejects_zero_count () =
  let sem = Semaphore.make ~permits:2 in
  Alcotest.check_raises "zero release"
    (Invalid_argument "Eta.Semaphore.release: n must be > 0")
    (fun () -> Semaphore.release sem 0)

let test_semaphore_release_rejects_over_capacity () =
  let sem = Semaphore.make ~permits:2 in
  Alcotest.check_raises "release over capacity"
    (Invalid_argument
       "Eta.Semaphore.release: release would exceed semaphore capacity")
    (fun () -> Semaphore.release sem 3)

let test_semaphore_rejects_over_capacity_acquire () =
  let sem = Semaphore.make ~permits:2 in
  Alcotest.check_raises "acquire over capacity"
    (Invalid_argument "Eta.Semaphore.acquire: n must be between 1 and max_permits")
    (fun () -> ignore (Semaphore.acquire sem 3 : (unit, _) Effect.t))

let test_semaphore_rejects_over_capacity_try_acquire () =
  let sem = Semaphore.make ~permits:2 in
  Alcotest.check_raises "try_acquire over capacity"
    (Invalid_argument
       "Eta.Semaphore.try_acquire: n must be between 1 and max_permits")
    (fun () -> ignore (Semaphore.try_acquire sem 3 : bool))

let test_semaphore_acquire_at_capacity_succeeds () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:2 in
  run_ok rt (Semaphore.acquire sem 2);
  Alcotest.(check int) "available 0" 0 (Semaphore.available sem)

let test_semaphore_try_acquire_is_atomic () =
  let sem = Semaphore.make ~permits:3 in
  Alcotest.(check bool) "first acquire succeeds" true
    (Semaphore.try_acquire sem 2);
  Alcotest.(check int) "one permit remains" 1 (Semaphore.available sem);
  Alcotest.(check bool) "oversized acquire fails" false
    (Semaphore.try_acquire sem 2);
  Alcotest.(check int) "failed acquire did not decrement" 1
    (Semaphore.available sem);
  Alcotest.(check bool) "remaining permit succeeds" true
    (Semaphore.try_acquire sem 1);
  Alcotest.(check int) "empty" 0 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_success () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:5 in
  let result =
    run_ok rt
      (Semaphore.with_permits sem 3 (fun () -> Effect.pure "done"))
  in
  Alcotest.(check string) "result" "done" result;
  Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_failure () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:5 in
  let eff =
    Semaphore.with_permits sem 3 (fun () -> Effect.fail `Boom)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "caught")
  in
  let result = run_ok rt eff in
  Alcotest.(check string) "caught" "caught" result;
  Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_defect () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:5 in
  (match
     Runtime.run rt
       (Semaphore.with_permits sem 3 (fun () ->
            Effect.sync (fun () -> failwith "permit body defect")))
   with
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected body defect, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sem>")) cause
  | Exit.Ok _ -> Alcotest.fail "expected body defect");
  Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:3 in
  let timed_out = ref false in
  let eff =
    Semaphore.with_permits sem 2 (fun () ->
        Effect.delay (Duration.ms 100) Effect.unit)
    |> Effect.timeout (Duration.ms 10)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) ->
         Effect.sync (fun () -> timed_out := true))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.unit "timed out" () (Eio.Promise.await promise);
  Alcotest.(check bool) "timed_out" true !timed_out;
  Alcotest.(check int) "released" 3 (Semaphore.available sem)

let test_semaphore_cancellation_stress () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:8 in
  let holder =
    Semaphore.with_permits sem 1 (fun () ->
        Effect.delay (Duration.ms 10_000) Effect.unit)
  in
  let holders = List.init 8 (fun _ -> fork_run sw rt holder) in
  wait_for_sleepers clock 8;
  Alcotest.(check int) "available 0" 0 (Semaphore.available sem);
  let waiters =
    List.init 50 (fun _ ->
      fork_run sw rt
        (Semaphore.acquire sem 1
         |> Effect.timeout (Duration.ms 5)
         |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure ())))
  in
  wait_for_sleepers clock 58;
  Test_clock.adjust clock (Duration.ms 5);
  List.iter (fun p -> ignore (Eio.Promise.await p : (unit, _) Exit.t)) waiters;
  Alcotest.(check int) "cancelled waiters" 50
    (Semaphore.cancelled_waiters sem);
  Alcotest.(check int) "waiting 0" 0 (Semaphore.waiting sem);
  Test_clock.adjust clock (Duration.ms 10_000);
  List.iter (fun p -> ignore (Eio.Promise.await p : (unit, _) Exit.t)) holders;
  Alcotest.(check int) "final available" 8 (Semaphore.available sem)

let test_semaphore_cancellation_removes_waiters_behind_active_waiter () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:2 in
  run_ok rt (Semaphore.acquire sem 2);
  let blocked =
    fork_run sw rt
      (Semaphore.acquire sem 2
       |> Effect.bind (fun () ->
            Effect.sync (fun () -> Semaphore.release sem 2)))
  in
  wait_until (fun () -> Semaphore.waiting sem = 1);
  let cancelled =
    List.init 10 (fun _ ->
      fork_run sw rt
        (Semaphore.acquire sem 1
         |> Effect.timeout (Duration.ms 5)
         |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure ())))
  in
  wait_for_sleepers clock 10;
  Test_clock.adjust clock (Duration.ms 5);
  List.iter
    (fun p -> check_exit_ok Alcotest.unit "cancelled" () (Eio.Promise.await p))
    cancelled;
  Alcotest.(check int) "only active waiter remains" 1 (Semaphore.waiting sem);
  Semaphore.release sem 2;
  check_exit_ok Alcotest.unit "blocked waiter completes" ()
    (Eio.Promise.await blocked);
  Alcotest.(check int) "permits returned" 2 (Semaphore.available sem)

let test_semaphore_fifo_wakes_waiters_in_order () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let sem = Semaphore.make ~permits:1 in
  run_ok rt (Semaphore.acquire sem 1);
  let completed = ref [] in
  let waiter name =
    Semaphore.acquire sem 1
    |> Effect.bind (fun () ->
           Effect.sync (fun () -> completed := name :: !completed))
  in
  let first = fork_run sw rt (waiter "first") in
  wait_until (fun () -> Semaphore.waiting sem = 1);
  let second = fork_run sw rt (waiter "second") in
  wait_until (fun () -> Semaphore.waiting sem = 2);
  Semaphore.release sem 1;
  check_exit_ok Alcotest.unit "first woke" () (Eio.Promise.await first);
  Alcotest.(check (list string)) "first only" [ "first" ] !completed;
  Semaphore.release sem 1;
  check_exit_ok Alcotest.unit "second woke" () (Eio.Promise.await second);
  Alcotest.(check (list string)) "fifo order" [ "second"; "first" ] !completed

let test_semaphore_cancel_after_wakeup_returns_permit () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let sem = Semaphore.make ~permits:1 in
  run_ok rt (Semaphore.acquire sem 1);
  let cancel_ctx = ref None in
  let waiter =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Semaphore.acquire sem 1))
  in
  wait_until (fun () -> Semaphore.waiting sem = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  Semaphore.release sem 1;
  (match Eio.Promise.await_exn waiter with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int) "permit returned" 1 (Semaphore.available sem);
  Alcotest.(check int) "cancelled waiter" 1 (Semaphore.cancelled_waiters sem)

let test_semaphore_waiting_ignores_resolved_waiter () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let sem = Semaphore.make ~permits:1 in
  run_ok rt (Semaphore.acquire sem 1);
  let waiter = fork_run sw rt (Semaphore.acquire sem 1) in
  wait_until (fun () -> Semaphore.waiting sem = 1);
  Semaphore.release sem 1;
  Alcotest.(check int) "resolved waiter no longer waiting" 0
    (Semaphore.waiting sem);
  check_exit_ok Alcotest.unit "waiter acquired" () (Eio.Promise.await waiter);
  Semaphore.release sem 1

let test_semaphore_multi_permit_contention () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:5 in
  let h1 =
    fork_run sw rt
      (Semaphore.acquire sem 2
       |> Effect.bind (fun () ->
            Effect.delay (Duration.ms 50) Effect.unit
            |> Effect.bind (fun () ->
                   Effect.sync (fun () -> Semaphore.release sem 2))))
  in
  let h2 =
    fork_run sw rt
      (Semaphore.acquire sem 2
       |> Effect.bind (fun () ->
            Effect.delay (Duration.ms 100) Effect.unit
            |> Effect.bind (fun () ->
                   Effect.sync (fun () -> Semaphore.release sem 2))))
  in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "available 1" 1 (Semaphore.available sem);
  let waiter =
    fork_run sw rt
      (Semaphore.acquire sem 3
       |> Effect.bind (fun () ->
            Effect.sync (fun () -> Semaphore.release sem 3)
            |> Effect.map (fun () -> "got3")))
  in
  Eio.Fiber.yield ();
  Alcotest.(check int) "waiting 1" 1 (Semaphore.waiting sem);
  Test_clock.adjust clock (Duration.ms 50);
  ignore (Eio.Promise.await h1 : (unit, _) Exit.t);
  check_exit_ok Alcotest.string "waiter got 3" "got3"
    (Eio.Promise.await waiter);
  Alcotest.(check int) "available 3 after waiter" 3
    (Semaphore.available sem);
  Test_clock.adjust clock (Duration.ms 50);
  ignore (Eio.Promise.await h2 : (unit, _) Exit.t);
  Alcotest.(check int) "final available" 5 (Semaphore.available sem)
