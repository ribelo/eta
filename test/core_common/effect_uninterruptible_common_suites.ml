module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let pp_hidden ppf _ = Format.pp_print_string ppf "<effect>"

  let check_exit_ok test name expected = function
    | Exit.Ok actual -> Alcotest.check test name expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" name (Cause.pp pp_hidden)
          cause

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected at least %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 20

  let test_effect_uninterruptible_defers_race_cancellation () =
    B.with_test_clock @@ fun ctx clock rt ->
    let slow_completed = ref false in
    let slow =
      Effect.named "slow.done"
        (Effect.sync (fun () ->
             slow_completed := true;
             "slow"))
      |> Effect.delay (Duration.ms 10)
      |> Effect.uninterruptible
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; Effect.pure "fast" ]) in
    wait_for_sleepers clock 1;
    B.yield ();
    Alcotest.(check bool) "race waits for protected loser" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 10);
    check_exit_ok Alcotest.string "winner preserved" "fast" (B.await promise);
    Alcotest.(check bool) "protected loser completed" true !slow_completed

  let test_uninterruptible_nested_masks_wait_for_protected_loser () =
    B.with_test_clock @@ fun ctx clock rt ->
    let slow_completed = ref false in
    let slow =
      Effect.named "nested.done"
        (Effect.sync (fun () ->
             slow_completed := true;
             "slow"))
      |> Effect.delay (Duration.ms 10)
      |> Effect.uninterruptible
      |> Effect.uninterruptible
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; Effect.pure "fast" ]) in
    wait_for_sleepers clock 1;
    B.yield ();
    Alcotest.(check bool) "race waits for nested protected loser" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 10);
    check_exit_ok Alcotest.string "winner preserved" "fast" (B.await promise);
    Alcotest.(check bool) "nested protected loser completed" true !slow_completed

  let test_uninterruptible_blocking_finalizer_delays_race_completion () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref false in
    let protected =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
             Effect.named "release.done"
               (Effect.sync (fun () -> released := true))
             |> Effect.delay (Duration.ms 1_000))
        |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) Effect.unit))
      |> Effect.map (fun () -> "protected")
      |> Effect.uninterruptible
    in
    let promise =
      B.fork_run ctx rt (Effect.race [ protected; Effect.pure "fast" ])
    in
    wait_for_sleepers clock 1;
    B.yield ();
    Alcotest.(check bool) "race waits for protected body" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 10);
    wait_for_sleepers clock 1;
    Alcotest.(check bool) "race still waits for protected finalizer" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 1_000);
    check_exit_ok Alcotest.string "winner preserved" "fast" (B.await promise);
    Alcotest.(check bool) "blocking finalizer completed" true !released

  let test_uninterruptible_timeout_inside_protected_still_fires () =
    B.with_test_clock @@ fun ctx clock rt ->
    let eff =
      Effect.delay (Duration.ms 100) Effect.unit
      |> Effect.timeout (Duration.ms 50)
      |> Effect.uninterruptible
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 50);
    match B.await promise with
    | Exit.Error (Cause.Fail _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed timeout failure, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected Timeout"

  let tests =
    [
      ( "Effect uninterruptible",
        [
          Alcotest.test_case "uninterruptible defers race cancellation" `Quick
            test_effect_uninterruptible_defers_race_cancellation;
          Alcotest.test_case "uninterruptible nested masks" `Quick
            test_uninterruptible_nested_masks_wait_for_protected_loser;
          Alcotest.test_case "uninterruptible blocking finalizer" `Quick
            test_uninterruptible_blocking_finalizer_delays_race_completion;
          Alcotest.test_case "uninterruptible timeout inside protected" `Quick
            test_uninterruptible_timeout_inside_protected_still_fires;
        ] );
    ]
end
