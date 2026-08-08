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
  | Signal.time_error ]

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

let expect_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected Ok, got Error"

let expect_error label pred = function
  | Error error when pred error -> ()
  | Error _ -> Alcotest.failf "%s: unexpected error variant" label
  | Ok _ -> Alcotest.failf "%s: expected error, got Ok" label

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

let record updates update =
  updates := update :: !updates;
  Ok ()

let test_make_no_error_first_use () =
  let source = No_error_signal.Var.create 1 in
  let doubled =
    No_error_signal.Var.watch source
    |> No_error_signal.map (fun value -> value * 2)
  in
  let observer =
    expect_ok
      (No_error_signal.Observer.observe doubled ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (No_error_signal.stabilize ());
  Alcotest.(check int) "initial read" 2
    (expect_ok (No_error_signal.Observer.read observer));
  expect_ok (No_error_signal.Var.set source 3);
  expect_ok (No_error_signal.stabilize ());
  Alcotest.(check int) "changed read" 6
    (expect_ok (No_error_signal.Observer.read observer));
  expect_ok (No_error_signal.Observer.dispose observer)

let test_basic_observe_stabilize_read () =
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let updates = ref [] in
  let observer =
    expect_ok (Signal.Observer.observe doubled ~on_update:(record updates))
  in
  expect_ok (Signal.stabilize ());
  expect_ok (Signal.Var.set source 2);
  expect_ok (Signal.stabilize ());
  Alcotest.(check int) "current" 4
    (expect_ok (Signal.Observer.read observer));
  (match List.rev !updates with
   | [ Signal.Initialized 2; Signal.Changed { old_value = 2; new_value = 4 } ]
     ->
       ()
   | _ -> Alcotest.fail "unexpected observer updates");
  expect_ok (Signal.Observer.dispose observer)

let test_bind_switch_detaches_stale_dependency () =
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let observer =
    expect_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (Signal.stabilize ());
  expect_ok (Signal.Var.set choose_left false);
  expect_ok (Signal.stabilize ());
  expect_ok (Signal.Var.set left 99);
  expect_ok (Signal.stabilize ());
  Alcotest.(check int) "right branch after left update" 20
    (expect_ok (Signal.Observer.read observer));
  expect_ok (Signal.Var.set right 21);
  expect_ok (Signal.stabilize ());
  Alcotest.(check int) "right branch update" 21
    (expect_ok (Signal.Observer.read observer));
  expect_ok (Signal.Observer.dispose observer)

let test_bind_can_select_initialized_external_bind () =
  let module S = Eta_signal.Make (Observer_error) () in
  let driver = S.Var.create 0 in
  let leaf = S.Var.create 10 in
  let external_signal =
    S.bind (S.Var.watch driver) ~f:(fun offset ->
        S.Var.watch leaf |> S.map (fun value -> value + offset + 1))
  in
  let external_observer =
    expect_ok (S.Observer.observe external_signal ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  Alcotest.(check int) "external initialized" 11
    (expect_ok (S.Observer.read external_observer));
  expect_ok (S.Observer.dispose external_observer);
  let selected = S.bind (S.const true) ~f:(fun _ -> external_signal) in
  let selected_observer =
    expect_ok (S.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  Alcotest.(check int) "selected initialized external bind" 11
    (expect_ok (S.Observer.read selected_observer));
  expect_ok (S.Var.set leaf 20);
  expect_ok (S.stabilize ());
  Alcotest.(check int) "selected follows external leaf update" 21
    (expect_ok (S.Observer.read selected_observer));
  expect_ok (S.Var.set driver 5);
  expect_ok (S.stabilize ());
  Alcotest.(check int) "selected follows external bind switch" 26
    (expect_ok (S.Observer.read selected_observer));
  expect_ok (S.Observer.dispose selected_observer)

let test_interval_catches_up_with_test_clock () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let interval = run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10)) in
  let observer =
    expect_ok (Signal.Observer.observe interval ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (Signal.stabilize ());
  Alcotest.(check int) "initial interval" 0
    (expect_ok (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 55;
  expect_ok (Signal.stabilize ());
  Alcotest.(check int) "caught up interval" 5
    (expect_ok (Signal.Observer.read observer));
  expect_ok (Signal.Observer.dispose observer)

let test_deadline_uses_monotonic_time () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let now_signal =
    run_ok runtime (Signal.Time.now ~every:(Eta.Duration.ms 1))
  in
  let now_observer =
    expect_ok (Signal.Observer.observe now_signal ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (Signal.stabilize ());
  let start = expect_ok (Signal.Observer.read now_observer) in
  Alcotest.(check int) "start timestamp" 0 (Signal.Time.to_ms start);
  let deadline =
    match Signal.Time.add start (Eta.Duration.ms 10) with
    | Ok deadline -> deadline
    | Error _ -> Alcotest.fail "expected future monotonic deadline"
  in
  let due =
    run_ok runtime (Signal.Time.deadline deadline)
  in
  let due_observer =
    expect_ok (Signal.Observer.observe due ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (Signal.stabilize ());
  Alcotest.(check bool) "initial deadline" false
    (expect_ok (Signal.Observer.read due_observer));
  Eta_test.Test_clock.set_time clock 9;
  expect_ok (Signal.stabilize ());
  Alcotest.(check bool) "before deadline" false
    (expect_ok (Signal.Observer.read due_observer));
  Eta_test.Test_clock.set_time clock 10;
  expect_ok (Signal.stabilize ());
  Alcotest.(check bool) "deadline reached" true
    (expect_ok (Signal.Observer.read due_observer));
  expect_ok (Signal.Observer.dispose due_observer);
  expect_ok (Signal.Observer.dispose now_observer)

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
  let now_signal = run_ok rt_a (S.Time.now ~every:(Eta.Duration.ms 1)) in
  let now_observer =
    expect_ok (S.Observer.observe now_signal ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  let foreign_timestamp = expect_ok (S.Observer.read now_observer) in
  expect_ok (S.Observer.dispose now_observer);
  let foreign_deadline =
    match S.Time.add foreign_timestamp (Eta.Duration.ms 10) with
    | Ok timestamp -> timestamp
    | Error _ -> Alcotest.fail "expected future foreign timestamp"
  in
  expect_exact_runtime_mismatch "deadline timestamp runtime provenance"
    (Eta.Runtime.run rt_b
       (widen
          (S.Time.deadline foreign_deadline)))

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
    let now_signal = run_ok rt_a (S.Time.now ~every:(Eta.Duration.days 1)) in
    let observer =
      expect_ok (S.Observer.observe now_signal ~on_update:(fun _ -> Ok ()))
    in
    expect_ok (S.stabilize ());
    let timestamp = expect_ok (S.Observer.read observer) in
    expect_ok (S.Observer.dispose observer);
    let deadline =
      match S.Time.add timestamp (Eta.Duration.ms duration_ms) with
      | Ok deadline -> deadline
      | Error _ -> Alcotest.failf "case %d: expected future timestamp" case
    in
    ignore
      (run_ok rt_a (S.Time.deadline deadline)
        : bool S.signal);
    expect_exact_runtime_mismatch
      (Format.asprintf "generated timestamp provenance case %d" case)
      (Eta.Runtime.run rt_b
         (widen (S.Time.deadline deadline)))
  done

let test_timers_bind_their_own_runtimes () =
  (* Timer provenance is pinned per timer at creation: one graph may host
     timers bound to different runtimes, and each timer samples its own
     runtime's monotonic clock. *)
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
  let interval_a = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  let interval_b = run_ok rt_b (S.Time.interval (Eta.Duration.ms 10)) in
  let observer_a =
    expect_ok (S.Observer.observe interval_a ~on_update:(fun _ -> Ok ()))
  in
  let observer_b =
    expect_ok (S.Observer.observe interval_b ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      expect_ok (S.Observer.dispose observer_a);
      expect_ok (S.Observer.dispose observer_b))
    (fun () ->
      expect_ok (S.stabilize ());
      Alcotest.(check int) "timer a initial" 0
        (expect_ok (S.Observer.read observer_a));
      Alcotest.(check int) "timer b initial" 0
        (expect_ok (S.Observer.read observer_b));
      Eta_test.Test_clock.set_time clock_a 55;
      expect_ok (S.stabilize ());
      Alcotest.(check int) "timer a follows its own clock" 5
        (expect_ok (S.Observer.read observer_a));
      Alcotest.(check int) "timer b is not moved by clock a" 0
        (expect_ok (S.Observer.read observer_b)))

let test_dispose_hands_timer_stop_to_bound_runtime () =
  (* Disposal is synchronous and runtime-agnostic: it hands the daemon stop
     to the graph's bound timer runtime before returning. *)
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock_a = Eta_test.Test_clock.create () in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock_a)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock_a)
      ()
  in
  let timer = run_ok rt_a (S.Time.interval (Eta.Duration.ms 10)) in
  let keep_alive =
    expect_ok (S.Observer.observe timer ~on_update:(fun _ -> Ok ()))
  in
  let disposed_first =
    expect_ok (S.Observer.observe timer ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () -> expect_ok (S.Observer.dispose keep_alive))
    (fun () ->
      expect_ok (S.stabilize ());
      Alcotest.(check bool) "timer demand started the daemon" true
        (Eta_test.Test_clock.sleeper_count clock_a > 0);
      expect_ok (S.Observer.dispose disposed_first);
      expect_error "disposed observer read" (function
        | `Disposed_observer -> true
        | _ -> false)
        (S.Observer.read disposed_first);
      expect_ok (S.stabilize ()))

let test_captured_branch_observer_invalidates_without_owner_observer () =
  let module S = Eta_signal.Make (Observer_error) () in
  let choose_left = S.Var.create true in
  let left = S.Var.create 10 in
  let right = S.Var.create 20 in
  let captured_left = ref None in
  let selected =
    S.bind (S.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then (
          let branch = S.Var.watch left in
          captured_left := Some branch;
          branch)
        else S.Var.watch right)
  in
  let selected_observer =
    expect_ok (S.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  let branch =
    match !captured_left with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch"
  in
  expect_ok (S.Observer.dispose selected_observer);
  let branch_observer =
    expect_ok (S.Observer.observe branch ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  Alcotest.(check int) "branch initialized" 10
    (expect_ok (S.Observer.read branch_observer));
  expect_ok (S.Var.set choose_left false);
  expect_ok (S.stabilize ());
  expect_error "captured branch read after switch" (( = ) `Invalid_scope)
    (S.Observer.read branch_observer);
  expect_ok (S.Observer.dispose branch_observer)

let test_captured_branch_observer_invalidates_after_owner_gc () =
  let module S = Eta_signal.Make (Observer_error) () in
  let choose_left = S.Var.create true in
  let left = S.Var.create 10 in
  let right = S.Var.create 20 in
  let captured_left = ref None in
  let make_and_drop_owner () =
    let external_signal = S.const 0 in
    let selected =
      S.bind (S.Var.watch choose_left) ~f:(fun use_left ->
          if use_left then (
            let branch = S.Var.watch left in
            captured_left := Some branch;
            external_signal)
          else S.Var.watch right)
    in
    let selected_observer =
      expect_ok (S.Observer.observe selected ~on_update:(fun _ -> Ok ()))
    in
    expect_ok (S.stabilize ());
    Alcotest.(check int) "selected initialized through external branch" 0
      (expect_ok (S.Observer.read selected_observer));
    expect_ok (S.Observer.dispose selected_observer);
    expect_ok (S.stabilize ())
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
    expect_ok (S.Observer.observe branch ~on_update:(fun _ -> Ok ()))
  in
  expect_ok (S.stabilize ());
  Alcotest.(check int) "captured branch initialized after owner gc" 10
    (expect_ok (S.Observer.read branch_observer));
  expect_ok (S.Var.set choose_left false);
  expect_ok (S.stabilize ());
  expect_error "captured branch read after owner gc switch"
    (( = ) `Invalid_scope) (S.Observer.read branch_observer);
  expect_ok (S.Observer.dispose branch_observer)

let test_observer_failure_settles_and_reports () =
  (* A typed callback failure settles the delivery and is reported through
     [stabilize]; the delivery is not retried. *)
  let module S = Eta_signal.Make (Observer_error) () in
  let source = S.Var.create 0 in
  let updates = ref [] in
  let fail_next_change = ref false in
  let observer =
    expect_ok
      (S.Observer.observe (S.Var.watch source) ~on_update:(fun update ->
           match update with
           | S.Initialized _ -> record updates update
           | S.Changed _ when !fail_next_change ->
               fail_next_change := false;
               Error `Observer_failed
           | S.Changed _ -> record updates update))
  in
  expect_ok (S.stabilize ());
  fail_next_change := true;
  expect_ok (S.Var.set source 1);
  expect_error "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (S.stabilize ());
  Alcotest.(check int) "snapshot committed despite callback failure" 1
    (expect_ok (S.Observer.read observer));
  expect_ok (S.stabilize ());
  (match List.rev !updates with
   | [ S.Initialized 0 ] -> ()
   | _ -> Alcotest.fail "typed callback failure must settle without retry");
  expect_ok (S.Observer.dispose observer)

let test_observer_raise_retries_pending_delivery () =
  (* A raising callback leaves the delivery pending; the defect propagates
     out of [stabilize] and the delivery is retried on the next settle
     round. *)
  let module S = Eta_signal.Make (Observer_error) () in
  let source = S.Var.create 0 in
  let updates = ref [] in
  let raise_next_change = ref false in
  let observer =
    expect_ok
      (S.Observer.observe (S.Var.watch source) ~on_update:(fun update ->
           match update with
           | S.Initialized _ -> record updates update
           | S.Changed _ when !raise_next_change ->
               raise_next_change := false;
               failwith "observer defect"
           | S.Changed _ -> record updates update))
  in
  expect_ok (S.stabilize ());
  raise_next_change := true;
  expect_ok (S.Var.set source 1);
  (match S.stabilize () with
   | _ -> Alcotest.fail "expected defect raise from stabilize"
   | exception Failure _ -> ());
  Alcotest.(check int) "snapshot committed despite callback defect" 1
    (expect_ok (S.Observer.read observer));
  expect_ok (S.stabilize ());
  (match List.rev !updates with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected pending delivery to retry after defect");
  expect_ok (S.Observer.dispose observer)

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
          Alcotest.test_case "interval catches up with test clock" `Quick
            test_interval_catches_up_with_test_clock;
          Alcotest.test_case "deadline uses monotonic time" `Quick
            test_deadline_uses_monotonic_time;
          Alcotest.test_case "deadline rejects foreign monotonic time" `Quick
            test_deadline_rejects_foreign_monotonic_time;
          Alcotest.test_case "generated deadlines preserve runtime provenance"
            `Quick test_generated_deadlines_preserve_runtime_provenance;
          Alcotest.test_case "timers bind their own runtimes" `Quick
            test_timers_bind_their_own_runtimes;
          Alcotest.test_case "dispose hands timer stop to bound runtime" `Quick
            test_dispose_hands_timer_stop_to_bound_runtime;
          Alcotest.test_case "captured branch observer invalidates" `Quick
            test_captured_branch_observer_invalidates_without_owner_observer;
          Alcotest.test_case "captured branch observer invalidates after gc"
            `Quick test_captured_branch_observer_invalidates_after_owner_gc;
          Alcotest.test_case "observer failure settles and reports" `Quick
            test_observer_failure_settles_and_reports;
          Alcotest.test_case "observer raise retries pending delivery" `Quick
            test_observer_raise_retries_pending_delivery;
        ] );
    ]
