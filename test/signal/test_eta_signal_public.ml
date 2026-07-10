module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp formatter = function
    | `Observer_failed -> Format.pp_print_string formatter "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()
module No_error_signal = Eta_signal.Make_no_error ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

type no_error_test_error =
  [ No_error_signal.graph_error
  | No_error_signal.observer_read_error
  | No_error_signal.stabilize_error ]

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let widen_no_error
    (eff : ('a, [< no_error_test_error ]) E.t) :
    ('a, no_error_test_error) E.t =
  E.map_error (fun error -> (error :> no_error_test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let run_no_error_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen_no_error eff))

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 200

let expect_fail label pred = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when pred error -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let expect_exact_runtime_mismatch label = function
  | Eta.Exit.Error (Eta.Cause.Fail `Runtime_mismatch) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected only Runtime_mismatch, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected Runtime_mismatch, got Ok" label

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec matches_at haystack_index needle_index =
    needle_index = needle_len
    || (haystack_index + needle_index < haystack_len
       && Char.equal haystack.[haystack_index + needle_index]
            needle.[needle_index]
       && matches_at haystack_index (needle_index + 1))
  in
  let rec search index =
    needle_len = 0
    || (index + needle_len <= haystack_len
       && (matches_at index 0 || search (index + 1)))
  in
  search 0

let rec finalizer_has_fail_message expected = function
  | Eta.Cause.Finalizer.Fail message -> contains_substring message expected
  | Eta.Cause.Finalizer.Die _ | Eta.Cause.Finalizer.Interrupt _ -> false
  | Eta.Cause.Finalizer.Sequential causes
  | Eta.Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_fail_message expected) causes
  | Eta.Cause.Finalizer.Finalizer cause ->
      finalizer_has_fail_message expected cause
  | Eta.Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_fail_message expected primary
      || finalizer_has_fail_message expected finalizer

let rec cause_has_finalizer_fail_message expected = function
  | Eta.Cause.Finalizer finalizer -> finalizer_has_fail_message expected finalizer
  | Eta.Cause.Suppressed { primary; finalizer } ->
      cause_has_finalizer_fail_message expected primary
      || finalizer_has_fail_message expected finalizer
  | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
      List.exists (cause_has_finalizer_fail_message expected) causes
  | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _ -> false

let expect_runtime_mismatch_with_cleanup_mismatch label = function
  | Eta.Exit.Error cause
    when Eta.Cause.failures cause = [ `Runtime_mismatch ]
         && cause_has_finalizer_fail_message
              "timer used from a different Eta runtime"
              cause ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf
        "%s: expected Runtime_mismatch with cleanup Runtime_mismatch, got %a"
        label (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected Runtime_mismatch, got Ok" label

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

let test_make_no_error_first_use () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = No_error_signal.Var.create 1 in
  let doubled =
    No_error_signal.Var.watch source
    |> No_error_signal.map (fun value -> value * 2)
  in
  let observer =
    run_no_error_ok runtime
      (No_error_signal.Observer.observe doubled (fun _ -> E.unit))
  in
  run_no_error_ok runtime No_error_signal.stabilize;
  Alcotest.(check int) "initial read" 2
    (run_no_error_ok runtime (No_error_signal.Observer.read observer));
  run_no_error_ok runtime (No_error_signal.Var.set source 3);
  run_no_error_ok runtime No_error_signal.stabilize;
  Alcotest.(check int) "changed read" 6
    (run_no_error_ok runtime (No_error_signal.Observer.read observer));
  run_no_error_ok runtime (No_error_signal.Observer.dispose observer)

let test_basic_observe_stabilize_read () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let updates = ref [] in
  let observer =
    run_ok runtime (Signal.Observer.observe doubled (record updates))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "current" 4
    (run_ok runtime (Signal.Observer.read observer));
  (match List.rev !updates with
   | [ Signal.Initialized 2; Signal.Changed { old_value = 2; new_value = 4 } ]
     ->
       ()
   | _ -> Alcotest.fail "unexpected observer updates");
  run_ok runtime (Signal.Observer.dispose observer)

let test_bind_switch_detaches_stale_dependency () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let observer =
    run_ok runtime (Signal.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set choose_left false);
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set left 99);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch after left update" 20
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Var.set right 21);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch update" 21
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_bind_can_select_initialized_external_bind () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let driver = S.Var.create 0 in
  let leaf = S.Var.create 10 in
  let external_signal =
    S.bind (S.Var.watch driver) (fun offset ->
        S.Var.watch leaf |> S.map (fun value -> value + offset + 1))
  in
  let external_observer =
    run_ok runtime (S.Observer.observe external_signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "external initialized" 11
    (run_ok runtime (S.Observer.read external_observer));
  run_ok runtime (S.Observer.dispose external_observer);
  let selected = S.bind (S.const true) (fun _ -> external_signal) in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "selected initialized external bind" 11
    (run_ok runtime (S.Observer.read selected_observer));
  run_ok runtime (S.Var.set leaf 20);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "selected follows external leaf update" 21
    (run_ok runtime (S.Observer.read selected_observer));
  run_ok runtime (S.Var.set driver 5);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "selected follows external bind switch" 26
    (run_ok runtime (S.Observer.read selected_observer));
  run_ok runtime (S.Observer.dispose selected_observer)

let test_stream_bridge_emits_and_closes () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok runtime (Signal.Stream.observe signal) in
  run_ok runtime Signal.stabilize;
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ Signal.Initialized 1 ],
      [ Signal.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream updates"

let test_interval_catches_up_with_test_clock () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let interval = run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10)) in
  let observer =
    run_ok runtime (Signal.Observer.observe interval (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "initial interval" 0
    (run_ok runtime (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 55;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "caught up interval" 5
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_deadline_uses_monotonic_time () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let now_signal =
    run_ok runtime (Signal.Time.now ~every:(Eta.Duration.ms 1) ())
  in
  let now_observer =
    run_ok runtime (Signal.Observer.observe now_signal (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  let start = run_ok runtime (Signal.Observer.read now_observer) in
  Alcotest.(check int) "start timestamp" 0 (Signal.Time.to_ms start);
  let deadline =
    match Signal.Time.add start (Eta.Duration.ms 10) with
    | Ok deadline -> deadline
    | Error _ -> Alcotest.fail "expected future monotonic deadline"
  in
  let due =
    run_ok runtime (Signal.Time.deadline ~every:(Eta.Duration.ms 1) deadline)
  in
  let due_observer =
    run_ok runtime (Signal.Observer.observe due (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  Alcotest.(check bool) "initial deadline" false
    (run_ok runtime (Signal.Observer.read due_observer));
  Eta_test.Test_clock.set_time clock 9;
  run_ok runtime Signal.stabilize;
  Alcotest.(check bool) "before deadline" false
    (run_ok runtime (Signal.Observer.read due_observer));
  Eta_test.Test_clock.set_time clock 10;
  run_ok runtime Signal.stabilize;
  Alcotest.(check bool) "deadline reached" true
    (run_ok runtime (Signal.Observer.read due_observer));
  run_ok runtime (Signal.Observer.dispose due_observer);
  run_ok runtime (Signal.Observer.dispose now_observer)

let test_deadline_rejects_foreign_monotonic_time () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  Eta_test.Test_clock.set_time clock_a 100;
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let now_signal = run_ok rt_a (S.Time.now ~every:(Eta.Duration.ms 1) ()) in
  let now_observer =
    run_ok rt_a (S.Observer.observe now_signal (fun _ -> E.unit))
  in
  run_ok rt_a S.stabilize;
  let foreign_timestamp = run_ok rt_a (S.Observer.read now_observer) in
  run_ok rt_a (S.Observer.dispose now_observer);
  let foreign_deadline =
    match S.Time.add foreign_timestamp (Eta.Duration.ms 10) with
    | Ok timestamp -> timestamp
    | Error _ -> Alcotest.fail "expected future foreign timestamp"
  in
  expect_exact_runtime_mismatch "deadline timestamp runtime provenance"
    (Eta.Runtime.run rt_b
       (widen
          (S.Time.deadline ~every:(Eta.Duration.ms 1) foreign_deadline)))

let test_generated_deadlines_preserve_runtime_provenance () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let random = Random.State.make [| 17; 71; 193 |] in
  for case = 0 to 23 do
    let now_ms = 100 + (case * 100) + Random.State.int random 50 in
    let duration_ms = 1 + Random.State.int random 80 in
    Eta_test.Test_clock.set_time clock_a now_ms;
    let now_signal = run_ok rt_a (S.Time.now ~every:(Eta.Duration.days 1) ()) in
    let observer =
      run_ok rt_a (S.Observer.observe now_signal (fun _ -> E.unit))
    in
    run_ok rt_a S.stabilize;
    let timestamp = run_ok rt_a (S.Observer.read observer) in
    run_ok rt_a (S.Observer.dispose observer);
    let deadline =
      match S.Time.add timestamp (Eta.Duration.ms duration_ms) with
      | Ok deadline -> deadline
      | Error _ -> Alcotest.failf "case %d: expected future timestamp" case
    in
    ignore
      (run_ok rt_a (S.Time.deadline ~every:(Eta.Duration.ms 1) deadline)
        : bool S.signal);
    expect_exact_runtime_mismatch
      (Format.asprintf "generated timestamp provenance case %d" case)
      (Eta.Runtime.run rt_b
         (widen (S.Time.deadline ~every:(Eta.Duration.ms 1) deadline)))
  done

let with_late_timer_wake ?(jump_ms = 1_000_000) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref 0 in
  let sleep_calls = ref 0 in
  let hold, hold_resolver = Eio.Promise.create () in
  let released = ref false in
  let sleep _duration =
    incr sleep_calls;
    if !sleep_calls = 1 then now_ms := jump_ms
    else Eio.Promise.await hold
  in
  let release () =
    if not !released then (
      released := true;
      Eio.Promise.resolve hold_resolver ())
  in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep
      ~now_ms:(fun () -> !now_ms)
      ()
  in
  Fun.protect ~finally:release (fun () -> f runtime sleep_calls)

let test_step_bounds_large_late_wake () =
  with_late_timer_wake @@ fun runtime sleep_calls ->
  let applied = ref 0 in
  let missed_seen = ref None in
  let step =
    run_ok runtime
      (Signal.Time.step ~every:(Eta.Duration.ms 1) ~initial:0 (fun ~missed value ->
           incr applied;
           missed_seen := Some missed;
           value + missed))
  in
  let observer =
    run_ok runtime (Signal.Observer.observe step (fun _ -> E.unit))
  in
  wait_until "step late wake" (fun () -> !sleep_calls >= 2);
  Alcotest.(check int) "step update calls" 1 !applied;
  Alcotest.(check (option int))
    "step missed count" (Some 1_000_000) !missed_seen;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "step value" 1_000_000
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_timer_runtime_mismatch_on_observe () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let check_mismatch label timer =
    expect_exact_runtime_mismatch
      (label ^ " observe from another runtime")
      (Eta.Runtime.run rt_b
         (widen (S.Observer.observe timer (fun _ -> E.unit))));
    let keep_alive =
      run_ok rt_a (S.Observer.observe timer (fun _ -> E.unit))
    in
    Fun.protect
      ~finally:(fun () -> run_ok rt_a (S.Observer.dispose keep_alive))
      (fun () ->
        run_ok rt_a S.stabilize;
        expect_runtime_mismatch_with_cleanup_mismatch
          (label ^ " active observe from another runtime")
          (Eta.Runtime.run rt_b
             (widen (S.Observer.observe timer (fun _ -> E.unit)))))
  in
  let interval = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  check_mismatch "interval timer" interval;
  let step =
    run_ok rt_a
      (S.Time.step ~every:(Eta.Duration.ms 10) ~initial:0
         (fun ~missed:_ value -> value + 1))
  in
  check_mismatch "step timer" step

let test_mixed_runtime_mismatch_does_not_poison_same_runtime_timer () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let wrong_runtime_timer = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  let same_runtime_timer = run_ok rt_b (S.Time.interval (Eta.Duration.ms 10)) in
  let wrong_runtime_observer =
    run_ok rt_a (S.Observer.observe wrong_runtime_timer (fun _ -> E.unit))
  in
  let wrong_runtime_observer_active = ref true in
  let dispose_wrong_runtime_observer () =
    if !wrong_runtime_observer_active then (
      wrong_runtime_observer_active := false;
      run_ok rt_a (S.Observer.dispose wrong_runtime_observer))
  in
  Fun.protect
    ~finally:dispose_wrong_runtime_observer
    (fun () ->
      run_ok rt_a S.stabilize;
      expect_runtime_mismatch_with_cleanup_mismatch "mixed runtime observe"
        (Eta.Runtime.run rt_b
           (widen
              (S.Observer.observe same_runtime_timer (fun _ -> E.unit))));
      Alcotest.(check int)
        "failed observe did not start same-runtime sleeper" 0
        (Eta_test.Test_clock.sleeper_count clock_b);
      dispose_wrong_runtime_observer ();
      let same_runtime_observer =
        run_ok rt_b (S.Observer.observe same_runtime_timer (fun _ -> E.unit))
      in
      Fun.protect
        ~finally:(fun () ->
          run_ok rt_b (S.Observer.dispose same_runtime_observer))
        (fun () ->
          run_ok rt_b S.stabilize;
          Alcotest.(check int) "same-runtime timer still observes" 0
            (run_ok rt_b (S.Observer.read same_runtime_observer));
          Alcotest.(check bool) "same-runtime sleeper starts after retry" true
            (Eta_test.Test_clock.sleeper_count clock_b > 0)))

let test_dispose_reports_timer_runtime_mismatch () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let clock_b = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_b)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_b)
      ()
  in
  let timer = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  let keep_alive =
    run_ok rt_a (S.Observer.observe timer (fun _ -> E.unit))
  in
  let disposed_from_wrong_runtime =
    run_ok rt_a (S.Observer.observe timer (fun _ -> E.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      run_ok rt_a (S.Observer.dispose disposed_from_wrong_runtime);
      run_ok rt_a (S.Observer.dispose keep_alive))
    (fun () ->
      run_ok rt_a S.stabilize;
      expect_exact_runtime_mismatch "dispose from another runtime"
        (Eta.Runtime.run rt_b
           (widen (S.Observer.dispose disposed_from_wrong_runtime)));
      expect_fail "dispose still finished observer"
        (function `Disposed_observer -> true | _ -> false)
        (Eta.Runtime.run rt_a
           (widen (S.Observer.read disposed_from_wrong_runtime))))

let test_captured_branch_observer_invalidates_without_owner_observer () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = S.Var.create true in
  let left = S.Var.create 10 in
  let right = S.Var.create 20 in
  let captured_left = ref None in
  let selected =
    S.bind (S.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let branch = S.Var.watch left in
          captured_left := Some branch;
          branch)
        else S.Var.watch right)
  in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !captured_left with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch"
  in
  run_ok runtime (S.Observer.dispose selected_observer);
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "branch initialized" 10
    (run_ok runtime (S.Observer.read branch_observer));
  run_ok runtime (S.Var.set choose_left false);
  run_ok runtime S.stabilize;
  expect_fail "captured branch read after switch" (( = ) `Invalid_scope)
    (Eta.Runtime.run runtime (widen (S.Observer.read branch_observer)));
  run_ok runtime (S.Observer.dispose branch_observer)

let test_captured_branch_observer_invalidates_after_owner_gc () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = S.Var.create true in
  let left = S.Var.create 10 in
  let right = S.Var.create 20 in
  let captured_left = ref None in
  let make_and_drop_owner () =
    let external_signal = S.const 0 in
    let selected =
      S.bind (S.Var.watch choose_left) (fun use_left ->
          if use_left then (
            let branch = S.Var.watch left in
            captured_left := Some branch;
            external_signal)
          else S.Var.watch right)
    in
    let selected_observer =
      run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
    in
    run_ok runtime S.stabilize;
    Alcotest.(check int) "selected initialized through external branch" 0
      (run_ok runtime (S.Observer.read selected_observer));
    run_ok runtime (S.Observer.dispose selected_observer);
    run_ok runtime S.stabilize
  in
  make_and_drop_owner ();
  Gc.full_major ();
  Gc.compact ();
  Gc.full_major ();
  let branch =
    match !captured_left with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch"
  in
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "captured branch initialized after owner gc" 10
    (run_ok runtime (S.Observer.read branch_observer));
  run_ok runtime (S.Var.set choose_left false);
  run_ok runtime S.stabilize;
  expect_fail "captured branch read after owner gc switch" (( = ) `Invalid_scope)
    (Eta.Runtime.run runtime (widen (S.Observer.read branch_observer)));
  run_ok runtime (S.Observer.dispose branch_observer)

let test_observer_failure_retries_pending_delivery () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let updates = ref [] in
  let fail_next_change = ref false in
  let observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch source) (fun update ->
           match update with
           | S.Initialized _ -> record updates update
           | S.Changed _ when !fail_next_change ->
               fail_next_change := false;
               E.fail `Observer_failed
           | S.Changed _ -> record updates update))
  in
  run_ok runtime S.stabilize;
  fail_next_change := true;
  run_ok runtime (S.Var.set source 1);
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta.Runtime.run runtime (widen S.stabilize));
  Alcotest.(check int) "snapshot committed despite callback failure" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  (match List.rev !updates with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected pending delivery to retry");
  run_ok runtime (S.Observer.dispose observer)

let test_stream_overflow_does_not_block_graph_progress () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw _clock runtime ->
  let source = S.Var.create 0 in
  let signal = S.Var.watch source in
  let stream_observer, stream =
    run_ok runtime (S.Stream.observe ~capacity:1 signal)
  in
  let observer_updates = ref [] in
  let ordinary_observer =
    run_ok runtime (S.Observer.observe signal (record observer_updates))
  in
  run_ok runtime S.stabilize;
  let before_drop = run_ok runtime (S.stats ()) in
  let progress =
    Eio.Fiber.fork_promise ~sw (fun () ->
        run_ok runtime (S.Var.set source 1);
        run_ok runtime S.stabilize;
        let after_drop = run_ok runtime (S.stats ()) in
        let after_first_updates = List.length !observer_updates in
        run_ok runtime (S.Var.set source 2);
        run_ok runtime S.stabilize;
        (after_drop, after_first_updates))
  in
  wait_until "full stream bridge stabilization" (fun () ->
      Eio.Promise.is_resolved progress);
  let after_drop, after_first_updates = Eio.Promise.await_exn progress in
  Alcotest.(check int) "ordinary observer progressed" 2
    after_first_updates;
  Alcotest.(check int) "full bridge dropped one update"
    (before_drop.S.stream_bridge_drop_count + 1)
    after_drop.S.stream_bridge_drop_count;
  Alcotest.(check int) "ordinary observer still progresses" 3
    (List.length !observer_updates);
  (match
     run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ S.Initialized 0 ] -> ()
   | _ -> Alcotest.fail "expected buffered initialized stream update");
  run_ok runtime (S.Observer.dispose ordinary_observer);
  run_ok runtime (S.Observer.dispose stream_observer)

let () =
  Alcotest.run "eta_signal_public"
    [
      ( "public",
        [
          Alcotest.test_case "no-error graph first use" `Quick
            test_make_no_error_first_use;
          Alcotest.test_case "observe stabilize read" `Quick
            test_basic_observe_stabilize_read;
          Alcotest.test_case "bind switch detaches stale dependency" `Quick
            test_bind_switch_detaches_stale_dependency;
          Alcotest.test_case "bind selects initialized external bind" `Quick
            test_bind_can_select_initialized_external_bind;
          Alcotest.test_case "stream bridge emits and closes" `Quick
            test_stream_bridge_emits_and_closes;
          Alcotest.test_case "interval catches up with test clock" `Quick
            test_interval_catches_up_with_test_clock;
          Alcotest.test_case "deadline uses monotonic time" `Quick
            test_deadline_uses_monotonic_time;
          Alcotest.test_case "deadline rejects foreign monotonic time" `Quick
            test_deadline_rejects_foreign_monotonic_time;
          Alcotest.test_case "generated deadlines preserve runtime provenance"
            `Quick test_generated_deadlines_preserve_runtime_provenance;
          Alcotest.test_case "step bounds large late wake" `Quick
            test_step_bounds_large_late_wake;
          Alcotest.test_case "timer runtime mismatch on observe" `Quick
            test_timer_runtime_mismatch_on_observe;
          Alcotest.test_case "mixed runtime timer mismatch recovery" `Quick
            test_mixed_runtime_mismatch_does_not_poison_same_runtime_timer;
          Alcotest.test_case "dispose reports timer runtime mismatch" `Quick
            test_dispose_reports_timer_runtime_mismatch;
          Alcotest.test_case "captured branch observer invalidates" `Quick
            test_captured_branch_observer_invalidates_without_owner_observer;
          Alcotest.test_case "captured branch observer invalidates after gc"
            `Quick test_captured_branch_observer_invalidates_after_owner_gc;
          Alcotest.test_case "observer failure retries pending delivery" `Quick
            test_observer_failure_retries_pending_delivery;
          Alcotest.test_case "stream overflow does not block graph progress"
            `Quick test_stream_overflow_does_not_block_graph_progress;
        ] );
    ]
