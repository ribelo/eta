open Eta

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()
module Other_signal = Eta_signal.Make (Observer_error) ()

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

let render pp value = Format.asprintf "%a" pp value

let check_render label pp value expected =
  Alcotest.(check string) label expected (render pp value)

let test_error_pretty_printers_are_clear () =
  check_render "ambiguous scope" Signal.pp_graph_error `Ambiguous_scope
    "ambiguous dynamic scope";
  check_render "cycle" Signal.pp_graph_error `Cycle "cycle detected";
  check_render "invalid scope" Signal.pp_graph_error `Invalid_scope
    "invalid dynamic scope";
  check_render "reentrant stabilization" Signal.pp_graph_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "reentrant update" Signal.pp_graph_error `Reentrant_update
    "same-variable effectful update reentry";
  check_render "disposed observer" Signal.pp_observer_read_error
    `Disposed_observer "disposed observer";
  check_render "no current observer value" Signal.pp_observer_read_error
    `No_current_value "no current observer value";
  check_render "uninitialized observer" Signal.pp_observer_read_error
    `Uninitialized_observer "uninitialized observer";
  check_render "stabilize graph error" Signal.pp_stabilize_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "stabilize observer error" Signal.pp_stabilize_error
    (`Observer_error `Observer_failed) "observer callback failed: observer failed";
  check_render "invalid interval" Signal.pp_time_error `Invalid_interval
    "invalid interval";
  check_render "past deadline" Signal.pp_time_error `Past_deadline
    "deadline is in the past";
  check_render "stream graph error" Signal.pp_stream_error `Cycle
    "cycle detected";
  check_render "invalid stream capacity" Signal.pp_stream_error
    `Invalid_capacity "stream bridge capacity must be positive"

let test_observer_initializes_on_stabilize () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun n -> n * 2) in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe doubled (record_observer events))
  in
  Alcotest.(check int) "registration does not run callback" 0
    (List.length !events);
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

let test_observer_unsafe_read_exn_reports_invalid_state () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (fun _ -> Effect.unit))
  in
  Alcotest.check_raises "unsafe read before stabilize"
    (Invalid_argument "Eta_signal observer is not initialized")
    (fun () -> ignore (Signal.Observer.unsafe_read_exn observer : int));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "unsafe read stabilized value" 1
    (Signal.Observer.unsafe_read_exn observer);
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.check_raises "unsafe read after dispose"
    (Invalid_argument "Eta_signal observer is disposed")
    (fun () -> ignore (Signal.Observer.unsafe_read_exn observer : int))

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

let test_functor_instances_stabilize_independently () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let other_source = Other_signal.Var.create 10 in
  let events = ref [] in
  let other_events = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source)
         (record_observer events))
  in
  let other_observer =
    run_ok rt
      (Other_signal.Observer.observe
         (Other_signal.Var.watch other_source)
         (record_observer other_events))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "first graph initialized" 1
    (run_ok rt (Signal.Observer.read observer));
  (match
     Eta_eio.Runtime.run rt
       (widen (Other_signal.Observer.read other_observer))
   with
   | Exit.Error (Cause.Fail `Uninitialized_observer) -> ()
   | Exit.Error cause ->
       Alcotest.failf "expected second graph to remain uninitialized, got %a"
         (Cause.pp pp_hidden) cause
   | Exit.Ok _ ->
       Alcotest.fail "second graph initialized during first graph stabilize");
  run_ok rt (Signal.Var.set source 2);
  run_ok rt (Other_signal.Var.set other_source 20);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "first graph changed" 2
    (run_ok rt (Signal.Observer.read observer));
  (match
     Eta_eio.Runtime.run rt
       (widen (Other_signal.Observer.read other_observer))
   with
   | Exit.Error (Cause.Fail `Uninitialized_observer) -> ()
   | Exit.Error cause ->
       Alcotest.failf "expected second graph to still be uninitialized, got %a"
         (Cause.pp pp_hidden) cause
   | Exit.Ok _ ->
       Alcotest.fail "second graph updated during first graph stabilize");
  run_ok rt Other_signal.stabilize;
  Alcotest.(check int) "second graph initialized with its latest source" 20
    (run_ok rt (Other_signal.Observer.read other_observer));
  Alcotest.(check int) "first graph event count" 2 (List.length !events);
  Alcotest.(check int) "second graph event count" 1
    (List.length !other_events);
  run_ok rt (Signal.Observer.dispose observer);
  run_ok rt (Other_signal.Observer.dispose other_observer)

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

let test_recompute_order_is_topological () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let order = ref [] in
  let record label =
    order := label :: !order
  in
  let shared =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           record "shared";
           n + 1)
  in
  let left =
    Signal.map
      (fun n ->
        record "left";
        n * 2)
      shared
  in
  let right =
    Signal.map
      (fun n ->
        record "right";
        n * 3)
      shared
  in
  let total =
    Signal.map2
      (fun left right ->
        record "total";
        left + right)
      left right
  in
  let observer =
    run_ok rt (Signal.Observer.observe total (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "initial topological recompute order"
    [ "shared"; "left"; "right"; "total" ]
    (List.rev !order);
  order := [];
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "updated topological recompute order"
    [ "shared"; "left"; "right"; "total" ]
    (List.rev !order);
  Alcotest.(check int) "updated value" 15
    (run_ok rt (Signal.Observer.read observer))

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

let test_source_equality_suppresses_graph_propagation () =
  with_runtime @@ fun rt ->
  let source =
    Signal.Var.create ~equal:(fun old_value new_value ->
        old_value mod 2 = new_value mod 2)
      0
  in
  let calls = ref 0 in
  let observed =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr calls;
           value)
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe observed (record_observer events))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial recompute" 1 !calls;
  run_ok rt (Signal.Var.set source 2);
  Alcotest.(check int) "source value updates immediately" 2
    (Signal.Var.value source);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "equal source update does not recompute" 1 !calls;
  Alcotest.(check int) "observer keeps previous graph snapshot" 0
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "equal source update emits no event" 1
    (List.length !events);
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "non-equal source update recomputes" 2 !calls;
  Alcotest.(check int) "observer sees non-equal update" 3
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !events with
   | [ Signal.Initialized 0; Changed { old_value = 0; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected initialization and non-equal change event");
  run_ok rt (Signal.Observer.dispose observer)

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

let test_observer_callbacks_run_in_registration_order () =
  with_runtime @@ fun rt ->
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 2 in
  let left_signal = Signal.Var.watch left in
  let right_signal = Signal.Var.watch right in
  let events = ref [] in
  let record label _update =
    Effect.sync (fun () -> events := label :: !events)
  in
  let left_first =
    run_ok rt (Signal.Observer.observe left_signal (record "left-1"))
  in
  let left_second =
    run_ok rt (Signal.Observer.observe left_signal (record "left-2"))
  in
  let right_first =
    run_ok rt (Signal.Observer.observe right_signal (record "right-1"))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "initial observer order" [ "left-1"; "left-2"; "right-1" ]
    (List.rev !events);
  events := [];
  run_ok rt (Signal.Var.set right 20);
  run_ok rt (Signal.Var.set left 10);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "changed observer order" [ "left-1"; "left-2"; "right-1" ]
    (List.rev !events);
  run_ok rt (Signal.Observer.dispose left_first);
  run_ok rt (Signal.Observer.dispose left_second);
  run_ok rt (Signal.Observer.dispose right_first)

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

let test_bind_selector_failure_preserves_previous_branch () =
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let fail_selector = ref true in
  let fail_inner = ref false in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left
        else if !fail_selector then failwith "selector"
        else
          Signal.Var.watch right
          |> Signal.map (fun value ->
                 if !fail_inner then failwith "inner";
                 value))
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial left branch" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set choose_left false);
  expect_die "selector defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old snapshot remains after selector defect" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set choose_left true);
  run_ok rt (Signal.Var.set left 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "old branch is still active after failed switch" 2
    (run_ok rt (Signal.Observer.read observer));
  fail_selector := false;
  fail_inner := true;
  run_ok rt (Signal.Var.set choose_left false);
  expect_die "inner branch defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old snapshot remains after inner defect" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set choose_left true);
  run_ok rt (Signal.Var.set left 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "old branch remains active after inner defect" 3
    (run_ok rt (Signal.Observer.read observer));
  fail_inner := false;
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later successful switch reaches right branch" 10
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_switch_is_not_committed_when_later_pure_node_fails () =
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let bad = Signal.Var.create 0 in
  let left_inner = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          left_inner := Some signal;
          signal
        else Signal.Var.watch right)
  in
  let failing =
    Signal.Var.watch bad
    |> Signal.map (fun value ->
           if value = 1 then failwith "later pure failure";
           value)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  let failing_observer =
    (run_ok rt (Signal.Observer.observe failing (fun _ -> Effect.unit))
      : int Signal.observer)
  in
  run_ok rt Signal.stabilize;
  let old_inner =
    match !left_inner with
    | Some signal -> signal
    | None -> Alcotest.fail "left branch was not created"
  in
  Alcotest.(check int) "initial selected value" 1
    (run_ok rt (Signal.Observer.read selected_observer));
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt (Signal.Var.set bad 1);
  expect_die "later pure failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose failing_observer);
  let old_inner_observer =
    run_ok rt (Signal.Observer.observe old_inner (fun _ -> Effect.unit))
  in
  run_ok rt (Signal.Observer.dispose old_inner_observer);
  run_ok rt (Signal.Observer.dispose selected_observer)

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

let test_observer_read_does_not_force_recompute () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let calls = ref 0 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr calls;
           value)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let after_stabilize = run_ok rt (Signal.stats ()) in
  run_ok rt (Signal.Var.set source 2);
  let before_read = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "read returns old stabilized snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  let after_read = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "observer read does not stabilize"
    before_read.Signal.stabilization_count
    after_read.Signal.stabilization_count;
  Alcotest.(check int) "observer read does not recompute"
    before_read.Signal.recompute_count after_read.Signal.recompute_count;
  Alcotest.(check int) "pending update not recomputed by read" 1 !calls;
  run_ok rt Signal.stabilize;
  let after_second_stabilize = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool) "later stabilization recomputes" true
    (after_second_stabilize.Signal.recompute_count
     > after_read.Signal.recompute_count);
  Alcotest.(check int) "map recomputed by later stabilization" 2 !calls;
  Alcotest.(check bool) "stabilization count advanced" true
    (after_second_stabilize.Signal.stabilization_count
     > after_stabilize.Signal.stabilization_count);
  Alcotest.(check int) "observer sees new snapshot after stabilize" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

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

let test_dispose_before_initialization_removes_demand () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let calls = ref 0 in
  let callback_ran = ref false in
  let mapped =
    Signal.Var.watch source
    |> Signal.map (fun n ->
           incr calls;
           n + 1)
  in
  let observer =
    run_ok rt
      (Signal.Observer.observe mapped (fun _ ->
           Effect.sync (fun () -> callback_ran := true)))
  in
  run_ok rt (Signal.Observer.dispose observer);
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "disposed uninitialized observer releases demand" 0 !calls;
  Alcotest.(check bool) "disposed uninitialized observer has no callback" false
    !callback_ran;
  expect_fail "disposed uninitialized read" (( = ) `Disposed_observer)
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

let test_source_equality_exception_is_defect_without_partial_snapshot () =
  with_runtime @@ fun rt ->
  let fail_equal = ref true in
  let source =
    Signal.Var.create
      ~equal:(fun _old_value _new_value ->
        if !fail_equal then failwith "source equality";
        false)
      1
  in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  expect_die "source equality defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old snapshot remains after source equality defect" 1
    (run_ok rt (Signal.Observer.read observer));
  fail_equal := false;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization retries source equality" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_equality_exception_is_defect_without_partial_snapshot () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let fail_equal = ref true in
  let events = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe
         ~equal:(fun _old_value _new_value ->
           if !fail_equal then failwith "observer equality";
           false)
         (Signal.Var.watch source)
         (record_observer events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  expect_die "observer equality defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "old observer current remains after equality defect" 1
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "observer callback was not run after equality defect" 1
    (List.length !events);
  fail_equal := false;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer current retries after equality defect" 2
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "observer callback runs after retry" 2
    (List.length !events);
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

let test_observer_effects_before_later_failure_are_not_rolled_back () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let effects = ref [] in
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (fun _ ->
            Effect.sync (fun () -> effects := "first" :: !effects)))
      : int Signal.observer);
  ignore
    (run_ok rt
       (Signal.Observer.observe observed (fun _ -> Effect.fail `Observer_failed))
      : int Signal.observer);
  expect_fail "later observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check (list string))
    "already-run observer effect remains" [ "first" ] (List.rev !effects)

let test_observer_callback_construction_defect_does_not_poison_graph () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let fail_once = ref true in
  let observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           if !fail_once then (
             fail_once := false;
             failwith "observer construction");
           Effect.unit))
  in
  expect_die "observer construction defect"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "snapshot published before observer defect" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization is not poisoned" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

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

let test_effectful_update_success_publishes_once () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe observed (record_observer events))
  in
  run_ok rt Signal.stabilize;
  events := [];
  Alcotest.(check int) "update result" 2
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))));
  Alcotest.(check int) "source updated" 2 (Signal.Var.value source);
  Alcotest.(check int) "observer waits for stabilization" 1
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "no event before stabilization" 0 (List.length !events);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer sees update" 2
    (run_ok rt (Signal.Observer.read observer));
  (match !events with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected one changed event");
  events := [];
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "no duplicate event" 0 (List.length !events);
  run_ok rt (Signal.Observer.dispose observer)

let test_effectful_update_allows_other_variable_mutation () =
  with_runtime @@ fun rt ->
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let combined =
    Signal.map2 ( + ) (Signal.Var.watch left) (Signal.Var.watch right)
  in
  let observer =
    run_ok rt (Signal.Observer.observe combined (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial observer value" 11
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "left update result" 2
    (run_ok rt
       (Signal.Var.update_effect left (fun current ->
            Signal.Var.update_effect right (fun other ->
                Effect.pure (other + 5))
            |> Effect.map (fun _ -> current + 1))));
  Alcotest.(check int) "left source updated" 2 (Signal.Var.value left);
  Alcotest.(check int) "right source updated" 15 (Signal.Var.value right);
  Alcotest.(check int) "observer waits for stabilization" 11
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer sees both updates" 17
    (run_ok rt (Signal.Observer.read observer))

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
  let check_stats label expected actual =
    Alcotest.(check int)
      (label ^ " stabilization_count")
      expected.Signal.stabilization_count actual.Signal.stabilization_count;
    Alcotest.(check int)
      (label ^ " active_observer_count")
      expected.Signal.active_observer_count actual.Signal.active_observer_count;
    Alcotest.(check int)
      (label ^ " necessary_node_count")
      expected.Signal.necessary_node_count actual.Signal.necessary_node_count;
    Alcotest.(check int)
      (label ^ " stale_node_count")
      expected.Signal.stale_node_count actual.Signal.stale_node_count;
    Alcotest.(check int)
      (label ^ " recompute_count")
      expected.Signal.recompute_count actual.Signal.recompute_count;
    Alcotest.(check int)
      (label ^ " dynamic_scope_invalidations")
      expected.Signal.dynamic_scope_invalidations
      actual.Signal.dynamic_scope_invalidations;
    Alcotest.(check int)
      (label ^ " nodes_became_necessary")
      expected.Signal.nodes_became_necessary
      actual.Signal.nodes_became_necessary;
    Alcotest.(check int)
      (label ^ " nodes_became_unnecessary")
      expected.Signal.nodes_became_unnecessary
      actual.Signal.nodes_became_unnecessary
  in
  let before = run_ok rt (Signal.stats ()) in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source |> Signal.map (fun n -> n + 1) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  let after_observe = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool) "necessary transition counted" true
    (after_observe.Signal.nodes_became_necessary
     > before.Signal.nodes_became_necessary);
  Alcotest.(check int) "active observer increments"
    (before.Signal.active_observer_count + 1)
    after_observe.Signal.active_observer_count;
  Alcotest.(check bool) "necessary nodes visible" true
    (after_observe.Signal.necessary_node_count
     > before.Signal.necessary_node_count);
  Alcotest.(check bool) "stale nodes visible before stabilize" true
    (after_observe.Signal.stale_node_count > before.Signal.stale_node_count);
  run_ok rt Signal.stabilize;
  let after_stabilize = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "stabilization count increments"
    (before.Signal.stabilization_count + 1)
    after_stabilize.Signal.stabilization_count;
  Alcotest.(check bool) "recompute count visible" true
    (after_stabilize.Signal.recompute_count > before.Signal.recompute_count);
  Alcotest.(check bool) "stale nodes clear after stabilize" true
    (after_stabilize.Signal.stale_node_count
     < after_observe.Signal.stale_node_count);
  let after_stats_read = run_ok rt (Signal.stats ()) in
  check_stats "stats read-only" after_stabilize after_stats_read;
  let dot = run_ok rt (Signal.to_dot ()) in
  Alcotest.(check bool) "dot dump is non-empty" true (String.length dot > 0);
  let after_dot = run_ok rt (Signal.stats ()) in
  check_stats "dot read-only" after_stabilize after_dot;
  run_ok rt (Signal.Observer.dispose observer);
  let after_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "active observer decrements"
    before.Signal.active_observer_count
    after_dispose.Signal.active_observer_count;
  Alcotest.(check bool) "necessary nodes drop after dispose" true
    (after_dispose.Signal.necessary_node_count
     < after_stabilize.Signal.necessary_node_count);
  Alcotest.(check bool) "unnecessary transition counted" true
    (after_dispose.Signal.nodes_became_unnecessary
     > after_stabilize.Signal.nodes_became_unnecessary)

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
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe signal (record_observer events))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial observer event" 1 (List.length !events);
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "read before stabilize remains old" 0
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "timer tick did not run callback" 1
    (List.length !events);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "stabilized tick" 1
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !events with
   | [ Signal.Initialized 0; Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected timer update after explicit stabilize");
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

let test_time_absolute_deadline () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.deadline ~every:(Duration.ms 5) 10) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "initial absolute deadline" false
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "absolute deadline not reached" false
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "absolute deadline reached" true
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Async.yield ();
  Alcotest.(check int) "absolute deadline timer stopped" 0
    (Eta_test.Test_clock.sleeper_count clock);
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
  expect_fail "invalid now cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.now ~every:Duration.zero ())));
  expect_fail "invalid deadline cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.deadline ~every:Duration.zero 1)));
  expect_fail "invalid after interval" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:Duration.zero (Duration.ms 1))));
  expect_fail "invalid after duration" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) Duration.zero)));
  expect_fail "invalid step cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.step ~every:Duration.zero ~initial:0 succ)));
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

let test_stream_bridge_take_does_not_dispose_observer () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok rt (Signal.Stream.observe signal) in
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initialized stream update");
  Alcotest.(check int) "observer remains alive after take" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer still updates after take" 2
    (run_ok rt (Signal.Observer.read observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected changed stream update after take");
  run_ok rt (Signal.Observer.dispose observer)

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
          Alcotest.test_case "error pretty printers are clear" `Quick
            test_error_pretty_printers_are_clear;
          Alcotest.test_case "observer initializes on stabilize" `Quick
            test_observer_initializes_on_stabilize;
          Alcotest.test_case "observer unsafe read reports invalid state"
            `Quick test_observer_unsafe_read_exn_reports_invalid_state;
          Alcotest.test_case "manual stabilization coalesces sets" `Quick
            test_manual_stabilization_coalesces_sets;
          Alcotest.test_case "functor instances stabilize independently" `Quick
            test_functor_instances_stabilize_independently;
          Alcotest.test_case "diamond recomputes shared node once" `Quick
            test_diamond_recomputes_shared_node_once;
          Alcotest.test_case "recompute order is topological" `Quick
            test_recompute_order_is_topological;
          Alcotest.test_case "n-ary maps, both, and all" `Quick
            test_n_ary_maps_both_and_all;
          Alcotest.test_case "cutoff suppresses downstream recompute" `Quick
            test_cutoff_suppresses_downstream_recompute;
          Alcotest.test_case "source equality suppresses propagation" `Quick
            test_source_equality_suppresses_graph_propagation;
          Alcotest.test_case "default cutoff is physical equality" `Quick
            test_default_cutoff_is_physical_equality;
          Alcotest.test_case "observer equality is observer-local" `Quick
            test_observer_equality_suppresses_only_that_observer;
          Alcotest.test_case "observer callbacks run in registration order"
            `Quick
            test_observer_callbacks_run_in_registration_order;
          Alcotest.test_case "bind detaches old dependency" `Quick
            test_bind_detaches_old_dependency;
          Alcotest.test_case "bind invalidates old scope" `Quick
            test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes;
          Alcotest.test_case "bind selector failure preserves branch" `Quick
            test_bind_selector_failure_preserves_previous_branch;
          Alcotest.test_case "bind switch rollback preserves old branch" `Quick
            test_bind_switch_is_not_committed_when_later_pure_node_fails;
          Alcotest.test_case "bind cycle detection typed failure" `Quick
            test_bind_cycle_detection_is_typed_failure;
          Alcotest.test_case "unobserved nodes do not recompute" `Quick
            test_unobserved_nodes_do_not_recompute;
          Alcotest.test_case "observer mutation is delayed" `Quick
            test_observer_mutation_is_delayed_to_next_stabilization;
          Alcotest.test_case "observer read during callback" `Quick
            test_observer_read_during_callback_sees_current_snapshot;
          Alcotest.test_case "observer read does not force recompute" `Quick
            test_observer_read_does_not_force_recompute;
          Alcotest.test_case "dispose removes demand" `Quick
            test_dispose_removes_demand;
          Alcotest.test_case "dispose before initialization removes demand"
            `Quick
            test_dispose_before_initialization_removes_demand;
          Alcotest.test_case "pure failure does not publish snapshot" `Quick
            test_pure_failure_does_not_publish_partial_snapshot_and_can_retry;
          Alcotest.test_case "failed initial stabilize has no current" `Quick
            test_failed_initial_stabilization_leaves_no_current_value;
          Alcotest.test_case "cutoff exception preserves snapshot" `Quick
            test_cutoff_exception_is_defect_without_partial_snapshot;
          Alcotest.test_case "source equality exception preserves snapshot"
            `Quick
            test_source_equality_exception_is_defect_without_partial_snapshot;
          Alcotest.test_case "observer equality exception preserves snapshot"
            `Quick
            test_observer_equality_exception_is_defect_without_partial_snapshot;
          Alcotest.test_case "pure ambiguous node creation typed failure" `Quick
            test_ambiguous_node_creation_during_pure_recompute_is_typed_failure;
          Alcotest.test_case "observer ambiguous node creation typed failure"
            `Quick
            test_ambiguous_node_creation_during_observer_callback_is_typed_failure;
          Alcotest.test_case "observer failure fails stabilize" `Quick
            test_observer_failure_fails_stabilize;
          Alcotest.test_case "observer failure is fail-fast" `Quick
            test_observer_failure_is_fail_fast;
          Alcotest.test_case "observer effects survive later failure" `Quick
            test_observer_effects_before_later_failure_are_not_rolled_back;
          Alcotest.test_case "observer construction defect does not poison"
            `Quick
            test_observer_callback_construction_defect_does_not_poison_graph;
          Alcotest.test_case "reentrant stabilization typed failure" `Quick
            test_reentrant_stabilization_is_typed_failure;
          Alcotest.test_case "reentrant stabilization keeps outer phase" `Quick
            test_reentrant_stabilization_does_not_clear_outer_phase;
          Alcotest.test_case "effectful update reentry typed failure" `Quick
            test_effectful_update_reentry_fails_and_preserves_value;
          Alcotest.test_case "effectful update publishes once" `Quick
            test_effectful_update_success_publishes_once;
          Alcotest.test_case "effectful update allows other variable mutation"
            `Quick
            test_effectful_update_allows_other_variable_mutation;
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
          Alcotest.test_case "time absolute deadline" `Quick
            test_time_absolute_deadline;
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
          Alcotest.test_case "stream bridge take keeps observer" `Quick
            test_stream_bridge_take_does_not_dispose_observer;
          Alcotest.test_case "stream bridge backpressures" `Quick
            test_stream_bridge_backpressures_at_capacity;
        ] );
    ]
