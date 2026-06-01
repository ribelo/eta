open Eta
open Eta_test
open Test_eta_support

(* These tests port upstream Effect/ZIO invariants rather than API shapes. Keep
   them here when Eta already has local unit tests for the same combinators but
   lacks coverage for cross-cutting cancellation and cleanup contracts. *)

let check_timeout label = function
  | Exit.Error (Cause.Fail `Timeout) -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Timeout, got %a" label
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected Timeout" label

let rec cause_has_boom = function
  | Cause.Fail `Boom -> true
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists cause_has_boom causes
  | Cause.Finalizer _ -> false
  | Cause.Suppressed { primary; finalizer = _ } -> cause_has_boom primary

let check_boom label = function
  | Exit.Error cause when cause_has_boom cause -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Boom, got %a" label
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected Boom" label

let test_effect_smol_acquire_use_release_timeout_releases () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let body =
    Effect.acquire_use_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> incr released))
      (fun () -> Effect.delay (Duration.ms 100) Effect.unit)
    |> Effect.timeout_as (Duration.ms 10) ~on_timeout:`Timeout
  in
  let promise = fork_run sw rt body in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  check_timeout "acquireUseRelease interrupt" (Eio.Promise.await promise);
  Alcotest.(check int) "release count" 1 !released

let test_effect_smol_finally_runs_on_timeout_interrupt () =
  with_test_clock @@ fun sw clock rt ->
  let finalized = ref false in
  let body =
    Effect.delay (Duration.ms 100) Effect.unit
    |> Effect.finally (Effect.sync (fun () -> finalized := true))
    |> Effect.timeout_as (Duration.ms 10) ~on_timeout:`Timeout
  in
  let promise = fork_run sw rt body in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  check_timeout "ensuring interrupt" (Eio.Promise.await promise);
  Alcotest.(check bool) "finalizer ran" true !finalized

let scoped_delay release id ms =
  Effect.acquire_release ~acquire:Effect.unit
    ~release:(fun () -> Effect.sync (fun () -> release id))
  |> Effect.bind (fun () -> Effect.delay (Duration.ms ms) (Effect.pure id))

let test_effect_smol_race_cancels_losers_before_return () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref [] in
  let release id = released := id :: !released in
  let winner = Effect.delay (Duration.ms 10) (Effect.pure 0) in
  let losers =
    [ 100; 200; 300; 500 ] |> List.map (fun ms -> scoped_delay release ms ms)
  in
  let promise = fork_run sw rt (Effect.race (winner :: losers)) in
  wait_for_sleepers clock 5;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.int "winner" 0 (Eio.Promise.await promise);
  Alcotest.(check (list int))
    "losers released before race returns"
    [ 100; 200; 300; 500 ]
    (List.sort Int.compare !released)

let test_effect_smol_all_fail_fast_releases_losing_scopes () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref [] in
  let release id = released := id :: !released in
  let slow id = scoped_delay release id 100 |> Effect.map (fun _ -> ()) in
  let boom = Effect.fail `Boom |> Effect.delay (Duration.ms 10) in
  let promise = fork_run sw rt (Effect.all [ slow 1; boom; slow 2 ]) in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.ms 10);
  check_boom "all fail-fast" (Eio.Promise.await promise);
  Alcotest.(check (list int))
    "siblings released before all returns"
    [ 1; 2 ]
    (List.sort Int.compare !released)

let test_zio_timeout_waits_for_resource_release () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref false in
  let body =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () ->
        Effect.sync (fun () -> released := true) |> Effect.delay (Duration.ms 50))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 100) Effect.unit)
    |> Effect.timeout_as (Duration.ms 10) ~on_timeout:`Timeout
  in
  let promise = fork_run sw rt body in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  wait_for_sleepers clock 1;
  Alcotest.(check bool)
    "timeout waits while release is still sleeping" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 100);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 50);
  wait_until (fun () -> Eio.Promise.is_resolved promise);
  check_timeout "timeout release" (Eio.Promise.await promise);
  Alcotest.(check bool) "release completed" true !released
