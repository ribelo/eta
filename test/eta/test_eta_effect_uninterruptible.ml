open Eta
open Eta_test
open Test_eta_support

let test_effect_uninterruptible_defers_race_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.named "slow.done" (Effect.sync (fun () ->
        slow_completed := true;
        "slow"))
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "protected loser completed" true !slow_completed

let test_uninterruptible_nested_masks_wait_for_protected_loser () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.named "nested.done" (Effect.sync (fun () ->
        slow_completed := true;
        "slow"))
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for nested protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "nested protected loser completed" true !slow_completed

let test_uninterruptible_blocking_finalizer_delays_race_completion () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref false in
  let protected =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
           Effect.named "release.done" (Effect.sync (fun () -> released := true))
           |> Effect.delay (Duration.ms 1_000))
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) Effect.unit))
    |> Effect.map (fun () -> "protected")
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ protected; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected body" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  wait_for_sleepers clock 1;
  Alcotest.(check bool) "race still waits for protected finalizer" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 1_000);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "blocking finalizer completed" true !released

let test_uninterruptible_timeout_inside_protected_still_fires () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.delay (Duration.ms 100) Effect.unit
    |> Effect.timeout (Duration.ms 50)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 50);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed timeout failure, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "Timeout"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Timeout"

let test_uninterruptible_race_loser_without_checkpoints_returns () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let domain_mgr = Eio.Stdenv.domain_mgr stdenv in
  let completed = ref false in
  let loser =
    Effect.sync (fun () ->
        let total =
          Eio.Domain_manager.run domain_mgr (fun () ->
              let acc = ref 0 in
              for i = 1 to 200_000 do
                acc := !acc + i
              done;
              !acc)
        in
        completed := total > 0;
        "slow")
    |> Effect.uninterruptible
  in
  let result = Runtime.run rt (Effect.race [ Effect.pure "fast"; loser ]) in
  check_exit_ok Alcotest.string "winner preserved" "fast" result;
  Alcotest.(check bool)
    "loser returned without cancellation checkpoint" true !completed


