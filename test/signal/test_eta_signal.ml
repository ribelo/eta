open Eta

module Signal = Eta_signal.Make (struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end)

type test_error =
  [ `Update_failed
  | Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<signal-error>"

let widen (eff : ('a, [< test_error ]) Effect.t) : ('a, test_error) Effect.t =
  Effect.map_error (fun err -> (err :> test_error)) eff

let run_ok rt eff =
  match Eta_eio.Runtime.run rt (widen eff) with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let expect_fail :
    type a. string -> (test_error -> bool) -> (a, test_error) Exit.t -> unit =
 fun label pred -> function
  | Exit.Error (Cause.Fail err) when pred err -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let expect_die label = function
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected defect, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected defect, got Ok" label

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f rt

let wait_for_sleepers clock expected =
  let rec loop attempts =
    if Eta_test.Test_clock.sleeper_count clock >= expected then ()
    else if attempts = 0 then
      Alcotest.failf "expected %d sleepers, got %d" expected
        (Eta_test.Test_clock.sleeper_count clock)
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 20

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let await_cancelled label promise =
  try
    match Eio.Promise.await_exn promise with
    | Exit.Ok _ -> Alcotest.failf "%s: expected Eio cancellation, got Ok" label
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Eio cancellation, got %a" label
          (Cause.pp pp_hidden) cause
  with Eio.Cancel.Cancelled _ -> ()

let expect_exit_ok label = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Ok, got %a" label (Cause.pp pp_hidden) cause

let with_runtime_and_switch f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f sw rt

let record_observer events update =
  Effect.sync (fun () -> events := update :: !events)

let test_observer_initializes_on_stabilize () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun n -> n * 2) in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe doubled (record_observer events))
  in
  expect_fail "read before stabilize"
    (( = ) `Uninitialized_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer read" 2
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int))
    "initial event" [ 2 ]
    (List.map
       (function
         | Signal.Initialized n -> n
         | Changed _ -> Alcotest.fail "unexpected changed event")
       (List.rev !events))

let test_manual_stabilization_coalesces_sets () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe observed (record_observer events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt (Signal.Var.set source 3);
  Alcotest.(check int) "source direct read sees latest set" 3
    (Signal.Var.value source);
  Alcotest.(check int) "observer still sees old snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer sees coalesced value" 3
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "two events" 2 (List.length !events)

let test_diamond_recomputes_shared_node_once () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let calls = ref 0 in
  let shared =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           incr calls;
           n + 1)
  in
  let left = Signal.map (fun n -> n * 2) shared in
  let right = Signal.map (fun n -> n * 3) shared in
  let total = Signal.map2 ( + ) left right in
  let observer =
    run_ok rt (Signal.Observer.observe total (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial total" 10
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "initial shared compute once" 1 !calls;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "updated total" 15
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "updated shared compute once" 2 !calls

let test_n_ary_maps_both_and_all () =
  with_runtime @@ fun rt ->
  let v1 = Signal.Var.create 1 in
  let v2 = Signal.Var.create 2 in
  let v3 = Signal.Var.create 3 in
  let v4 = Signal.Var.create 4 in
  let v5 = Signal.Var.create 5 in
  let v6 = Signal.Var.create 6 in
  let v7 = Signal.Var.create 7 in
  let v8 = Signal.Var.create 8 in
  let v9 = Signal.Var.create 9 in
  let s1 = Signal.Var.watch v1 in
  let s2 = Signal.Var.watch v2 in
  let s3 = Signal.Var.watch v3 in
  let s4 = Signal.Var.watch v4 in
  let s5 = Signal.Var.watch v5 in
  let s6 = Signal.Var.watch v6 in
  let s7 = Signal.Var.watch v7 in
  let s8 = Signal.Var.watch v8 in
  let s9 = Signal.Var.watch v9 in
  let sum3 = Signal.map3 (fun a b c -> a + b + c) s1 s2 s3 in
  let sum4 = Signal.map4 (fun a b c d -> a + b + c + d) s1 s2 s3 s4 in
  let sum5 =
    Signal.map5 (fun a b c d e -> a + b + c + d + e) s1 s2 s3 s4 s5
  in
  let sum6 =
    Signal.map6
      (fun a b c d e f -> a + b + c + d + e + f)
      s1 s2 s3 s4 s5 s6
  in
  let sum7 =
    Signal.map7
      (fun a b c d e f g -> a + b + c + d + e + f + g)
      s1 s2 s3 s4 s5 s6 s7
  in
  let sum8 =
    Signal.map8
      (fun a b c d e f g h -> a + b + c + d + e + f + g + h)
      s1 s2 s3 s4 s5 s6 s7 s8
  in
  let sum9 =
    Signal.map9
      (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
      s1 s2 s3 s4 s5 s6 s7 s8 s9
  in
  let pair_sum = Signal.both s1 s2 |> Signal.map (fun (a, b) -> a + b) in
  let all_sum =
    Signal.all [ s1; s2; s3 ] |> Signal.map (List.fold_left ( + ) 0)
  in
  let combined =
    Signal.all
      [ sum3; sum4; sum5; sum6; sum7; sum8; sum9; pair_sum; all_sum ]
    |> Signal.map (List.fold_left ( + ) 0)
  in
  let observer =
    run_ok rt (Signal.Observer.observe combined (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial combined n-ary value" 170
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set v9 10);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "map9 updates through all" 171
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set v1 11);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "shared source updates all combinators" 261
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_cutoff_suppresses_downstream_recompute () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let parity =
    Signal.Var.watch source
    |> Signal.map ~equal:Int.equal (fun n -> n mod 2)
  in
  let downstream_calls = ref 0 in
  let downstream =
    Signal.map
      (fun n ->
        incr downstream_calls;
        n)
      parity
  in
  let observer =
    run_ok rt (Signal.Observer.observe downstream (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial value" 0
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "downstream not recomputed" 1 !downstream_calls

let test_default_cutoff_is_physical_equality () =
  with_runtime @@ fun rt ->
  let initial = Array.make 1 1 in
  let next = Array.copy initial in
  Alcotest.(check bool) "test values are distinct blocks" false (initial == next);
  let source = Signal.Var.create initial in
  let events = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (record_observer events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source next);
  run_ok rt Signal.stabilize;
  (match List.rev !events with
   | [ Signal.Initialized initialized; Changed { old_value; new_value } ] ->
       Alcotest.(check (list int)) "initialized value" [ 1 ]
         (Array.to_list initialized);
       Alcotest.(check bool) "old value is initial block" true
         (old_value == initial);
       Alcotest.(check bool) "new value is next block" true
         (new_value == next)
   | _ -> Alcotest.fail "expected initialized and changed events");
  Alcotest.(check bool) "observer current is next block" true
    (run_ok rt (Signal.Observer.read observer) == next);
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_equality_suppresses_only_that_observer () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source in
  let suppressed_events = ref [] in
  let normal_events = ref [] in
  let suppressed_observer =
    run_ok rt
      (Signal.Observer.observe ~equal:(fun _old_value _new_value -> true)
         signal (record_observer suppressed_events))
  in
  let normal_observer =
    run_ok rt (Signal.Observer.observe signal (record_observer normal_events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "suppressed observer saw only initialization" 1
    (List.length !suppressed_events);
  Alcotest.(check int) "normal observer saw initialization and change" 2
    (List.length !normal_events);
  Alcotest.(check int) "suppressed observer current still updates" 1
    (run_ok rt (Signal.Observer.read suppressed_observer));
  Alcotest.(check int) "normal observer current updates" 1
    (run_ok rt (Signal.Observer.read normal_observer));
  run_ok rt (Signal.Observer.dispose suppressed_observer);
  run_ok rt (Signal.Observer.dispose normal_observer)

let test_bind_detaches_old_dependency () =
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial left" 10
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "switched right" 20
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set left 99);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "old left detached" 20
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "right still active" 21
    (run_ok rt (Signal.Observer.read observer))

let test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes () =
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let left_calls = ref 0 in
  let right_calls = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then
          Signal.Var.watch left
          |> Signal.map (fun value ->
                 incr left_calls;
                 value)
        else
          Signal.Var.watch right
          |> Signal.map (fun value ->
                 incr right_calls;
                 value))
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let before_switch = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "initial left value" 10
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "left inner computed once" 1 !left_calls;
  Alcotest.(check int) "right inner not yet computed" 0 !right_calls;
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  let after_switch = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool)
    "scope invalidation counted" true
    (after_switch.Signal.dynamic_scope_invalidations
     > before_switch.Signal.dynamic_scope_invalidations);
  Alcotest.(check int) "switched right value" 20
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "obsolete left inner not recomputed on switch" 1
    !left_calls;
  Alcotest.(check int) "right inner computed once" 1 !right_calls;
  run_ok rt (Signal.Var.set left 99);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "obsolete left update does not recompute old scope" 1
    !left_calls;
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "active right update recomputes active scope" 2
    !right_calls;
  Alcotest.(check int) "right value updates" 21
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_cycle_detection_is_typed_failure () =
  with_runtime @@ fun rt ->
  let trigger = Signal.Var.create () in
  let holder = ref None in
  let cyclic =
    Signal.bind (Signal.Var.watch trigger) (fun () ->
        match !holder with
        | Some signal -> signal
        | None -> Alcotest.fail "cycle holder was not initialized")
  in
  holder := Some cyclic;
  let observer =
    run_ok rt (Signal.Observer.observe cyclic (fun _ -> Effect.unit))
  in
  expect_fail "cycle" (( = ) `Cycle)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose observer)

let test_unobserved_nodes_do_not_recompute () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let calls = ref 0 in
  let _unobserved =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           incr calls;
           n + 1)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "unobserved map never recomputed" 0 !calls

let test_observer_mutation_is_delayed_to_next_stabilization () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer =
    run_ok rt
      (Signal.Observer.observe signal (function
        | Signal.Initialized 1 -> Signal.Var.set source 2
        | Initialized _ | Changed _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "current stabilization snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "next stabilization sees observer mutation" 2
    (run_ok rt (Signal.Observer.read observer))

let test_observer_read_during_callback_sees_current_snapshot () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let seen = ref [] in
  let observer_ref = ref None in
  let observer =
    run_ok rt
      (Signal.Observer.observe signal (fun _update ->
           match !observer_ref with
           | None -> Effect.unit
           | Some observer ->
               Signal.Observer.read observer
               |> Effect.map_error (fun _ -> `Observer_failed)
               |> Effect.bind (fun value ->
                      Effect.sync (fun () -> seen := value :: !seen))))
  in
  observer_ref := Some observer;
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int)) "callback reads current snapshots" [ 1; 2 ]
    (List.rev !seen)

let test_dispose_removes_demand () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let calls = ref 0 in
  let mapped =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           incr calls;
           n + 1)
  in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Observer.dispose observer);
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "disposed observer releases demand" 1 !calls;
  expect_fail "disposed read" (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)))

let test_pure_failure_does_not_publish_partial_snapshot_and_can_retry () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           if n = 2 then failwith "boom";
           n)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  expect_die "pure callback defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old snapshot remains after defect" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization retries graph" 3
    (run_ok rt (Signal.Observer.read observer))

let test_failed_initial_stabilization_leaves_no_current_value () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let fail = ref true in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           if !fail then (
             fail := false;
             failwith "initial failure");
           value)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  expect_die "initial pure failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  expect_fail "read after failed initial stabilization"
    (( = ) `No_current_value)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization initializes observer" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_cutoff_exception_is_defect_without_partial_snapshot () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let defect = Failure "cutoff" in
  let mapped =
    Signal.Var.watch source
    |> Signal.map
         ~equal:(fun _old_value _new_value -> raise defect)
         (fun n -> n)
  in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  expect_die "cutoff defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old snapshot remains after cutoff defect" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_ambiguous_node_creation_during_pure_recompute_is_typed_failure () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           ignore (Signal.const n : int Signal.signal);
           n)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  expect_fail "pure ambiguous scope" (( = ) `Ambiguous_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose observer)

let test_ambiguous_node_creation_during_observer_callback_is_typed_failure () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           ignore (Signal.const 1 : int Signal.signal);
           Effect.unit))
  in
  expect_fail "observer ambiguous scope" (( = ) `Ambiguous_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_failure_fails_stabilize () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (function
         | Initialized _ -> Effect.fail `Observer_failed
         | Changed _ -> Effect.unit))
      : int Signal.observer);
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize))

let test_observer_failure_is_fail_fast () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let later_ran = ref false in
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (fun _ -> Effect.fail `Observer_failed))
      : int Signal.observer);
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (fun _ ->
            Effect.sync (fun () -> later_ran := true)))
      : int Signal.observer);
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check bool) "later observer did not run" false !later_ran

let test_reentrant_stabilization_is_typed_failure () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let nested = ref None in
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (fun _ ->
            Effect.exit Signal.stabilize
            |> Effect.bind (fun exit ->
                   Effect.sync (fun () -> nested := Some exit))))
      : int Signal.observer);
  run_ok rt Signal.stabilize;
  (match !nested with
   | Some (Exit.Error (Cause.Fail `Reentrant_stabilization)) -> ()
   | Some (Exit.Error cause) ->
       Alcotest.failf "unexpected nested cause %a" (Cause.pp pp_hidden) cause
   | Some (Exit.Ok ()) -> Alcotest.fail "nested stabilize unexpectedly succeeded"
   | None -> Alcotest.fail "nested stabilize did not run")

let test_reentrant_stabilization_does_not_clear_outer_phase () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let nested = ref [] in
  let record_nested () =
    Effect.exit Signal.stabilize
    |> Effect.bind (fun exit ->
           Effect.sync (fun () -> nested := exit :: !nested))
  in
  ignore
    (run_ok rt (Signal.Observer.observe observed (fun _ -> record_nested ()))
      : int Signal.observer);
  ignore
    (run_ok rt (Signal.Observer.observe observed (fun _ -> record_nested ()))
      : int Signal.observer);
  run_ok rt Signal.stabilize;
  let is_reentrant = function
    | Exit.Error (Cause.Fail `Reentrant_stabilization) -> true
    | Exit.Ok _ | Exit.Error _ -> false
  in
  Alcotest.(check int) "two nested attempts" 2 (List.length !nested);
  Alcotest.(check bool)
    "all nested attempts remained reentrant" true
    (List.for_all is_reentrant !nested)

let test_effectful_update_reentry_fails_and_preserves_value () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  expect_fail "reentrant update" (( = ) `Reentrant_update)
    (Eta_eio.Runtime.run rt
       (widen
          (Signal.Var.update_effect source (fun current ->
               Signal.Var.update_effect source (fun _ -> Effect.pure (current + 10))
               |> Effect.map (fun _ -> current + 1)))));
  Alcotest.(check int) "source unchanged" 1 (Signal.Var.value source)

let test_effectful_update_failures_preserve_value_and_release_slot () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  expect_fail "typed update failure" (( = ) `Update_failed)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Var.update_effect source (fun _ -> Effect.fail `Update_failed))));
  Alcotest.(check int) "typed failure leaves value unchanged" 1
    (Signal.Var.value source);
  Alcotest.(check int) "slot released after typed failure" 2
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))));
  expect_die "update callback defect"
    (Eta_eio.Runtime.run rt
       (widen (Signal.Var.update_effect source (fun _ -> failwith "update defect"))));
  Alcotest.(check int) "defect leaves value unchanged" 2
    (Signal.Var.value source);
  Alcotest.(check int) "slot released after defect" 3
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))))

let test_effectful_update_interruption_preserves_value_and_releases_slot () =
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let cancel_ctx = ref None in
  let updating =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run rt
          (widen
             (Signal.Var.update_effect source (fun current ->
                  Effect.sync (fun () ->
                      Eio.Promise.resolve started_resolver ())
                  |> Effect.bind (fun () ->
                         Effect.never |> Effect.map (fun () -> current + 10))))))
  in
  Eio.Promise.await started;
  wait_until "update cancellation context" (fun () -> Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  await_cancelled "interrupted update" updating;
  Alcotest.(check int) "interruption leaves value unchanged" 1
    (Signal.Var.value source);
  Alcotest.(check int) "slot released after interruption" 2
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))))

let test_queued_graph_operation_cancellation_does_not_run () =
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let block_once = ref true in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           if !block_once then (
             block_once := false;
             Eio.Promise.resolve started_resolver ();
             Eio.Promise.await release);
           n)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  Eio.Promise.await started;
  let attempted, attempted_resolver = Eio.Promise.create () in
  let cancel_ctx = ref None in
  let queued_set =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run rt
          (widen
             (Effect.sync (fun () -> Eio.Promise.resolve attempted_resolver ())
             |> Effect.bind (fun () -> Signal.Var.set source 2))))
  in
  wait_until "queued set cancellation context" (fun () ->
      Option.is_some !cancel_ctx);
  Eio.Promise.await attempted;
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  await_cancelled "queued set" queued_set;
  Eio.Promise.resolve release_resolver ();
  ignore (expect_exit_ok "stabilizer" (Eio.Promise.await_exn stabilizer) : unit);
  Alcotest.(check int) "cancelled set did not run" 1 (Signal.Var.value source);
  Alcotest.(check int) "observer kept original value" 1
    (run_ok rt (Signal.Observer.read observer))

let test_active_graph_operation_interruption_releases_lane () =
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let block_once = ref true in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           if !block_once then (
             block_once := false;
             Eio.Promise.resolve started_resolver ();
             Eio.Promise.await release);
           n)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  let cancel_ctx = ref None in
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  Eio.Promise.await started;
  wait_until "active stabilize cancellation context" (fun () ->
      Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  await_cancelled "active stabilize" stabilizer;
  Eio.Promise.resolve release_resolver ();
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "lane released for later set/stabilize" 2
    (run_ok rt (Signal.Observer.read observer))

let test_stats_and_dot_are_read_only () =
  with_runtime @@ fun rt ->
  let before = run_ok rt (Signal.stats ()) in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source |> Signal.map (fun n -> n + 1) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  let after_observe = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "active observer increments"
    (before.Signal.active_observer_count + 1)
    after_observe.Signal.active_observer_count;
  Alcotest.(check bool) "necessary nodes visible" true
    (after_observe.Signal.necessary_node_count
     > before.Signal.necessary_node_count);
  run_ok rt Signal.stabilize;
  let after_stabilize = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "stabilization count increments"
    (before.Signal.stabilization_count + 1)
    after_stabilize.Signal.stabilization_count;
  Alcotest.(check bool) "recompute count visible" true
    (after_stabilize.Signal.recompute_count > before.Signal.recompute_count);
  let dot = run_ok rt (Signal.to_dot ()) in
  Alcotest.(check bool) "dot dump is non-empty" true (String.length dot > 0);
  run_ok rt (Signal.Observer.dispose observer)

let test_time_interval_starts_only_when_observed () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  Eta_test.Async.yield ();
  Alcotest.(check int) "unobserved timer has no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial tick" 0
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_interval_requires_explicit_stabilization () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "read before stabilize remains old" 0
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "stabilized tick" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_timer_becomes_inert_after_dispose () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Observer.dispose observer);
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "disposed timer did not reschedule" 0
    (Eta_test.Test_clock.sleeper_count clock)

let test_time_timer_becomes_inert_after_bind_switch () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create true in
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then timer else Signal.const 0)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  Alcotest.(check int) "bind timer waits for branch materialization" 0
    (Eta_test.Test_clock.sleeper_count clock);
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Var.set use_timer false);
  run_ok rt Signal.stabilize;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "detached timer did not reschedule" 0
    (Eta_test.Test_clock.sleeper_count clock);
  run_ok rt (Signal.Observer.dispose observer)

let test_time_now_uses_runtime_clock () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ()) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial now" 0
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "updated now" 5
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_after_deadline () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt
      (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "initial deadline" false
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "deadline not reached" false
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "deadline reached" true
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_step_function () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 5) ~initial:1 (fun n -> n * 2))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial step" 1
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "first step" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_validation_errors () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  expect_fail "invalid interval" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.interval Duration.zero)));
  expect_fail "past deadline" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.deadline ~every:(Duration.ms 1) 0)))

let test_stream_bridge_emits_after_stabilize () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok rt (Signal.Stream.observe signal) in
  let first =
    Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect
  in
  run_ok rt Signal.stabilize;
  (match run_ok rt first with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initialized stream update");
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_bridge_validates_capacity () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  expect_fail "invalid stream capacity" (( = ) `Invalid_capacity)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Stream.observe ~capacity:0 signal)))

let test_stream_bridge_closes_on_observer_dispose () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok rt (Signal.Stream.observe signal) in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Observer.dispose observer);
  match run_ok rt (Eta_stream.run_collect stream) with
  | [ Signal.Initialized 1 ] -> ()
  | _ -> Alcotest.fail "expected stream to drain buffered update and close"

let test_stream_bridge_backpressures_at_capacity () =
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    run_ok rt (Signal.Stream.observe ~capacity:1 signal)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "stabilization waits for bridge capacity" false
    (Eio.Promise.is_resolved stabilizer);
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update");
  ignore
    (expect_exit_ok "backpressured stabilize"
       (Eio.Promise.await_exn stabilizer)
      : unit);
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected changed stream update after capacity frees");
  run_ok rt (Signal.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal"
    [
      ( "core",
        [
          Alcotest.test_case "observer initializes on stabilize" `Quick
            test_observer_initializes_on_stabilize;
          Alcotest.test_case "manual stabilization coalesces sets" `Quick
            test_manual_stabilization_coalesces_sets;
          Alcotest.test_case "diamond recomputes shared node once" `Quick
            test_diamond_recomputes_shared_node_once;
          Alcotest.test_case "n-ary maps, both, and all" `Quick
            test_n_ary_maps_both_and_all;
          Alcotest.test_case "cutoff suppresses downstream recompute" `Quick
            test_cutoff_suppresses_downstream_recompute;
          Alcotest.test_case "default cutoff is physical equality" `Quick
            test_default_cutoff_is_physical_equality;
          Alcotest.test_case "observer equality is observer-local" `Quick
            test_observer_equality_suppresses_only_that_observer;
          Alcotest.test_case "bind detaches old dependency" `Quick
            test_bind_detaches_old_dependency;
          Alcotest.test_case "bind invalidates old scope" `Quick
            test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes;
          Alcotest.test_case "bind cycle detection typed failure" `Quick
            test_bind_cycle_detection_is_typed_failure;
          Alcotest.test_case "unobserved nodes do not recompute" `Quick
            test_unobserved_nodes_do_not_recompute;
          Alcotest.test_case "observer mutation is delayed" `Quick
            test_observer_mutation_is_delayed_to_next_stabilization;
          Alcotest.test_case "observer read during callback" `Quick
            test_observer_read_during_callback_sees_current_snapshot;
          Alcotest.test_case "dispose removes demand" `Quick
            test_dispose_removes_demand;
          Alcotest.test_case "pure failure does not publish snapshot" `Quick
            test_pure_failure_does_not_publish_partial_snapshot_and_can_retry;
          Alcotest.test_case "failed initial stabilize has no current" `Quick
            test_failed_initial_stabilization_leaves_no_current_value;
          Alcotest.test_case "cutoff exception preserves snapshot" `Quick
            test_cutoff_exception_is_defect_without_partial_snapshot;
          Alcotest.test_case "pure ambiguous node creation typed failure" `Quick
            test_ambiguous_node_creation_during_pure_recompute_is_typed_failure;
          Alcotest.test_case "observer ambiguous node creation typed failure"
            `Quick
            test_ambiguous_node_creation_during_observer_callback_is_typed_failure;
          Alcotest.test_case "observer failure fails stabilize" `Quick
            test_observer_failure_fails_stabilize;
          Alcotest.test_case "observer failure is fail-fast" `Quick
            test_observer_failure_is_fail_fast;
          Alcotest.test_case "reentrant stabilization typed failure" `Quick
            test_reentrant_stabilization_is_typed_failure;
          Alcotest.test_case "reentrant stabilization keeps outer phase" `Quick
            test_reentrant_stabilization_does_not_clear_outer_phase;
          Alcotest.test_case "effectful update reentry typed failure" `Quick
            test_effectful_update_reentry_fails_and_preserves_value;
          Alcotest.test_case "effectful update failure cleanup" `Quick
            test_effectful_update_failures_preserve_value_and_release_slot;
          Alcotest.test_case "effectful update interruption cleanup" `Quick
            test_effectful_update_interruption_preserves_value_and_releases_slot;
          Alcotest.test_case "queued graph operation cancellation" `Quick
            test_queued_graph_operation_cancellation_does_not_run;
          Alcotest.test_case "active graph interruption releases lane" `Quick
            test_active_graph_operation_interruption_releases_lane;
          Alcotest.test_case "stats and dot introspection" `Quick
            test_stats_and_dot_are_read_only;
          Alcotest.test_case "time interval starts on observe" `Quick
            test_time_interval_starts_only_when_observed;
          Alcotest.test_case "time interval needs stabilization" `Quick
            test_time_interval_requires_explicit_stabilization;
          Alcotest.test_case "time timer inert after dispose" `Quick
            test_time_timer_becomes_inert_after_dispose;
          Alcotest.test_case "time timer inert after bind switch" `Quick
            test_time_timer_becomes_inert_after_bind_switch;
          Alcotest.test_case "time now uses runtime clock" `Quick
            test_time_now_uses_runtime_clock;
          Alcotest.test_case "time after deadline" `Quick
            test_time_after_deadline;
          Alcotest.test_case "time step function" `Quick
            test_time_step_function;
          Alcotest.test_case "time validation errors" `Quick
            test_time_validation_errors;
          Alcotest.test_case "stream bridge emits after stabilize" `Quick
            test_stream_bridge_emits_after_stabilize;
          Alcotest.test_case "stream bridge validates capacity" `Quick
            test_stream_bridge_validates_capacity;
          Alcotest.test_case "stream bridge closes on dispose" `Quick
            test_stream_bridge_closes_on_observer_dispose;
          Alcotest.test_case "stream bridge backpressures" `Quick
            test_stream_bridge_backpressures_at_capacity;
        ] );
    ]
