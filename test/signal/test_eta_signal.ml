include Eta_signal_test_helpers

open Eta

exception Cleanup_interrupt =
  Eta_signal_test_interrupt_runtime.Cleanup_interrupt

module Cleanup_interrupt_runtime = Eta_signal_test_interrupt_runtime

module Make_isolated_sync_runtime () = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let root_scope = ()
  let fresh_counter = ref 0
  let now_ms () = 0
  let fresh () = incr fresh_counter; !fresh_counter
  let sleep _duration = ()
  let protect f = f ()
  let with_cancel_mask f =
    protect (fun () ->
        f
          {
            Runtime_contract.restore =
              (fun (type a) (body : unit -> a) -> body ());
          })
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = failwith "Make_isolated_sync_runtime.await_cancel"
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    match !resolver with
    | Some _ ->
        invalid_arg "Make_isolated_sync_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with
    | Some value -> value
    | None -> failwith "Make_isolated_sync_runtime.await_promise: unresolved"

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Make_isolated_sync_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()

  let locals : (int, Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_get local =
    match Hashtbl.find_opt locals (Runtime_contract.Backend.local_id local) with
    | None -> None
    | Some bindings ->
        List.find_map
          (Runtime_contract.Backend.local_binding_value local)
          bindings

  let local_with_binding local value f =
    let id = Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id
      (Runtime_contract.Local_binding (local, value) :: stack);
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      f
end

let run_effect_in_foreign_domain eff =
  run_in_domain @@ fun () ->
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  Runtime.run rt (widen eff)

let record_observer events update =
  events := update :: !events;
  Ok ()

let count_occurrences text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop index count =
    if needle_len = 0 || index + needle_len > text_len then count
    else if String.sub text index needle_len = needle then
      loop (index + needle_len) (count + 1)
    else loop (index + 1) count
  in
  loop 0 0

let force_signal_gc () =
  Gc.full_major ();
  Gc.compact ();
  Gc.full_major ()

let test_unnecessary_root_nodes_are_gc_reclaimable () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  expect_result_ok (Signal.stabilize ());
  force_signal_gc ();
  let before = expect_result_ok (Signal.stats ()) in
  let make_temporary_graph () =
    let source = Signal.Var.create 0 in
    let signal =
      Signal.Var.watch source |> Signal.map (fun value -> value + 1)
      |> Signal.map (fun value -> value * 2)
    in
    let observer =
      expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
    in
    expect_result_ok (Signal.stabilize ());
    expect_result_ok (Signal.Observer.dispose observer);
    expect_result_ok (Signal.stabilize ())
  in
  make_temporary_graph ();
  let after_dispose = expect_result_ok (Signal.stats ()) in
  Alcotest.(check bool) "temporary graph was indexed" true
    (after_dispose.Signal.total_node_count > before.Signal.total_node_count);
  force_signal_gc ();
  let after_gc = expect_result_ok (Signal.stats ()) in
  Alcotest.(check int) "temporary root nodes reclaimed"
    before.Signal.total_node_count after_gc.Signal.total_node_count

let test_recompute_order_is_topological () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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
    expect_result_ok (Signal.Observer.observe total ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check (list string))
    "initial topological recompute order"
    [ "shared"; "left"; "right"; "total" ]
    (List.rev !order);
  order := [];
  expect_result_ok (Signal.Var.set source 2);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check (list string))
    "updated topological recompute order"
    [ "shared"; "left"; "right"; "total" ]
    (List.rev !order);
  Alcotest.(check int) "updated value" 15
    (expect_result_ok (Signal.Observer.read observer))

let test_observer_graph_order_precedes_reverse_registration_fail_fast () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let upstream =
    Signal.Var.watch source |> Signal.map (fun value -> value + 1)
  in
  let downstream = Signal.map (fun value -> value * 10) upstream in
  let upstream_events = ref [] in
  let downstream_observer =
    expect_result_ok
      (Signal.Observer.observe downstream ~on_update:(function
        | Signal.Initialized _ -> Ok ()
        | Changed _ -> Error `Observer_failed))
  in
  let upstream_observer =
    expect_result_ok
      (Signal.Observer.observe upstream ~on_update:(function
        | Signal.Initialized _ -> Ok ()
        | Changed { new_value; _ } ->
            upstream_events := new_value :: !upstream_events;
            Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose downstream_observer);
      ignore (Signal.Observer.dispose upstream_observer))
    (fun () ->
      expect_result_ok (Signal.stabilize ());
      expect_result_ok (Signal.Var.set source 2);
      expect_result_fail "downstream observer failure"
        (function
          | `Observer_error `Observer_failed -> true
          | _ -> false)
        (Signal.stabilize ());
      Alcotest.(check (list int))
        "upstream observer ran before downstream fail-fast" [ 3 ]
        (List.rev !upstream_events))

let test_observer_graph_order_after_bind_switch_uses_new_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let selector = Signal.Var.create false in
  let data = Signal.Var.create 1 in
  let upstream_ref = ref None in
  let dynamic =
    Signal.bind (Signal.Var.watch selector) ~f:(fun use_upstream ->
        if use_upstream then
          match !upstream_ref with
          | Some upstream -> upstream
          | None -> Alcotest.fail "upstream not installed"
        else Signal.const 0)
  in
  let upstream =
    Signal.Var.watch data |> Signal.map (fun value -> value + 1)
  in
  upstream_ref := Some upstream;
  let upstream_events = ref [] in
  let dynamic_observer =
    expect_result_ok
      (Signal.Observer.observe dynamic ~on_update:(function
        | Signal.Initialized _ -> Ok ()
        | Changed _ -> Error `Observer_failed))
  in
  let upstream_observer =
    expect_result_ok
      (Signal.Observer.observe upstream ~on_update:(function
        | Signal.Initialized _ -> Ok ()
        | Changed { new_value; _ } ->
            upstream_events := new_value :: !upstream_events;
            Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose dynamic_observer);
      ignore (Signal.Observer.dispose upstream_observer))
    (fun () ->
      expect_result_ok (Signal.stabilize ());
      expect_result_ok (Signal.Var.set data 2);
      expect_result_ok (Signal.Var.set selector true);
      expect_result_fail "dynamic observer failure"
        (function
          | `Observer_error `Observer_failed -> true
          | _ -> false)
        (Signal.stabilize ());
      Alcotest.(check (list int))
        "new inner upstream observer ran before dynamic fail-fast" [ 3 ]
        (List.rev !upstream_events))

let test_observer_dispose_after_active_check_skips_callback () =
  (* A disposal from inside another observer's callback takes effect before
     the disposed observer's own callback is claimed in the same delivery
     plan. *)
  let module Signal = Eta_signal.Make (Observer_error) () in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let target_ref = ref None in
  let target_callback_ran = ref false in
  let arm_dispose = ref false in
  let marker =
    expect_result_ok
      (Signal.Observer.observe signal ~on_update:(function
        | Signal.Changed _ when !arm_dispose ->
            (match !target_ref with
            | None -> Alcotest.fail "target observer was not registered"
            | Some target -> ignore (Signal.Observer.dispose target));
            Ok ()
        | Initialized _ | Changed _ -> Ok ()))
  in
  let target =
    expect_result_ok
      (Signal.Observer.observe signal ~on_update:(fun _ ->
           target_callback_ran := true;
           Ok ()))
  in
  target_ref := Some target;
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose target);
      ignore (Signal.Observer.dispose marker))
    (fun () ->
      expect_result_ok (Signal.stabilize ());
      target_callback_ran := false;
      arm_dispose := true;
      expect_result_ok (Signal.Var.set source 2);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool)
        "disposed observer callback is skipped after active check" false
        !target_callback_ran;
      expect_result_fail "target disposed by active-check hook"
        (( = ) `Disposed_observer) (Signal.Observer.read target))

let test_bind_switches_after_unnecessary_source_change () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let selector_calls = ref [] in
  let bound =
    Signal.bind watched ~f:(fun value ->
        selector_calls := value :: !selector_calls;
        Signal.const ("branch " ^ string_of_int value))
  in
  let source_observer =
    expect_result_ok (Signal.Observer.observe watched ~on_update:(fun _ -> Ok ()))
  in
  let bound_observer =
    expect_result_ok (Signal.Observer.observe bound ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "initial branch" "branch 0"
    (expect_result_ok (Signal.Observer.read bound_observer));
  Alcotest.(check (list int))
    "initial selector call" [ 0 ] (List.rev !selector_calls);
  expect_result_ok (Signal.Observer.dispose bound_observer);
  expect_result_ok (Signal.Var.set source 1);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "source observer saw update" 1
    (expect_result_ok (Signal.Observer.read source_observer));
  Alcotest.(check (list int))
    "unnecessary bind not reselected" [ 0 ] (List.rev !selector_calls);
  let reobserved =
    expect_result_ok (Signal.Observer.observe bound ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "reobserved branch is current" "branch 1"
    (expect_result_ok (Signal.Observer.read reobserved));
  Alcotest.(check (list int))
    "bind reselected on reobserve" [ 0; 1 ] (List.rev !selector_calls);
  expect_result_ok (Signal.Observer.dispose source_observer);
  expect_result_ok (Signal.Observer.dispose reobserved)

let test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let left_calls = ref 0 in
  let right_calls = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
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
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let before_switch = expect_result_ok (Signal.stats ()) in
  Alcotest.(check int) "initial left value" 10
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check int) "left inner computed once" 1 !left_calls;
  Alcotest.(check int) "right inner not yet computed" 0 !right_calls;
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.stabilize ());
  let after_switch = expect_result_ok (Signal.stats ()) in
  Alcotest.(check bool)
    "scope invalidation counted" true
    (after_switch.Signal.dynamic_scope_invalidations
     > before_switch.Signal.dynamic_scope_invalidations);
  Alcotest.(check int) "switched right value" 20
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check int) "obsolete left inner not recomputed on switch" 1
    !left_calls;
  Alcotest.(check int) "right inner computed once" 1 !right_calls;
  expect_result_ok (Signal.Var.set left 99);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "obsolete left update does not recompute old scope" 1
    !left_calls;
  expect_result_ok (Signal.Var.set right 21);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "active right update recomputes active scope" 2
    !right_calls;
  Alcotest.(check int) "right value updates" 21
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_bind_rejects_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let selected =
    Signal.bind watched ~f:(fun _ ->
        match !captured with
        | Some stale -> stale
        | None ->
            let signal =
              Signal.map
                (fun value -> "branch " ^ string_of_int value)
                watched
            in
            captured := Some signal;
            signal)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "initial branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set source 1);
  expect_result_fail "reused dynamic-scope inner" (( = ) `Invalid_scope)
    (Signal.stabilize ());
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  captured := None;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_bind_rejects_root_wrapper_over_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let wrapper = ref None in
  let selected =
    Signal.bind watched ~f:(fun value ->
        match !wrapper with
        | Some wrapped when value = 1 -> wrapped
        | _ ->
            let signal =
              Signal.map
                (fun value -> "branch " ^ string_of_int value)
                watched
            in
            if value = 0 then captured := Some signal;
            signal)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "initial branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  let old_inner =
    match !captured with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  wrapper := Some (Signal.map (fun value -> value ^ " wrapped") old_inner);
  expect_result_ok (Signal.Var.set source 1);
  expect_result_fail "root wrapper over reused dynamic-scope inner" (( = ) `Invalid_scope)
    (Signal.stabilize ());
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  wrapper := None;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_bind_rejects_new_scope_wrapper_over_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let selected =
    Signal.bind watched ~f:(fun value ->
        match !captured with
        | Some stale when value = 1 ->
            Signal.map (fun value -> value ^ " wrapped") stale
        | _ ->
            let signal =
              Signal.map
                (fun value -> "branch " ^ string_of_int value)
                watched
            in
            if value = 0 then captured := Some signal;
            signal)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "initial branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set source 1);
  expect_result_fail "new-scope wrapper over reused dynamic-scope inner"
    (( = ) `Invalid_scope)
    (Signal.stabilize ());
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (expect_result_ok (Signal.Observer.read observer));
  captured := None;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_bind_accepts_ancestor_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let outer_source = Signal.Var.create true in
  let inner_source = Signal.Var.create 0 in
  let inner_watch = Signal.Var.watch inner_source in
  let selected =
    Signal.bind (Signal.Var.watch outer_source) ~f:(fun _ ->
        let ancestor = Signal.map (fun value -> value + 10) inner_watch in
        Signal.bind inner_watch ~f:(fun _ -> ancestor))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "initial ancestor inner" 10
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set inner_source 1);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "updated ancestor inner" 11
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_nested_bind_switches_newly_reachable_inner_same_stabilization () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let outer_enabled = Signal.Var.create false in
  let inner_right = Signal.Var.create false in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let stale_left_recomputes = ref 0 in
  let inner =
    Signal.bind (Signal.Var.watch inner_right) ~f:(fun use_right ->
        if use_right then Signal.Var.watch right
        else
          let branch =
            Signal.Var.watch left
            |> Signal.map (fun value ->
                   if Int.equal value 11 then incr stale_left_recomputes;
                   value)
          in
          captured_left := Some branch;
          branch)
  in
  let priming_observer =
    expect_result_ok (Signal.Observer.observe inner ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let left_branch =
    match !captured_left with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured inner branch"
  in
  let left_callbacks = ref 0 in
  let left_observer =
    expect_result_ok
      (Signal.Observer.observe left_branch ~on_update:(fun _ ->
           left_callbacks := !left_callbacks + 1;
            Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "inner branch observer initialized" 1 !left_callbacks;
  expect_result_ok (Signal.Observer.dispose priming_observer);
  let outer =
    Signal.bind (Signal.Var.watch outer_enabled) ~f:(fun enabled ->
        if enabled then inner else Signal.const (-1))
  in
  let outer_observer =
    expect_result_ok (Signal.Observer.observe outer ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "outer initially uses fallback" (-1)
    (expect_result_ok (Signal.Observer.read outer_observer));
  expect_result_ok (Signal.Var.set left 11);
  expect_result_ok (Signal.Var.set inner_right true);
  expect_result_ok (Signal.Var.set outer_enabled true);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "outer uses newly reachable inner branch" 20
    (expect_result_ok (Signal.Observer.read outer_observer));
  Alcotest.(check int) "stale inner branch did not recompute" 0
    !stale_left_recomputes;
  Alcotest.(check int) "stale inner branch observer was skipped" 1
    !left_callbacks;
  expect_result_fail "stale inner branch invalidated" (( = ) `Invalid_scope)
    (Signal.Observer.read left_observer);
  expect_result_ok (Signal.Observer.dispose left_observer);
  expect_result_ok (Signal.Observer.dispose outer_observer)

let test_bind_switch_invalidates_external_derived_branch_dependents () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let selected_observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let wrapped = Signal.map (fun value -> value + 1) captured in
  let wrapped_observer =
    expect_result_ok (Signal.Observer.observe wrapped ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "wrapped branch initialized" 11
    (expect_result_ok (Signal.Observer.read wrapped_observer));
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "selected switched to right" 20
    (expect_result_ok (Signal.Observer.read selected_observer));
  expect_result_fail "wrapped branch observer invalidated" (( = ) `Invalid_scope)
    (Signal.Observer.read wrapped_observer);
  expect_result_ok (Signal.Observer.dispose wrapped_observer);
  expect_result_ok (Signal.Var.set right 21);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "later stabilization ignores invalidated wrapper" 21
    (expect_result_ok (Signal.Observer.read selected_observer));
  expect_result_ok (Signal.Observer.dispose selected_observer)

let test_bind_switch_skips_stale_branch_observer_before_invalidation () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let stale_branch_recomputes = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then (
          let signal =
            Signal.Var.watch left
            |> Signal.map (fun value ->
                   if value = 11 then (
                     incr stale_branch_recomputes;
                     failwith "stale branch recomputed during bind switch");
                   value)
          in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let initial_selected_observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  expect_result_ok (Signal.Observer.dispose initial_selected_observer);
  let branch_observer =
    expect_result_ok (Signal.Observer.observe captured ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "branch observer initialized" 10
    (expect_result_ok (Signal.Observer.read branch_observer));
  let selected_observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.Var.set left 11);
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "selected switched to right" 20
    (expect_result_ok (Signal.Observer.read selected_observer));
  Alcotest.(check int) "stale branch was not recomputed" 0
    !stale_branch_recomputes;
  expect_result_fail "invalidated branch observer read" (( = ) `Invalid_scope)
    (Signal.Observer.read branch_observer);
  expect_result_ok (Signal.Observer.dispose branch_observer);
  expect_result_ok (Signal.Observer.dispose selected_observer)

let test_dynamic_scope_invalidation_skips_callback () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 0 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map Fun.id in
          captured_left := Some signal;
          signal)
        else Signal.const 0)
  in
  let selected_observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let branch =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let branch_callbacks = ref 0 in
  let branch_observer =
    expect_result_ok
      (Signal.Observer.observe branch ~on_update:(fun _ ->
           branch_callbacks := !branch_callbacks + 1;
            Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "branch observer initialized" 1 !branch_callbacks;
  expect_result_ok (Signal.Var.set left 1);
  expect_result_ok (Signal.Var.set choose_left false);
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Signal.Observer.dispose branch_observer);
      ignore
        (Signal.Observer.dispose selected_observer))
    (fun () ->
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int)
        "invalidated branch callback is skipped" 1 !branch_callbacks;
      expect_result_fail "invalidated branch observer read" (( = ) `Invalid_scope)
        (Signal.Observer.read branch_observer);
      Alcotest.(check int) "selected value is unchanged" 0
        (expect_result_ok (Signal.Observer.read selected_observer)))

let test_commit_skips_invalidated_staged_entries () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let selected_observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let branch_observer =
    expect_result_ok (Signal.Observer.observe captured ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.Var.set left 11);
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "selected switched to right" 20
    (expect_result_ok (Signal.Observer.read selected_observer));
  expect_result_fail "invalidated branch observer read" (( = ) `Invalid_scope)
    (Signal.Observer.read branch_observer);
  let options =
    {
      Signal.dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = false;
    }
  in
  let dot = Signal.to_dot ~options () in
  Alcotest.(check bool) "invalid observer shown" true
    (contains_substring dot "state=invalid_scope");
  Alcotest.(check bool) "invalid observer remains uninitialized" true
    (contains_substring dot "state=invalid_scope value_state=uninitialized");
  Alcotest.(check bool) "invalid observer did not commit current value" false
    (contains_substring dot "state=invalid_scope value_state=current");
  expect_result_ok (Signal.Observer.dispose branch_observer);
  expect_result_ok (Signal.Observer.dispose selected_observer)

let test_bind_selector_failure_preserves_previous_branch () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let fail_selector = ref true in
  let fail_inner = ref false in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then Signal.Var.watch left
        else if !fail_selector then failwith "selector"
        else
          Signal.Var.watch right
          |> Signal.map (fun value ->
                 if !fail_inner then failwith "inner";
                 value))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "initial left branch" 1
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set choose_left false);
  expect_raise "selector defect" (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int) "old snapshot remains after selector defect" 1
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set choose_left true);
  expect_result_ok (Signal.Var.set left 2);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "old branch is still active after failed switch" 2
    (expect_result_ok (Signal.Observer.read observer));
  fail_selector := false;
  fail_inner := true;
  expect_result_ok (Signal.Var.set choose_left false);
  expect_raise "inner branch defect" (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int) "old snapshot remains after inner defect" 2
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Var.set choose_left true);
  expect_result_ok (Signal.Var.set left 3);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "old branch remains active after inner defect" 3
    (expect_result_ok (Signal.Observer.read observer));
  fail_inner := false;
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "later successful switch reaches right branch" 10
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_bind_switch_is_not_committed_when_later_pure_node_fails () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let bad = Signal.Var.create 0 in
  let left_inner = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
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
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  let failing_observer =
    (expect_result_ok (Signal.Observer.observe failing ~on_update:(fun _ -> Ok ()))
      : int Signal.observer)
  in
  expect_result_ok (Signal.stabilize ());
  let old_inner =
    match !left_inner with
    | Some signal -> signal
    | None -> Alcotest.fail "left branch was not created"
  in
  Alcotest.(check int) "initial selected value" 1
    (expect_result_ok (Signal.Observer.read selected_observer));
  expect_result_ok (Signal.Var.set choose_left false);
  expect_result_ok (Signal.Var.set bad 1);
  expect_raise "later pure failure" (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  expect_result_ok (Signal.Observer.dispose failing_observer);
  let old_inner_observer =
    expect_result_ok (Signal.Observer.observe old_inner ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.Observer.dispose old_inner_observer);
  expect_result_ok (Signal.Observer.dispose selected_observer)

let test_dispose_unlinks_observer_from_graph () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let finalized = ref false in
  let create_and_dispose () =
    let payload = Bytes.make 1 '\000' in
    Gc.finalise (fun _ -> finalized := true) payload;
    let observer =
      expect_result_ok
        (Signal.Observer.observe (Signal.Var.watch source) ~on_update:(fun _ ->
             ignore (Bytes.get payload 0);
             Ok ()))
    in
    expect_result_ok (Signal.Observer.dispose observer)
  in
  create_and_dispose ();
  let rec force_collection attempts =
    Gc.full_major ();
    Gc.compact ();
    if !finalized then ()
    else if attempts = 0 then
      Alcotest.fail "disposed observer callback was retained by graph"
    else force_collection (attempts - 1)
  in
  force_collection 20

let test_time_timer_start_failure_retries_necessary_timer () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let fail_next_now = ref false in
  let now_ms () =
    if !fail_next_now then (
      fail_next_now := false;
      failwith "timer start clock failure")
    else Eta_test.Test_clock.now_ms clock
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let use_timer = Signal.Var.create false in
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun enabled ->
        if enabled then timer else Signal.const 0)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "initial non-timer branch" 0
    (expect_result_ok (Signal.Observer.read observer));
  fail_next_now := true;
  expect_result_ok (Signal.Var.set use_timer true);
  expect_raise "timer branch start failure" (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int) "failed start installed no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  expect_result_ok (Signal.stabilize ());
  wait_for_sleepers clock 1;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "timer restarted and ticked" 1
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_timer_start_failure_preserves_pending_observer_event () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let fail_next_now = ref false in
  let now_ms () =
    if !fail_next_now then (
      fail_next_now := false;
      failwith "timer start clock failure")
    else Eta_test.Test_clock.now_ms clock
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let use_timer = Signal.Var.create false in
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun enabled ->
        if enabled then timer else Signal.const (-1))
  in
  let events = ref [] in
  let event_new_values () =
    List.map
      (function
        | Signal.Initialized value -> value
        | Signal.Changed { new_value; _ } -> new_value)
      (List.rev !events)
  in
  let observer =
    expect_result_ok
      (Signal.Observer.observe selected ~on_update:(fun update ->
           events := update :: !events;
           Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let after_initial = expect_result_ok (Signal.stats ()) in
  fail_next_now := true;
  expect_result_ok (Signal.Var.set use_timer true);
  expect_raise "timer branch start failure" (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int)
    "post-commit failed start publishes snapshot for reads" 0
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check (list int)) "failed start did not deliver callback" [ -1 ]
    (event_new_values ());
  let after_failure = expect_result_ok (Signal.stats ()) in
  Alcotest.(check int) "failed cleanup does not complete delivery"
    after_initial.Signal.callback_delivery_count
    after_failure.Signal.callback_delivery_count;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check (list int)) "retry delivers pending event once" [ -1; 0 ]
    (event_new_values ());
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_timer_start_failure_rolls_back_unstarted_timers () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let fail_next_now = ref false in
  let now_ms () =
    if !fail_next_now then (
      fail_next_now := false;
      failwith "timer start clock failure")
    else Eta_test.Test_clock.now_ms clock
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let use_timers = Signal.Var.create false in
  let unstarted = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let failing = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observed =
    Signal.bind (Signal.Var.watch use_timers) ~f:(fun enabled ->
        if enabled then Signal.all [ failing; unstarted ]
        else Signal.const [ 0; 0 ])
  in
  let observer =
    expect_result_ok (Signal.Observer.observe observed ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  fail_next_now := true;
  expect_result_ok (Signal.Var.set use_timers true);
  expect_raise "multi-timer start failure"
    (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int) "failed refresh installed no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let options : Signal.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = false;
      dot_timers = true;
      dot_state = false;
      dot_dynamic_scopes = false;
    }
  in
  let dot = Signal.to_dot ~options () in
  Alcotest.(check int)
    "failed refresh leaves no active timer without a start" 0
    (count_occurrences dot
       "timer_active=true timer_running=none timer_cancel=false");
  expect_result_ok (Signal.stabilize ());
  wait_for_sleepers clock 2;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check (list int)) "both timers restart and tick" [ 1; 1 ]
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_concurrent_effectful_update_same_variable_fails_fast () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen
             (Signal.Var.update_effect source (fun current ->
                  Effect.sync (fun () ->
                      Eio.Promise.resolve started_resolver ();
                      Eio.Promise.await release;
                      current + 10)))))
  in
  Eio.Promise.await started;
  expect_fail "concurrent update" (( = ) `Reentrant_update)
    (Eta_eio.Runtime.run rt
       (widen
          (Signal.Var.update_effect source (fun current ->
               Effect.pure (current + 100)))));
  Alcotest.(check int) "failed concurrent update leaves value unchanged" 1
    (Signal.Var.value source);
  Eio.Promise.resolve release_resolver ();
  Alcotest.(check int) "first update succeeds" 11
    (expect_exit_ok "first update" (Eio.Promise.await_exn first));
  Alcotest.(check int) "slot released after first update" 12
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))))

let test_effectful_update_rejects_concurrent_set_same_variable () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let updating =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen
             (Signal.Var.update_effect source (fun current ->
                  Effect.sync (fun () ->
                      Eio.Promise.resolve started_resolver ();
                      Eio.Promise.await release;
                      current + 10)))))
  in
  Eio.Promise.await started;
  expect_result_fail "concurrent set" (( = ) `Reentrant_update)
    (Signal.Var.set source 100);
  Alcotest.(check int) "failed set leaves value unchanged" 1
    (Signal.Var.value source);
  Eio.Promise.resolve release_resolver ();
  Alcotest.(check int) "effectful update still commits" 11
    (expect_exit_ok "effectful update" (Eio.Promise.await_exn updating));
  Alcotest.(check int) "slot released after update" 12
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))))

let test_effectful_update_interruption_preserves_value_and_releases_slot () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let with_late_timer_wake f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref 0 in
  let sleep_calls = ref 0 in
  let hold, hold_resolver = Eio.Promise.create () in
  let released = ref false in
  let sleep _duration =
    incr sleep_calls;
    if !sleep_calls = 1 then now_ms := 100
    else Eio.Promise.await hold
  in
  let release () =
    if not !released then (
      released := true;
      Eio.Promise.resolve hold_resolver ())
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep
      ~now_ms:(fun () -> !now_ms)
      ()
  in
  f rt sleep_calls release

let test_time_interval_catches_up_after_late_sleep () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_late_timer_wake @@ fun rt sleep_calls release ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_until "late interval wake rescheduled" (fun () -> !sleep_calls >= 2);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "late interval wake catches up" 10
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer);
  release ()

let with_cooperative_timer_host ?(initial_ms = 0) ?(jump_ms = 10_000) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref initial_ms in
  let sleep_calls = ref 0 in
  let yield_calls = ref 0 in
  let logger = Eta_observability.Logger.in_memory () in
  let module Unix = struct
    let run_in_systhread ?label:_ f = f ()
  end in
  let module Eio_ops = struct
    module Time = struct
      let now _clock = float_of_int !now_ms /. 1000.0

      let sleep _clock _seconds =
        incr sleep_calls;
        if !sleep_calls = 1 then now_ms := jump_ms
        else raise (Eio.Cancel.Cancelled (Failure "timer catch-up test stop"))
    end

    module Net = struct
      let getaddrinfo_stream ?service:_ _net _host = []
      let connect ~sw:_ _net _addr = failwith "unused net connect"
    end

    module Flow = struct
      let single_read _source _buffer = failwith "unused flow read"
      let write _sink _buffers = failwith "unused flow write"
    end

    module Switch = struct
      let run = Eio.Switch.run
      let fail = Eio.Switch.fail
    end

    module Fiber = struct
      let get = Eio.Fiber.get
      let with_binding = Eio.Fiber.with_binding
      let first = Eio.Fiber.first
      let await_cancel = Eio.Fiber.await_cancel
      let fork = Eio.Fiber.fork
      let fork_daemon = Eio.Fiber.fork_daemon

      let yield () =
        incr yield_calls;
        Eio.Fiber.yield ()

      let check = Eio.Fiber.check
    end

    module Stream = struct
      type 'a t = 'a Eio.Stream.t

      let create = Eio.Stream.create
      let add = Eio.Stream.add
      let take = Eio.Stream.take
      let take_nonblocking = Eio.Stream.take_nonblocking
    end

    module Cancel = struct
      let sub = Eio.Cancel.sub
      let cancel = Eio.Cancel.cancel
    end
  end in
  let host =
    Eta_eio.Host.make ~unix:(module Unix) ~eio:(module Eio_ops) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock env)
    ~now_ms:(fun () -> !now_ms) ~logger:(Eta_observability.Logger.as_capability logger)
  @@ fun rt ->
  f rt sleep_calls yield_calls logger

let test_time_large_catch_up_applies_beyond_old_cap () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~jump_ms:10_250
  @@ fun rt sleep_calls yield_calls logger ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_until "large catch-up processed" (fun () -> !sleep_calls >= 2);
  Alcotest.(check int) "large interval catch-up coalesced" 0 !yield_calls;
  Alcotest.(check int) "large catch-up logs no daemon diagnostic" 0
    (List.length (Eta_observability.Logger.dump logger));
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "large catch-up applies every interval cadence" 1_025
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer);
  Alcotest.(check int) "dispose logs no daemon diagnostic" 0
    (List.length (Eta_observability.Logger.dump logger))

let test_time_interval_saturated_catch_up_coalesces () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls yield_calls logger ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 1)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_until "saturated interval catch-up processed" (fun () ->
      !sleep_calls >= 1);
  Alcotest.(check int) "saturated interval catch-up did not batch-yield" 0
    !yield_calls;
  Alcotest.(check int) "saturated interval catch-up logs no daemon diagnostic" 0
    (List.length (Eta_observability.Logger.dump logger));
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "saturated interval catch-up reaches max_int" max_int
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_deadline_saturated_catch_up_does_not_overflow () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  (* Start at -1 so the first 1ms cadence is due at 0, reproducing the
     saturated successor edge through public timer APIs. *)
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls _yield_calls logger ->
  let signal =
    run_ok rt (Signal.Time.after (Duration.ms 2))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_until "saturated deadline timer woke" (fun () -> !sleep_calls >= 1);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool) "saturated catch-up reaches deadline" true
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check int) "saturated catch-up logs no daemon diagnostic" 0
    (List.length (Eta_observability.Logger.dump logger));
  expect_result_ok (Signal.Observer.dispose observer)

let with_delayed_first_daemon_start_host f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let daemon_started, daemon_started_resolver = Eio.Promise.create () in
  let daemon_release, daemon_release_resolver = Eio.Promise.create () in
  let daemon_delayed = ref false in
  let daemon_released = ref false in
  let release_daemon () =
    if not !daemon_released then (
      daemon_released := true;
      Eio.Promise.resolve daemon_release_resolver ())
  in
  let module Eio_ops = struct
    module Time = struct
      let now _clock =
        float_of_int (Eta_test.Test_clock.now_ms clock) /. 1000.0

      let sleep _clock seconds =
        Eta_test.Test_clock.sleep clock
          (Duration.ms (int_of_float (seconds *. 1000.0)))
    end

    module Net = Eio.Net
    module Flow = Eio.Flow
    module Switch = Eio.Switch

    module Fiber = struct
      let get = Eio.Fiber.get
      let with_binding = Eio.Fiber.with_binding
      let first = Eio.Fiber.first
      let await_cancel = Eio.Fiber.await_cancel
      let fork = Eio.Fiber.fork

      let fork_daemon ~sw f =
        if !daemon_delayed then Eio.Fiber.fork_daemon ~sw f
        else (
          daemon_delayed := true;
          Eio.Fiber.fork_daemon ~sw (fun () ->
              Eio.Promise.resolve daemon_started_resolver ();
              Eio.Promise.await daemon_release;
              f ()))

      let yield = Eio.Fiber.yield
      let check = Eio.Fiber.check
    end

    module Stream = Eio.Stream
    module Cancel = Eio.Cancel
  end in
  let host =
    Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock env) @@ fun rt ->
  f sw clock rt daemon_started release_daemon

let test_time_timer_dispose_before_cancel_install_exits_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_delayed_first_daemon_start_host
  @@ fun sw clock rt daemon_started release_daemon ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Eio.Promise.await daemon_started;
  Alcotest.(check int) "uncancellable start has not installed a sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  expect_result_ok (Signal.Observer.dispose observer);
  release_daemon ();
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.drain rt)
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "uncancellable start exits after demand disappears" true
    (Eio.Promise.is_resolved drained);
  Eio.Promise.await_exn drained;
  Alcotest.(check int) "stopped uncancellable start installed no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock)

let test_time_now_update_on_start_demand_drop_does_not_queue_source () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt_ref = ref None in
  let observer_ref = ref None in
  let now_calls = ref 0 in
  let drop_demand_during_update_on_start = ref false in
  let now_ms () =
    incr now_calls;
    if !drop_demand_during_update_on_start && !now_calls = 3 then (
      (match (!rt_ref, !observer_ref) with
       | Some rt, Some observer -> expect_result_ok (Signal.Observer.dispose observer)
       | _ -> Alcotest.fail "missing observer for update-on-start demand drop");
      30)
    else if !now_calls >= 2 then 20
    else 0
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  rt_ref := Some rt;
  let use_timer = Signal.Var.create false in
  let now_signal =
    run_ok rt (Signal.Time.now ~every:(Duration.days 1))
    |> Signal.map Signal.Time.to_ms
  in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun use_timer ->
        if use_timer then now_signal else Signal.const (-1))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  observer_ref := Some observer;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "initial inactive branch" (-1)
    (expect_result_ok (Signal.Observer.read observer));
  drop_demand_during_update_on_start := true;
  expect_result_ok (Signal.Var.set use_timer true);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "start update was stopped before daemon start" 3
    !now_calls;
  expect_result_fail "observer disposed during update_on_start"
    (( = ) `Disposed_observer)
    (Signal.Observer.read observer);
  Alcotest.(check int) "stopped update_on_start installed no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let options : Signal.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = false;
      dot_timers = true;
      dot_state = true;
      dot_dynamic_scopes = false;
    }
  in
  let dot = Signal.to_dot ~options () in
  Alcotest.(check int) "stopped update_on_start queued no source update" 0
    (count_occurrences dot "queued=true");
  Alcotest.(check int) "stopped update_on_start left no uncancellable timer" 0
    (count_occurrences dot "timer_state=running_uncancellable")

let test_time_timer_becomes_inert_after_dispose () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.Observer.dispose observer);
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "disposed timer did not reschedule" 0
    (Eta_test.Test_clock.sleeper_count clock)

let test_time_timer_dispose_cancels_sleeping_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.Observer.dispose observer);
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.drain rt)
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "disposed long-interval timer daemon drains without clock advance" true
    (Eio.Promise.is_resolved drained);
  Eio.Promise.await_exn drained

let test_time_after_daemon_sleeps_until_exact_deadline () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let sleep_calls = ref 0 in
  let sleep duration =
    incr sleep_calls;
    Eta_test.Test_clock.sleep clock duration
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  let signal = run_ok rt (Signal.Time.after (Duration.ms 50)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool) "one-shot timer starts false" false
    (expect_result_ok (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 30);
  Eta_test.Async.yield ();
  Alcotest.(check int) "one-shot daemon did not poll before the deadline" 1
    !sleep_calls;
  Alcotest.(check bool) "still pending before the exact deadline" false
    (expect_result_ok (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 30);
  wait_until "one-shot daemon finished at the exact deadline" (fun () ->
      !sleep_calls = 1 && Eta_test.Test_clock.sleeper_count clock = 0);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool) "one-shot timer fired at the exact deadline" true
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check int) "one-shot daemon slept exactly once" 1 !sleep_calls;
  expect_result_ok (Signal.Observer.dispose observer)

let with_timer_cancel_tracking_host ?(run_cancel = true) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let owner_domain = Domain.self () in
  let graph_lifecycle_depth_key = Eio.Fiber.create_key () in
  let cancel_inside_local_binding = ref false in
  let cancel_outside_owner_domain = ref false in
  let fail_next_cancel = ref false in
  let graph_lifecycle_exit_count = ref 0 in
  let after_graph_lifecycle_exit : (int * (unit -> unit)) option ref =
    ref None
  in
  let graph_lifecycle_depth () =
    try Option.value (Eio.Fiber.get graph_lifecycle_depth_key) ~default:0
    with Stdlib.Effect.Unhandled _ -> 0
  in
  (* Eta_eio transports Runtime_contract locals as one context table. With
     Eta_observability.Tracer.noop below and auto-instrumentation disabled by default, the only
     immediate [1] local in this harness is eta_signal's graph-lane depth. *)
  let local_binding_is_graph_lifecycle_depth =
    function
    | Runtime_contract.Local_binding (_, value) ->
        let value = Obj.repr value in
        Obj.is_int value && (Obj.magic value : int) = 1
  in
  let context_has_graph_lifecycle_depth value =
    let value = Obj.repr value in
    (not (Obj.is_int value))
    &&
    let context :
        (int, Runtime_contract.local_binding list) Hashtbl.t =
      Obj.magic value
    in
    Hashtbl.fold
      (fun _ bindings found ->
        found || List.exists local_binding_is_graph_lifecycle_depth bindings)
      context false
  in
  let module Eio_ops = struct
    module Time = struct
      let now _clock =
        float_of_int (Eta_test.Test_clock.now_ms clock) /. 1000.0

      let sleep _clock seconds =
        Eta_test.Test_clock.sleep clock
          (Duration.ms (int_of_float (seconds *. 1000.0)))
    end

    module Net = Eio.Net
    module Flow = Eio.Flow
    module Switch = Eio.Switch

    module Fiber = struct
      let get = Eio.Fiber.get

      let with_binding key value f =
        let graph_lifecycle_binding = context_has_graph_lifecycle_depth value in
        let depth =
          if graph_lifecycle_binding then graph_lifecycle_depth () + 1
          else graph_lifecycle_depth ()
        in
        Eio.Fiber.with_binding graph_lifecycle_depth_key depth
          (fun () ->
            let result = Eio.Fiber.with_binding key value f in
            if graph_lifecycle_binding then (
              incr graph_lifecycle_exit_count;
              match !after_graph_lifecycle_exit with
              | Some (target_count, hook)
                when Int.equal target_count !graph_lifecycle_exit_count ->
                  hook ()
              | Some _ | None -> ());
            result)

      let first = Eio.Fiber.first
      let await_cancel = Eio.Fiber.await_cancel
      let fork = Eio.Fiber.fork
      let fork_daemon = Eio.Fiber.fork_daemon
      let yield = Eio.Fiber.yield
      let check = Eio.Fiber.check
    end

    module Stream = Eio.Stream

    module Cancel = struct
      let sub = Eio.Cancel.sub

      let cancel cancel_context exn =
        if Domain.self () <> owner_domain then
          cancel_outside_owner_domain := true;
        if graph_lifecycle_depth () > 0 then
          cancel_inside_local_binding := true;
        if run_cancel then Eio.Cancel.cancel cancel_context exn;
        if !fail_next_cancel then (
          fail_next_cancel := false;
          failwith "timer cancel failure")
    end
  end in
  let host =
    Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock env)
    ~tracer:Eta_observability.Tracer.noop @@ fun rt ->
  f clock rt cancel_inside_local_binding cancel_outside_owner_domain
    fail_next_cancel sw graph_lifecycle_exit_count after_graph_lifecycle_exit

let test_time_timer_cancel_runs_outside_graph_lifecycle () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt cancel_inside_local_binding cancel_outside_owner_domain
         _fail_next_cancel _sw _graph_lifecycle_exit_count
         _after_graph_lifecycle_exit ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.Observer.dispose observer);
  Alcotest.(check bool)
    "timer cancel ran outside graph lifecycle local binding" false
    !cancel_inside_local_binding;
  Alcotest.(check bool)
    "timer cancel ran on owner domain" false !cancel_outside_owner_domain

let test_time_invalidated_timer_cancel_runs_outside_graph_lifecycle () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt cancel_inside_local_binding cancel_outside_owner_domain
         _fail_next_cancel _sw _graph_lifecycle_exit_count
         _after_graph_lifecycle_exit ->
  let use_timer = Signal.Var.create true in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun active ->
        if active then run_ok rt (Signal.Time.interval (Duration.days 1))
        else Signal.const 0)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.Var.set use_timer false);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool)
    "invalidated timer cancel ran outside graph lifecycle local binding" false
    !cancel_inside_local_binding;
  Alcotest.(check bool)
    "invalidated timer cancel ran on owner domain" false
    !cancel_outside_owner_domain;
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_timer_cancel_failure_preserves_committed_snapshot () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt _cancel_inside_local_binding _cancel_outside_owner_domain
         fail_next_cancel _sw _graph_lifecycle_exit_count
         _after_graph_lifecycle_exit ->
  let use_timer = Signal.Var.create true in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun active ->
        if active then run_ok rt (Signal.Time.interval (Duration.days 1))
        else Signal.const 42)
  in
  let callback_values = ref [] in
  let observer =
    expect_result_ok
      (Signal.Observer.observe selected ~on_update:(function
        | Signal.Initialized value | Changed { new_value = value; _ } ->
            callback_values := value :: !callback_values;
            Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  wait_for_sleepers clock 1;
  Alcotest.(check (list int))
    "initial callback delivered" [ 0 ] (List.rev !callback_values);
  fail_next_cancel := true;
  expect_result_ok (Signal.Var.set use_timer false);
  expect_raise "timer cancel failure"
    (function Failure _ -> true | _ -> false)
    (fun () -> ignore (Signal.stabilize ()));
  Alcotest.(check int)
    "snapshot committed before timer cancel failure" 42
    (expect_result_ok (Signal.Observer.read observer));
  Alcotest.(check (list int))
    "timer cancel failure did not deliver callback" [ 0 ]
    (List.rev !callback_values);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check (list int))
    "retry delivers pending branch switch" [ 0; 42 ]
    (List.rev !callback_values);
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_invalidated_timer_cancels_sleeping_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let use_timer = Signal.Var.create true in
  let created_timers = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) ~f:(fun use_timer ->
        if use_timer then (
          incr created_timers;
          run_ok rt (Signal.Time.interval (Duration.days 1)))
        else Signal.const 0)
  in
  let observer =
    expect_result_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  wait_for_sleepers clock 1;
  Alcotest.(check int) "dynamic timer created once" 1 !created_timers;
  expect_result_ok (Signal.Var.set use_timer false);
  expect_result_ok (Signal.stabilize ());
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.drain rt)
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "invalidated long-interval timer daemon drains without clock advance" true
    (Eio.Promise.is_resolved drained);
  Eio.Promise.await_exn drained;
  expect_result_ok (Signal.Observer.dispose observer)

let test_time_now_backward_clock_refresh_overrides_pending_update () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 10))
    |> Signal.map Signal.Time.to_ms
  in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "initial now" 0
    (expect_result_ok (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 10;
  wait_for_sleepers clock 1;
  Eta_test.Test_clock.set_time clock 0;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "backward refresh wins over pending update" 0
    (expect_result_ok (Signal.Observer.read observer));
  expect_result_ok (Signal.Observer.dispose observer)

let with_blocked_timer_daemon f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref 0 in
  let sleep_calls = ref 0 in
  let hold, hold_resolver = Eio.Promise.create () in
  let released = ref false in
  let sleep _duration =
    incr sleep_calls;
    Eio.Promise.await hold
  in
  let release () =
    if not !released then (
      released := true;
      Eio.Promise.resolve hold_resolver ())
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep
      ~now_ms:(fun () -> !now_ms)
      ()
  in
  Fun.protect ~finally:release (fun () -> f rt now_ms sleep_calls)

let test_time_deadline_catches_up_without_daemon_yield () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal =
    run_ok rt (Signal.Time.after (Duration.ms 100))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "deadline daemon is sleeping" (fun () -> !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool) "before deadline" false
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := 150;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool) "after deadline" true
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_interval_catches_up_arithmetically_without_daemon_yield () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "initial" 0
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := 55;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "5 missed cadences" 5
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_interval_does_not_recount_saturated_due () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  now_ms := max_int - 1;
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 1)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "initial interval" 0
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := max_int;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "saturated due counted once" 1
        (expect_result_ok (Signal.Observer.read observer));
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "saturated due is not recounted" 1
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_deadline_refresh_retries_after_downstream_defect () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let deadline =
    run_ok rt (Signal.Time.after (Duration.ms 100))
  in
  let raised = ref false in
  let checked =
    Signal.map
      (fun due ->
        if due && not !raised then (
          raised := true;
          failwith "deadline refresh rollback");
        due)
      deadline
  in
  let observer =
    expect_result_ok (Signal.Observer.observe checked ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "deadline daemon is sleeping" (fun () -> !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool) "before deadline" false
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := 150;
      expect_raise "deadline refresh rollback" (function Failure _ -> true | _ -> false)
        (fun () -> ignore (Signal.stabilize ()));
      Alcotest.(check bool) "rolled back deadline snapshot" false
        (expect_result_ok (Signal.Observer.read observer));
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool) "deadline refresh retried" true
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_interval_refresh_retries_after_downstream_defect () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let interval = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let raised = ref false in
  let checked =
    Signal.map
      (fun count ->
        if count > 0 && not !raised then (
          raised := true;
          failwith "interval refresh rollback");
        count)
      interval
  in
  let observer =
    expect_result_ok (Signal.Observer.observe checked ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "initial" 0
        (expect_result_ok (Signal.Observer.read observer));
      let before_failure_stats = expect_result_ok (Signal.stats ()) in
      now_ms := 55;
      expect_raise "interval refresh rollback" (function Failure _ -> true | _ -> false)
        (fun () -> ignore (Signal.stabilize ()));
      Alcotest.(check int) "rolled back interval snapshot" 0
        (expect_result_ok (Signal.Observer.read observer));
      Alcotest.(check int)
        "rolled back interval refresh dirty flags"
        before_failure_stats.Signal.live_dirty_node_count
        (expect_result_ok (Signal.stats ())).Signal.live_dirty_node_count;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "interval refresh retried" 5
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_active_deadline_refreshes_before_daemon_runs () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal =
    run_ok rt (Signal.Time.after (Duration.ms 10))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "active deadline daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool) "initial active deadline" false
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := 10;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check bool)
        "active deadline refreshes during stabilization before daemon resumes"
        true
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_deadline_on_demand_finish_cancels_running_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.after (Duration.ms 5))
  in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  wait_for_sleepers clock 1;
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool) "initial deadline" false
    (expect_result_ok (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check bool) "deadline finished by on-demand refresh" true
    (expect_result_ok (Signal.Observer.read observer));
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.drain rt)
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  let drained_without_clock_advance = Eio.Promise.is_resolved drained in
  if not drained_without_clock_advance then (
    Eta_test.Test_clock.adjust clock (Duration.days 1);
    for _ = 1 to 5 do
      Eta_test.Async.yield ()
    done;
    Eio.Promise.await_exn drained);
  expect_result_ok (Signal.Observer.dispose observer);
  Alcotest.(check bool)
    "on-demand deadline finish cancels sleeping daemon" true
    drained_without_clock_advance

let test_time_active_interval_refreshes_before_daemon_runs () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 5)) in
  let observer =
    expect_result_ok (Signal.Observer.observe signal ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "active interval daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "initial active interval" 0
        (expect_result_ok (Signal.Observer.read observer));
      now_ms := 20;
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int)
        "active interval catches up during stabilization before daemon resumes"
        4
        (expect_result_ok (Signal.Observer.read observer)))

let test_time_active_timer_refresh_does_not_restart_pure_pass () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let source = Signal.Var.create 1 in
  let pure_runs = ref 0 in
  let mapped =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr pure_runs;
           value)
  in
  let deadline =
    run_ok rt (Signal.Time.after (Duration.ms 10))
  in
  let combined =
    Signal.map2 (fun value due -> if due then value else 0) mapped deadline
  in
  let observer =
    expect_result_ok (Signal.Observer.observe combined ~on_update:(fun _ -> Ok ()))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      wait_until "active deadline daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "initial combined value" 0
        (expect_result_ok (Signal.Observer.read observer));
      pure_runs := 0;
      now_ms := 10;
      expect_result_ok (Signal.Var.set source 2);
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "refreshed combined value" 2
        (expect_result_ok (Signal.Observer.read observer));
      Alcotest.(check int) "pre-timer pure closure ran once" 1 !pure_runs)

let () =
  Alcotest.run "eta_signal"
    [
      ( "core",
        [
          Alcotest.test_case "unnecessary root nodes are gc reclaimable" `Quick
            test_unnecessary_root_nodes_are_gc_reclaimable;
          Alcotest.test_case "recompute order is topological" `Quick
            test_recompute_order_is_topological;
          Alcotest.test_case
            "observer graph order precedes reverse registration fail-fast"
            `Quick
            test_observer_graph_order_precedes_reverse_registration_fail_fast;
          Alcotest.test_case
            "observer graph order uses staged bind switch" `Quick
            test_observer_graph_order_after_bind_switch_uses_new_inner;
          Alcotest.test_case "observer dispose after active check skips callback"
            `Quick test_observer_dispose_after_active_check_skips_callback;
          Alcotest.test_case
            "bind switches after unnecessary source change" `Quick
            test_bind_switches_after_unnecessary_source_change;
          Alcotest.test_case "bind invalidates old scope" `Quick
            test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes;
          Alcotest.test_case "bind rejects reused dynamic-scope inner" `Quick
            test_bind_rejects_reused_dynamic_scope_inner;
          Alcotest.test_case
            "bind rejects root wrapper over reused dynamic-scope inner" `Quick
            test_bind_rejects_root_wrapper_over_reused_dynamic_scope_inner;
          Alcotest.test_case
            "bind rejects new-scope wrapper over reused dynamic-scope inner"
            `Quick
            test_bind_rejects_new_scope_wrapper_over_reused_dynamic_scope_inner;
          Alcotest.test_case "bind accepts ancestor dynamic-scope inner" `Quick
            test_bind_accepts_ancestor_dynamic_scope_inner;
          Alcotest.test_case
            "nested bind switches newly reachable inner same stabilization"
            `Quick
            test_nested_bind_switches_newly_reachable_inner_same_stabilization;
          Alcotest.test_case "bind switch invalidates external branch dependents"
            `Quick test_bind_switch_invalidates_external_derived_branch_dependents;
          Alcotest.test_case "bind switch skips stale branch observer" `Quick
            test_bind_switch_skips_stale_branch_observer_before_invalidation;
          Alcotest.test_case "dynamic scope invalidation skips callback" `Quick
            test_dynamic_scope_invalidation_skips_callback;
          Alcotest.test_case "commit skips invalidated staged entries" `Quick
            test_commit_skips_invalidated_staged_entries;
          Alcotest.test_case "bind selector failure preserves branch" `Quick
            test_bind_selector_failure_preserves_previous_branch;
          Alcotest.test_case "bind switch rollback preserves old branch" `Quick
            test_bind_switch_is_not_committed_when_later_pure_node_fails;
          Alcotest.test_case "dispose unlinks observer from graph" `Quick
            test_dispose_unlinks_observer_from_graph;
          Alcotest.test_case "time timer start failure retries necessary timer"
            `Quick test_time_timer_start_failure_retries_necessary_timer;
          Alcotest.test_case
            "time timer start failure preserves pending observer event" `Quick
            test_time_timer_start_failure_preserves_pending_observer_event;
          Alcotest.test_case "time timer start failure rolls back unstarted timers"
            `Quick test_time_timer_start_failure_rolls_back_unstarted_timers;
          Alcotest.test_case "concurrent effectful update fails fast" `Quick
            test_concurrent_effectful_update_same_variable_fails_fast;
          Alcotest.test_case
            "effectful update rejects concurrent set on same variable" `Quick
            test_effectful_update_rejects_concurrent_set_same_variable;
          Alcotest.test_case "effectful update interruption cleanup" `Quick
            test_effectful_update_interruption_preserves_value_and_releases_slot;
          Alcotest.test_case "time interval catches up after late sleep" `Quick
            test_time_interval_catches_up_after_late_sleep;
          Alcotest.test_case "time interval does not recount saturated due"
            `Quick test_time_interval_does_not_recount_saturated_due;
          Alcotest.test_case "time large catch-up applies beyond old cap" `Quick
            test_time_large_catch_up_applies_beyond_old_cap;
          Alcotest.test_case "time interval saturated catch-up coalesces" `Quick
            test_time_interval_saturated_catch_up_coalesces;
          Alcotest.test_case "time deadline saturated catch-up does not overflow"
            `Quick test_time_deadline_saturated_catch_up_does_not_overflow;
          Alcotest.test_case
            "time timer dispose before cancel install exits daemon" `Quick
            test_time_timer_dispose_before_cancel_install_exits_daemon;
          Alcotest.test_case
            "time now update_on_start stops after demand drop" `Quick
            test_time_now_update_on_start_demand_drop_does_not_queue_source;
          Alcotest.test_case "time timer inert after dispose" `Quick
            test_time_timer_becomes_inert_after_dispose;
          Alcotest.test_case "time timer dispose cancels sleeping daemon" `Quick
            test_time_timer_dispose_cancels_sleeping_daemon;
          Alcotest.test_case "time after daemon sleeps until exact deadline"
            `Quick test_time_after_daemon_sleeps_until_exact_deadline;
          Alcotest.test_case "time timer cancel outside graph lifecycle" `Quick
            test_time_timer_cancel_runs_outside_graph_lifecycle;
          Alcotest.test_case
            "time invalidated timer cancel outside graph lifecycle" `Quick
            test_time_invalidated_timer_cancel_runs_outside_graph_lifecycle;
          Alcotest.test_case "time timer cancel failure keeps snapshot" `Quick
            test_time_timer_cancel_failure_preserves_committed_snapshot;
          Alcotest.test_case "time invalidated timer cancels sleeping daemon"
            `Quick test_time_invalidated_timer_cancels_sleeping_daemon;
          Alcotest.test_case "time now backward refresh overrides pending update"
            `Quick
            test_time_now_backward_clock_refresh_overrides_pending_update;
          Alcotest.test_case "time deadline catches up without daemon yield"
            `Quick test_time_deadline_catches_up_without_daemon_yield;
          Alcotest.test_case
            "time interval catches up arithmetically without daemon yield"
            `Quick
            test_time_interval_catches_up_arithmetically_without_daemon_yield;
          Alcotest.test_case
            "time deadline refresh retries after downstream defect" `Quick
            test_time_deadline_refresh_retries_after_downstream_defect;
          Alcotest.test_case
            "time interval refresh retries after downstream defect" `Quick
            test_time_interval_refresh_retries_after_downstream_defect;
          Alcotest.test_case "time active deadline refreshes before daemon"
            `Quick test_time_active_deadline_refreshes_before_daemon_runs;
          Alcotest.test_case
            "time deadline on-demand finish cancels running daemon" `Quick
            test_time_deadline_on_demand_finish_cancels_running_daemon;
          Alcotest.test_case "time active interval refreshes before daemon"
            `Quick test_time_active_interval_refreshes_before_daemon_runs;
          Alcotest.test_case "time active timer refresh does not restart pure pass"
            `Quick test_time_active_timer_refresh_does_not_restart_pure_pass;
        ] );
    ]
