open Eta
open Eta_test
open Test_eta_support

type dependency_deps = {
  add : int -> int;
  mul : int -> int;
}

let test_explicit_dependency_passing () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let log_calls = ref [] in
  let deps =
    {
      add = (fun n -> n + 1);
      mul = (fun n -> n * 2);
    }
  in
  let db_query s = "row:" ^ s in
  let log_info m = log_calls := m :: !log_calls in
  let services =
    object
      method query = db_query
      method info = log_info
    end
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let b msg = Effect.named "log" (Effect.sync (fun () -> services#info msg)) in
  let c id =
    Effect.named "db" (Effect.sync (fun () -> services#query (string_of_int (deps.add id))))
  in
  let a id =
    let open Effect in
    let user_id = deps.add id in
    bind (fun () -> c id) (b ("fetching " ^ string_of_int user_id))
  in
  match Runtime.run rt (a 41) with
  | Exit.Error _ -> Alcotest.fail "expected Ok"
  | Exit.Ok value ->
      Alcotest.(check string) "db result" "row:42" value;
      Alcotest.(check (list string))
        "log calls" [ "fetching 42" ] (List.rev !log_calls)

(* V-F1 (F-A): par / all / for_each_par. Fail-fast semantics. *)
let test_par_returns_both_successes () =
  with_runtime @@ fun rt ->
  let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure 2)) in
  Alcotest.(check (pair int int)) "par returns pair" (1, 2) result

let test_par_keeps_heterogeneous_successes_private () =
  with_runtime @@ fun rt ->
  let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure "two")) in
  Alcotest.(check (pair int string)) "par returns typed pair" (1, "two") result

let test_par_fail_fast_cancels_sibling () =
  with_runtime @@ fun rt ->
  let other_done = ref false in
  let slow_other =
    Effect.named "slow" (Effect.sync (fun () ->
        Eio.Fiber.yield ();
        other_done := true;
        99))
  in
  let cause =
    match Runtime.run rt (Effect.par (Effect.fail "boom") slow_other) with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "par cause" (Cause.Fail "boom") cause;
  Alcotest.(check bool) "sibling cancelled before completion" false !other_done

let test_all_collects_in_input_order () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt (Effect.all [ Effect.pure 1; Effect.pure 2; Effect.pure 3 ])
  in
  Alcotest.(check (list int)) "all order" [ 1; 2; 3 ] result

let test_all_preserves_input_order_with_out_of_order_completion () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.all
      [
        Effect.pure 1 |> Effect.delay (Duration.ms 30);
        Effect.pure 2 |> Effect.delay (Duration.ms 10);
        Effect.pure 3 |> Effect.delay (Duration.ms 20);
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.ms 30);
  check_exit_ok (Alcotest.list Alcotest.int) "input order" [ 1; 2; 3 ]
    (Eio.Promise.await promise)

let test_all_empty_returns_empty_list () =
  with_runtime @@ fun rt ->
  Alcotest.(check (list int)) "empty" [] (run_ok rt (Effect.all []))

let test_all_fail_fast () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.all [ Effect.pure 1; Effect.fail "boom"; Effect.pure 3 ])
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "all cause" (Cause.Fail "boom") cause

let test_all_settled_collects_successes_and_failures () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.all_settled
         [ Effect.pure 1; Effect.fail `Boom; Effect.pure 3 ])
  in
  match result with
  | [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
  | _ -> Alcotest.fail "unexpected all_settled result"

let test_all_settled_preserves_input_order_with_out_of_order_completion () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.all_settled
      [
        Effect.pure 1 |> Effect.delay (Duration.ms 30);
        Effect.fail `Boom |> Effect.delay (Duration.ms 10);
        Effect.pure 3 |> Effect.delay (Duration.ms 20);
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.ms 30);
  match Eio.Promise.await promise with
  | Exit.Ok [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
  | Exit.Ok _ -> Alcotest.fail "unexpected all_settled result order"
  | Exit.Error cause ->
      Alcotest.failf "expected settled results, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause

let test_all_settled_runs_all_children () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref 0 in
  let slow name =
    Effect.named name (Effect.sync (fun () -> incr slow_done))
    |> Effect.delay (Duration.ms 50)
  in
  let promise =
    fork_run sw rt (Effect.all_settled [ Effect.fail `Boom; slow "a"; slow "b" ])
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 50);
  ignore
    (Eio.Promise.await promise :
      ((unit, [> `Boom ] Cause.t) result list, _) Exit.t);
  Alcotest.(check int) "slow children completed" 2 !slow_done

let test_all_settled_timeout_scoped_resource_is_typed () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let body =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () ->
           Effect.named "release" (Effect.sync (fun () -> incr released)))
      |> Effect.bind (fun () ->
             Effect.delay (Duration.seconds 10) Effect.unit))
    |> Effect.timeout (Duration.seconds 5)
  in
  let promise = fork_run sw rt (Effect.all_settled [ body ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Ok [ Error (Cause.Fail `Timeout) ] ->
      Alcotest.(check int) "released" 1 !released
  | Exit.Ok [ Error cause ] ->
      Alcotest.failf "expected typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected one settled timeout"
  | Exit.Error cause ->
      Alcotest.failf "expected all_settled success, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause

let test_all_settled_empty () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "empty" 0 (List.length (run_ok rt (Effect.all_settled [])))

let test_for_each_par_success () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.for_each_par [ 10; 20; 30 ] (fun x -> Effect.pure (x + 1)))
  in
  Alcotest.(check (list int)) "for_each_par results" [ 11; 21; 31 ] result

let test_for_each_par_preserves_input_order_with_out_of_order_completion () =
  with_test_clock @@ fun sw clock rt ->
  let worker x =
    let delay =
      match x with 1 -> 30 | 2 -> 10 | 3 -> 20 | _ -> 0
    in
    Effect.pure (x * 10) |> Effect.delay (Duration.ms delay)
  in
  let promise = fork_run sw rt (Effect.for_each_par [ 1; 2; 3 ] worker) in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.ms 30);
  check_exit_ok (Alcotest.list Alcotest.int) "input order" [ 10; 20; 30 ]
    (Eio.Promise.await promise)

let test_for_each_par_one_fails () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.for_each_par [ 1; 2; 3 ] (fun x ->
             if x = 2 then Effect.fail "bad" else Effect.pure x))
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "for_each_par cause" (Cause.Fail "bad") cause

let test_for_each_par_bounded_caps_concurrency () =
  with_test_clock @@ fun sw clock rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.named "enter" (Effect.sync (fun () ->
        incr active;
        max_seen := max !max_seen !active))
    |> Effect.bind (fun () ->
           Effect.pure x
           |> Effect.delay (Duration.ms 10)
           |> Effect.tap (fun _ ->
                  Effect.named "leave" (Effect.sync (fun () -> decr active))))
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3; 4; 5 ] worker)
  in
  for _ = 1 to 3 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 10);
    yield ()
  done;
  check_exit_ok (Alcotest.list Alcotest.int) "results" [ 1; 2; 3; 4; 5 ]
    (Eio.Promise.await promise);
  Alcotest.(check int) "max concurrency" 2 !max_seen

let test_for_each_par_bounded_max_one_is_sequential () =
  with_runtime @@ fun rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.named "worker" (Effect.sync (fun () ->
        incr active;
        max_seen := max !max_seen !active;
        decr active;
        x))
  in
  Alcotest.(check (list int)) "results" [ 1; 2; 3 ]
    (run_ok rt (Effect.for_each_par_bounded ~max:1 [ 1; 2; 3 ] worker));
  Alcotest.(check int) "max concurrency" 1 !max_seen

let test_for_each_par_bounded_rejects_nonpositive_max () =
  Alcotest.check_raises "zero max"
    (Invalid_argument "Effect.for_each_par_bounded: max must be > 0")
    (fun () ->
      ignore
        (Effect.for_each_par_bounded ~max:0 [ 1 ] (fun x -> Effect.pure x)
          : (int list, _) Effect.t));
  Alcotest.check_raises "negative max"
    (Invalid_argument "Effect.for_each_par_bounded: max must be > 0")
    (fun () ->
      ignore
        (Effect.for_each_par_bounded ~max:(-1) [ 1 ] (fun x ->
             Effect.pure x)
          : (int list, _) Effect.t))

let test_for_each_par_bounded_fail_fast () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref false in
  let worker = function
    | 1 -> Effect.fail "boom"
    | _ ->
        Effect.named "slow" (Effect.sync (fun () -> slow_done := true))
        |> Effect.delay (Duration.ms 10)
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3 ] worker)
  in
  yield ();
  check_exit_error string_cause "cause" (Cause.Fail "boom")
    (Eio.Promise.await promise);
  Test_clock.adjust clock (Duration.ms 10);
  yield ();
  Alcotest.(check bool) "slow cancelled" false !slow_done

let test_effect_race_ignores_early_failure_until_success () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_success ms value =
    Effect.pure value |> Effect.delay (Duration.ms ms)
  in
  let eff =
    Effect.race
      [
        Effect.fail `Boom |> Effect.delay Duration.zero;
        delayed_success 200 200;
        delayed_success 100 100;
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "race sleepers registered" 2
    (Test_clock.sleeper_count clock);
  Test_clock.adjust clock (Duration.ms 100);
  Alcotest.(check int)
    "first success wins" 100
    (Expect.expect_ok (Eio.Promise.await promise))

let test_effect_race_cancels_losers_after_first_success () =
  with_test_clock @@ fun sw clock rt ->
  let loser_completed = ref false in
  let winner = Effect.pure "winner" |> Effect.delay (Duration.ms 10) in
  let loser =
    Effect.sync (fun () -> loser_completed := true)
    |> Effect.delay (Duration.ms 100)
    |> Effect.map (fun () -> "loser")
  in
  let promise = fork_run sw rt (Effect.race [ winner; loser ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner" "winner" (Eio.Promise.await promise);
  Test_clock.adjust clock (Duration.ms 100);
  yield ();
  Alcotest.(check bool) "loser cancelled" false !loser_completed

let test_effect_race_all_failures_returns_concurrent_causes () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let eff = Effect.race [ delayed_failure 0 "first"; delayed_failure 10 "second" ] in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_error string_cause "failures combined"
    (Cause.Concurrent [ Cause.Fail "first"; Cause.Fail "second" ])
    (Eio.Promise.await promise)

let test_par_simultaneous_failures_records_concurrent_baseline () =
  with_test_clock @@ fun sw _clock rt ->
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let child name =
    Effect.named name (Effect.sync (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go))
    |> Effect.bind (fun () -> Effect.fail name)
  in
  let promise = fork_run sw rt (Effect.par (child "left") (child "right")) in
  let first = Eio.Stream.take ready in
  let second = Eio.Stream.take ready in
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected simultaneous failure"
  | Exit.Error cause ->
      check_concurrent_cause "par simultaneous failure baseline" cause;
      check_string_cause_contains "first child observed" first cause;
      check_string_cause_contains "second child observed" second cause

let test_par_finalizer_failure_during_sibling_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let slow =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:
           (Effect.named "par.slow.acquire" (Effect.sync (fun () ->
                Eio.Promise.resolve acquired_u ())))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.named "par.body.wait_for_acquire" (Effect.sync (fun () ->
        Eio.Promise.await acquired))
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let promise = fork_run sw rt (Effect.par body slow) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "par cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "<typed failure>" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before par returned" true !release_started

let test_all_finalizer_failure_during_sibling_cancellation_baseline () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let slow =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:
           (Effect.named "slow.acquire" (Effect.sync (fun () ->
                Eio.Promise.resolve acquired_u ())))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.named "body.wait_for_acquire" (Effect.sync (fun () -> Eio.Promise.await acquired))
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let promise = fork_run sw rt (Effect.all [ body; slow ]) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "all cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "<typed failure>" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before all returned" true !release_started

let test_for_each_par_simultaneous_failures_baseline () =
  with_test_clock @@ fun sw _clock rt ->
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let worker name =
    Effect.named ("worker." ^ name) (Effect.sync (fun () ->
        if name <> "ok" then (
          Eio.Stream.add ready name;
          Eio.Promise.await go);
        name))
    |> Effect.bind (fun name ->
           if name = "ok" then Effect.pure name else Effect.fail name)
  in
  let promise =
    fork_run sw rt (Effect.for_each_par [ "left"; "right"; "ok" ] worker)
  in
  let first = Eio.Stream.take ready in
  let second = Eio.Stream.take ready in
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected for_each_par failure"
  | Exit.Error cause ->
      check_concurrent_cause "for_each_par simultaneous baseline" cause;
      check_string_cause_contains "first item observed" first cause;
      check_string_cause_contains "second item observed" second cause

let test_for_each_par_finalizer_failure_during_sibling_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let worker = function
    | "slow" ->
        Effect.scoped
          (Effect.acquire_release
             ~acquire:
               (Effect.named "foreach.slow.acquire" (Effect.sync (fun () ->
                    Eio.Promise.resolve acquired_u ())))
             ~release:(fun () ->
               release_started := true;
               Effect.fail "release")
          |> Effect.bind (fun () ->
                 Effect.delay (Duration.ms 1_000) Effect.unit))
    | "body" ->
        Effect.named "foreach.body.wait_for_acquire" (Effect.sync (fun () ->
            Eio.Promise.await acquired))
        |> Effect.bind (fun () -> Effect.fail "body")
    | _ -> Effect.unit
  in
  let promise = fork_run sw rt (Effect.for_each_par [ "body"; "slow" ] worker) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "for_each_par cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "<typed failure>" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before for_each_par returned" true
        !release_started

let check_child_finalizer_before_catch_handler label caught released
    released_before_catch = function
  | Exit.Error (Cause.Interrupt _) ->
      Alcotest.(check bool) (label ^ " caught") true (Atomic.get caught);
      Alcotest.(check bool) (label ^ " released") true (Atomic.get released);
      Alcotest.(check bool)
        (label ^ " released before catch") true
        (Atomic.get released_before_catch)
  | Exit.Error cause ->
      Alcotest.failf "%s: expected uncaught interrupt, got %a" label
        (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected uncaught interrupt" label

let test_par_child_finalizer_runs_before_catch_handler () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let caught = Atomic.make false in
  let released = Atomic.make false in
  let released_before_catch = Atomic.make false in
  let slow =
    Effect.acquire_release
      ~acquire:
        (Effect.sync (fun () ->
             Eio.Promise.resolve acquired_u ();
             ()))
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
  in
  let fail_after_acquire =
    Effect.sync (fun () -> Eio.Promise.await acquired)
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let eff =
    Effect.par fail_after_acquire slow
    |> Effect.catch (fun _ ->
           Atomic.set released_before_catch (Atomic.get released);
           Atomic.set caught true;
           Effect.pure ((), ()))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  check_child_finalizer_before_catch_handler "par" caught released
    released_before_catch (Eio.Promise.await promise)

let test_all_child_finalizer_runs_before_catch_handler () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let caught = Atomic.make false in
  let released = Atomic.make false in
  let released_before_catch = Atomic.make false in
  let slow =
    Effect.acquire_release
      ~acquire:
        (Effect.sync (fun () ->
             Eio.Promise.resolve acquired_u ();
             ()))
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
  in
  let fail_after_acquire =
    Effect.sync (fun () -> Eio.Promise.await acquired)
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let eff =
    Effect.all [ fail_after_acquire; slow ]
    |> Effect.catch (fun _ ->
           Atomic.set released_before_catch (Atomic.get released);
           Atomic.set caught true;
           Effect.pure [])
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  check_child_finalizer_before_catch_handler "all" caught released
    released_before_catch (Eio.Promise.await promise)

let test_for_each_par_child_finalizer_runs_before_catch_handler () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let caught = Atomic.make false in
  let released = Atomic.make false in
  let released_before_catch = Atomic.make false in
  let worker = function
    | "slow" ->
        Effect.acquire_release
          ~acquire:
            (Effect.sync (fun () ->
                 Eio.Promise.resolve acquired_u ();
                 ()))
          ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
        |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
    | "body" ->
        Effect.sync (fun () -> Eio.Promise.await acquired)
        |> Effect.bind (fun () -> Effect.fail "body")
    | _ -> Effect.unit
  in
  let eff =
    Effect.for_each_par [ "body"; "slow" ] worker
    |> Effect.catch (fun _ ->
           Atomic.set released_before_catch (Atomic.get released);
           Atomic.set caught true;
           Effect.pure [])
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  check_child_finalizer_before_catch_handler "for_each_par" caught released
    released_before_catch (Eio.Promise.await promise)

let test_par_nested_race_all_failures_baseline () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let nested =
    Effect.race
      [ delayed_failure 0 "race-left"; delayed_failure 10 "race-right" ]
  in
  let promise =
    fork_run sw rt
      (Effect.par nested (Effect.pure () |> Effect.delay (Duration.ms 20)))
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected nested race failure"
  | Exit.Error cause ->
      check_concurrent_cause "par nested race baseline" cause;
      check_string_cause_contains "nested first failure observed" "race-left" cause;
      check_string_cause_contains "nested second failure observed" "race-right" cause
