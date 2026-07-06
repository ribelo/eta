let () =
  match Sys.getenv_opt "EIO_BACKEND" with
  | None | Some "" ->
      (Unix.putenv [@alert "-unsafe_multidomain"]) "EIO_BACKEND" "posix"
  | Some _ -> ()

open Eta

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

(* Most tests shadow [Signal] with a fresh functor instance so graph indexes do
   not accumulate across cases. These public top-level instances are kept for
   tests that deliberately exercise cross-instance behavior. *)
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

let expect_exact_runtime_mismatch label = function
  | Exit.Error (Cause.Fail `Runtime_mismatch) -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected only Runtime_mismatch, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected Runtime_mismatch, got Ok" label

let counter_overflow name = function
  | `Counter_overflow actual -> String.equal actual name
  | _ -> false

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

let rec finalizer_has_die_message expected = function
  | Cause.Finalizer.Die die ->
      contains_substring (Printexc.to_string die.exn) expected
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> false
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_die_message expected) causes
  | Cause.Finalizer.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_die_message expected primary
      || finalizer_has_die_message expected finalizer

let rec cause_has_finalizer_die_message expected = function
  | Cause.Finalizer finalizer -> finalizer_has_die_message expected finalizer
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_finalizer_die_message expected primary
      || finalizer_has_die_message expected finalizer
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_finalizer_die_message expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let expect_finalizer_die label expected = function
  | Exit.Error cause when cause_has_finalizer_die_message expected cause -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected finalizer defect %S, got %a" label expected
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected finalizer defect, got Ok" label

let domain_spawn f =
  (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"]) f

let run_in_domain f =
  let domain = domain_spawn f in
  Domain.join domain

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f rt

let with_test_graph_lane rt graph f =
  run_ok rt
    (Eta_signal_testable.Graph.with_lane_access graph
       ~leaf_name:"test_eta_signal.graph_lane"
       ~depth_local:(Runtime_contract.create_local ())
       ~hooks:
         (Eta_signal_testable.Graph.lane_hooks ~note_waiter_enqueued:ignore
            ~note_waiter_compaction:ignore)
       ~after_acquired:(fun () -> Effect.unit)
       f)

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
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f sw rt

exception Cleanup_interrupt
exception Lane_grant_resolution_failed

module Cleanup_interrupt_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let interrupt_next_protect_return = ref false
  let interrupt_on_local_binding_count = ref None
  let after_local_binding_count : (int * (unit -> unit)) option ref = ref None
  let now = ref 0
  let root_scope = ()
  let now_ms () = !now
  let sleep duration = now := !now + Duration.to_ms duration

  let protect f =
    let value = f () in
    if !interrupt_next_protect_return then (
      interrupt_next_protect_return := false;
      raise Cleanup_interrupt);
    value

  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = raise Cleanup_interrupt
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    match !resolver with
    | Some _ ->
        invalid_arg "Cleanup_interrupt_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with
    | Some value -> value
    | None -> failwith "Cleanup_interrupt_runtime.await_promise: unresolved"

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Cleanup_interrupt_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false

  let cancellation_reason = function
    | Cleanup_interrupt -> Some Cleanup_interrupt
    | _ -> None

  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()

  let locals : (int, Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_binding_count = ref 0

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
    local_binding_count := !local_binding_count + 1;
    Hashtbl.replace locals id
      (Runtime_contract.Local_binding (local, value) :: stack);
    let interrupt =
      match !interrupt_on_local_binding_count with
      | Some target when target = !local_binding_count ->
          interrupt_on_local_binding_count := None;
          true
      | Some _ | None -> false
    in
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      (fun () -> if interrupt then raise Cleanup_interrupt else f ())
    |> fun value ->
    (match !after_local_binding_count with
     | Some (target, hook) when target = !local_binding_count ->
         after_local_binding_count := None;
         hook ()
     | Some _ | None -> ());
    value
end

module Make_isolated_sync_runtime () = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let root_scope = ()
  let now_ms () = 0
  let sleep _duration = ()
  let protect f = f ()
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

let with_logger_test_clock f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let logger = Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~logger:(Logger.as_capability logger) ()
  in
  f sw clock rt logger

let record_observer events update =
  Effect.sync (fun () -> events := update :: !events)

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
  run_ok rt Signal.stabilize;
  force_signal_gc ();
  let before = run_ok rt (Signal.stats ()) in
  let make_temporary_graph () =
    let source = Signal.Var.create 0 in
    let signal =
      Signal.Var.watch source |> Signal.map (fun value -> value + 1)
      |> Signal.map (fun value -> value * 2)
    in
    let observer =
      run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
    in
    run_ok rt Signal.stabilize;
    run_ok rt (Signal.Observer.dispose observer);
    run_ok rt Signal.stabilize
  in
  make_temporary_graph ();
  let after_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool) "temporary graph was indexed" true
    (after_dispose.Signal.total_node_count > before.Signal.total_node_count);
  force_signal_gc ();
  let after_gc = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "temporary root nodes reclaimed"
    before.Signal.total_node_count after_gc.Signal.total_node_count

let test_functor_instances_stabilize_independently () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_observer_callbacks_run_in_registration_order () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_observer_ordering_across_graph_branches_is_deterministic () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let run_case label registration_order =
    let source = Signal.Var.create 1 in
    let upstream =
      Signal.Var.watch source |> Signal.map (fun value -> value + 1)
    in
    let downstream = Signal.map (fun value -> value * 10) upstream in
    let independent =
      Signal.Var.watch source |> Signal.map (fun value -> -value)
    in
    let events = ref [] in
    let record label _update =
      Effect.sync (fun () -> events := label :: !events)
    in
    let observe = function
      | "upstream" -> Signal.Observer.observe upstream (record "upstream")
      | "downstream" ->
          Signal.Observer.observe downstream (record "downstream")
      | "independent" ->
          Signal.Observer.observe independent (record "independent")
      | unexpected ->
          Alcotest.failf "unexpected observer label %S" unexpected
    in
    let observers =
      List.map (fun name -> run_ok rt (observe name)) registration_order
    in
    let expected = [ "upstream"; "downstream"; "independent" ] in
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun observer ->
            ignore
              (Eta_eio.Runtime.run rt
                 (widen (Signal.Observer.dispose observer))
                : _ Exit.t))
          observers)
      (fun () ->
        run_ok rt Signal.stabilize;
        Alcotest.(check (list string))
          (label ^ " initial graph observer order") expected (List.rev !events);
        events := [];
        run_ok rt (Signal.Var.set source 2);
        run_ok rt Signal.stabilize;
        Alcotest.(check (list string))
          (label ^ " changed graph observer order") expected
          (List.rev !events))
  in
  run_case "creation registration"
    [ "upstream"; "downstream"; "independent" ];
  run_case "reverse dependency registration"
    [ "downstream"; "upstream"; "independent" ];
  run_case "reverse registration"
    [ "independent"; "downstream"; "upstream" ]

let test_observer_independent_branch_order_ignores_registration_permutation () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let run_case label registration_order =
    let source = Signal.Var.create 1 in
    let left = Signal.Var.watch source |> Signal.map (fun value -> value + 1) in
    let middle =
      Signal.Var.watch source |> Signal.map (fun value -> value + 2)
    in
    let right =
      Signal.Var.watch source |> Signal.map (fun value -> value + 3)
    in
    let events = ref [] in
    let record label _update =
      Effect.sync (fun () -> events := label :: !events)
    in
    let observe = function
      | "left" -> Signal.Observer.observe left (record "left")
      | "middle" -> Signal.Observer.observe middle (record "middle")
      | "right" -> Signal.Observer.observe right (record "right")
      | unexpected ->
          Alcotest.failf "unexpected observer label %S" unexpected
    in
    let observers =
      List.map (fun name -> run_ok rt (observe name)) registration_order
    in
    let expected = [ "left"; "middle"; "right" ] in
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun observer ->
            ignore
              (Eta_eio.Runtime.run rt
                 (widen (Signal.Observer.dispose observer))
                : _ Exit.t))
          observers)
      (fun () ->
        run_ok rt Signal.stabilize;
        Alcotest.(check (list string))
          (label ^ " initial independent observer order") expected
          (List.rev !events);
        events := [];
        run_ok rt (Signal.Var.set source 2);
        run_ok rt Signal.stabilize;
        Alcotest.(check (list string))
          (label ^ " changed independent observer order") expected
          (List.rev !events))
  in
  run_case "creation registration" [ "left"; "middle"; "right" ];
  run_case "reverse registration" [ "right"; "middle"; "left" ];
  run_case "mixed registration" [ "middle"; "right"; "left" ]

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
    run_ok rt
      (Signal.Observer.observe downstream (function
        | Signal.Initialized _ -> Effect.unit
        | Changed _ -> Effect.fail `Observer_failed))
  in
  let upstream_observer =
    run_ok rt
      (Signal.Observer.observe upstream (function
        | Signal.Initialized _ -> Effect.unit
        | Changed { new_value; _ } ->
            Effect.sync (fun () ->
                upstream_events := new_value :: !upstream_events)))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Eta_eio.Runtime.run rt
           (widen
              (Signal.Observer.dispose downstream_observer
               |> Effect.bind (fun () ->
                      Signal.Observer.dispose upstream_observer)))
          : _ Exit.t))
    (fun () ->
      run_ok rt Signal.stabilize;
      run_ok rt (Signal.Var.set source 2);
      expect_fail "downstream observer failure"
        (function
          | `Observer_error `Observer_failed -> true
          | _ -> false)
        (Eta_eio.Runtime.run rt (widen Signal.stabilize));
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
    Signal.bind (Signal.Var.watch selector) (fun use_upstream ->
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
    run_ok rt
      (Signal.Observer.observe dynamic (function
        | Signal.Initialized _ -> Effect.unit
        | Changed _ -> Effect.fail `Observer_failed))
  in
  let upstream_observer =
    run_ok rt
      (Signal.Observer.observe upstream (function
        | Signal.Initialized _ -> Effect.unit
        | Changed { new_value; _ } ->
            Effect.sync (fun () ->
                upstream_events := new_value :: !upstream_events)))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Eta_eio.Runtime.run rt
           (widen
              (Signal.Observer.dispose dynamic_observer
               |> Effect.bind (fun () ->
                      Signal.Observer.dispose upstream_observer)))
          : _ Exit.t))
    (fun () ->
      run_ok rt Signal.stabilize;
      run_ok rt (Signal.Var.set data 2);
      run_ok rt (Signal.Var.set selector true);
      expect_fail "dynamic observer failure"
        (function
          | `Observer_error `Observer_failed -> true
          | _ -> false)
        (Eta_eio.Runtime.run rt (widen Signal.stabilize));
      Alcotest.(check (list int))
        "new inner upstream observer ran before dynamic fail-fast" [ 3 ]
        (List.rev !upstream_events))

let test_observer_dispose_during_callback_skips_collected_event () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let events = ref [] in
  let later_observer = ref None in
  let first_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           Effect.sync (fun () -> events := "first" :: !events)
           |> Effect.bind (fun () ->
                  match !later_observer with
                  | Some observer ->
                      Signal.Observer.dispose observer
                      |> Effect.or_die (fun err -> Signal.Graph_error err)
                  | None -> Effect.sync (fun () -> Alcotest.fail "missing observer"))))
  in
  let second_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           Effect.sync (fun () -> events := "second" :: !events)))
  in
  later_observer := Some second_observer;
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "collected event is skipped after same-stabilization disposal"
    [ "first" ] (List.rev !events);
  expect_fail "same-stabilization disposed observer read" (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read second_observer)));
  events := [];
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "disposed observer is absent from later stabilization" [ "first" ]
    (List.rev !events);
  run_ok rt (Signal.Observer.dispose first_observer)

let test_observer_dispose_after_active_check_skips_callback () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let target_ref = ref None in
  let target_callback_ran = ref false in
  let arm_dispose = ref false in
  let marker =
    expect_exit_ok "marker observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe signal (function
              | Signal.Changed _ when !arm_dispose ->
                  Effect.sync (fun () ->
                      Cleanup_interrupt_runtime.after_local_binding_count :=
                        Some
                          ( !Cleanup_interrupt_runtime.local_binding_count + 2,
                            fun () ->
                              match !target_ref with
                              | None ->
                                  Alcotest.fail "target observer was not registered"
                              | Some target ->
                                  ignore
                                    (expect_exit_ok
                                       "target dispose after active check"
                                       (Runtime.run rt
                                          (widen
                                             (Signal.Observer.dispose target)))
                                      : unit) ))
              | Initialized _ | Changed _ -> Effect.unit))))
  in
  let target =
    expect_exit_ok "target observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe signal (fun _ ->
                 Effect.sync (fun () -> target_callback_ran := true)))))
  in
  target_ref := Some target;
  Fun.protect
    ~finally:(fun () ->
      Cleanup_interrupt_runtime.after_local_binding_count := None;
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose target)) : _ Exit.t);
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose marker)) : _ Exit.t))
    (fun () ->
      ignore
        (expect_exit_ok "initial stabilize"
           (Runtime.run rt (widen Signal.stabilize))
          : unit);
      target_callback_ran := false;
      arm_dispose := true;
      ignore
        (expect_exit_ok "set source"
           (Runtime.run rt (widen (Signal.Var.set source 2)))
          : unit);
      ignore
        (expect_exit_ok "stabilize with racing dispose"
           (Runtime.run rt (widen Signal.stabilize))
          : unit);
      Alcotest.(check bool)
        "disposed observer callback is skipped after active check" false
        !target_callback_ran;
      expect_fail "target disposed by active-check hook" (( = ) `Disposed_observer)
        (Runtime.run rt (widen (Signal.Observer.read target))))

let test_observer_dispose_after_delivery_claim_skips_callback () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source in
  let callbacks = ref 0 in
  let observer =
    run_ok rt
      (Signal.Observer.observe signal (fun _ ->
           Effect.sync (fun () -> incr callbacks)))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial callback" 1 !callbacks;
  run_ok rt (Signal.Var.set source 1);
  let claimed, claimed_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let hook_ran = ref false in
  let release_once =
    let released = ref false in
    fun () ->
      if not !released then (
        released := true;
        Eio.Promise.resolve release_resolver ())
  in
  let hook =
    {
      Signal.Private_test_hooks.run =
        (fun () ->
          Effect.sync (fun () ->
              if not !hook_ran then (
                hook_ran := true;
                Eio.Promise.resolve claimed_resolver ();
                Eio.Promise.await release)));
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Signal.Private_test_hooks.clear ();
      release_once ();
      ignore (Runtime.run rt (widen (Signal.Observer.dispose observer)) : _ Exit.t))
    (fun () ->
      Signal.Private_test_hooks.with_hook
        Signal.Private_test_hooks.After_observer_delivery_claim hook
      @@ fun () ->
      let stabilizer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt (widen Signal.stabilize))
      in
      Eio.Promise.await claimed;
      run_ok rt (Signal.Observer.dispose observer);
      release_once ();
      ignore
        (expect_exit_ok "stabilize with post-claim dispose"
           (Eio.Promise.await_exn stabilizer)
          : unit);
      Alcotest.(check int)
        "disposed observer callback is skipped after delivery claim" 1 !callbacks;
      expect_fail "target disposed by claim hook" (( = ) `Disposed_observer)
        (Runtime.run rt (widen (Signal.Observer.read observer))))

let test_observer_registration_skips_callbacks_until_returned () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observe_returned = ref false in
  let callback_before_return = ref false in
  let callback_count = ref 0 in
  Cleanup_interrupt_runtime.after_local_binding_count :=
    Some
      ( 1,
        fun () ->
          ignore
            (expect_exit_ok "stabilize during observer registration"
               (Runtime.run rt (widen Signal.stabilize))
              : unit) );
  let observer =
    Fun.protect
      ~finally:(fun () ->
        Cleanup_interrupt_runtime.after_local_binding_count := None)
      (fun () ->
        expect_exit_ok "observer registration"
          (Runtime.run rt
             (widen
                (Signal.Observer.observe signal (fun _ ->
                     Effect.sync (fun () ->
                         incr callback_count;
                         if not !observe_returned then
                           callback_before_return := true))))))
  in
  observe_returned := true;
  Fun.protect
    ~finally:(fun () ->
      ignore (Runtime.run rt (widen (Signal.Observer.dispose observer)) : _ Exit.t))
    (fun () ->
      Alcotest.(check bool)
        "registration window did not run callback" false
        !callback_before_return;
      Alcotest.(check int) "no callback before observe returned" 0
        !callback_count;
      ignore
        (expect_exit_ok "stabilize after observer registration"
           (Runtime.run rt (widen Signal.stabilize))
          : unit);
      Alcotest.(check int) "callback after observe returned" 1 !callback_count)

let test_observer_activation_waits_for_transfer_before_callbacks () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observe_returned = ref false in
  let callback_before_return = ref false in
  let callback_count = ref 0 in
  Cleanup_interrupt_runtime.after_local_binding_count :=
    Some
      ( 4,
        fun () ->
          ignore
            (expect_exit_ok "stabilize during observer transfer"
               (Runtime.run rt (widen Signal.stabilize))
              : unit) );
  let observer =
    Fun.protect
      ~finally:(fun () ->
        Cleanup_interrupt_runtime.after_local_binding_count := None)
      (fun () ->
        expect_exit_ok "observer registration"
          (Runtime.run rt
             (widen
                (Signal.Observer.observe signal (fun _ ->
                     Effect.sync (fun () ->
                         incr callback_count;
                         if not !observe_returned then
                           callback_before_return := true))))))
  in
  observe_returned := true;
  Fun.protect
    ~finally:(fun () ->
      ignore (Runtime.run rt (widen (Signal.Observer.dispose observer)) : _ Exit.t))
    (fun () ->
      Alcotest.(check bool)
        "transfer window did not run callback" false !callback_before_return;
      Alcotest.(check int) "no callback before observe transfer" 0
        !callback_count;
      ignore
        (expect_exit_ok "stabilize after observer transfer"
           (Runtime.run rt (widen Signal.stabilize))
          : unit);
      Alcotest.(check int) "callback after observe transfer" 1 !callback_count)

let test_observer_activation_interruption_disposes_unowned_observer () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  Signal.Private_test_hooks.clear ();
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let before_stats =
    expect_exit_ok "stats before interrupted observe"
      (Runtime.run rt (widen (Signal.stats ())))
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let callbacks = ref 0 in
  let hook =
    {
      Signal.Private_test_hooks.run =
        (fun () -> Effect.sync (fun () -> raise Cleanup_interrupt));
    }
  in
  Fun.protect
    ~finally:Signal.Private_test_hooks.clear
    (fun () ->
      Signal.Private_test_hooks.with_hook
        Signal.Private_test_hooks.After_observer_activation_before_return hook
      @@ fun () ->
      (match
         Runtime.run rt
           (widen
              (Signal.Observer.observe signal (fun _update ->
                   Effect.sync (fun () -> incr callbacks))))
       with
      | exception Cleanup_interrupt -> ()
      | Exit.Error cause when Cause.is_interrupt_only cause -> ()
      | Exit.Error cause ->
          Alcotest.failf "expected injected interruption, got %a"
            (Cause.pp pp_hidden) cause
      | Exit.Ok observer ->
          ignore
            (Runtime.run rt (widen (Signal.Observer.dispose observer))
              : _ Exit.t);
          Alcotest.fail "observer unexpectedly returned after interruption");
      let stats =
        expect_exit_ok "stats after interrupted observe"
          (Runtime.run rt (widen (Signal.stats ())))
      in
      Alcotest.(check int)
        "interrupted observer activation leaves no active observer" 0
        (stats.Signal.active_observer_count
        - before_stats.Signal.active_observer_count);
      ignore
        (expect_exit_ok "stabilize after interrupted observe"
           (Runtime.run rt (widen Signal.stabilize))
          : unit);
      Alcotest.(check int)
        "interrupted observer activation does not leak callback" 0 !callbacks)

let test_observer_activation_abort_cleanup_does_not_mask_failure () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  Signal.Private_test_hooks.clear ();
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let hook =
    {
      Signal.Private_test_hooks.run =
        (fun () -> Effect.sync (fun () -> failwith "activation failure"));
    }
  in
  Fun.protect
    ~finally:Signal.Private_test_hooks.clear
    (fun () ->
      Signal.Private_test_hooks.with_hook
        Signal.Private_test_hooks.After_observer_activation_before_return hook
      @@ fun () ->
      match
        Runtime.run rt
          (widen
             (Signal.Observer.observe_with_hooks_callback
                ~on_finish:[ (fun _reason ->
                  failwith "abort cleanup hook failure") ]
                signal
                (fun _observer _update -> Effect.unit)))
      with
      | Exit.Error cause ->
          if
            cause_has_finalizer_die_message "abort cleanup hook failure" cause
          then
            Alcotest.failf
              "observer activation abort cleanup masked original failure: %a"
              (Cause.pp pp_hidden) cause
      | Exit.Ok observer ->
          ignore
            (Runtime.run rt (widen (Signal.Observer.dispose observer))
              : _ Exit.t);
          Alcotest.fail "observer unexpectedly returned after activation failure")

let test_observer_observe_invalidated_before_transfer_fails () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let use_branch = Signal.Var.create true in
  let captured = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_branch) (fun active ->
        if active then (
          let branch = Signal.const 1 in
          captured := Some branch;
          branch)
        else Signal.const 2)
  in
  let selected_observer =
    expect_exit_ok "selected observer registration"
      (Runtime.run rt
         (widen (Signal.Observer.observe selected (fun _ -> Effect.unit))))
  in
  ignore
    (expect_exit_ok "initial stabilize"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  let branch =
    match !captured with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch signal"
  in
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Cleanup_interrupt_runtime.after_local_binding_count :=
    Some
      ( 3,
        fun () ->
          ignore
            (expect_exit_ok "branch switch before observer transfer"
               (Runtime.run rt
                  (widen
                     (Signal.Var.set use_branch false
                      |> Effect.bind (fun () -> Signal.stabilize))))
              : unit) );
  Fun.protect
    ~finally:(fun () ->
      Cleanup_interrupt_runtime.after_local_binding_count := None;
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose selected_observer))
          : _ Exit.t))
    (fun () ->
      match
        Runtime.run rt
          (widen (Signal.Observer.observe branch (fun _ -> Effect.unit)))
      with
      | Exit.Error (Cause.Fail `Invalid_scope) -> ()
      | Exit.Error cause ->
          Alcotest.failf "expected Invalid_scope, got %a" (Cause.pp pp_hidden)
            cause
      | Exit.Ok observer ->
          ignore
            (Runtime.run rt (widen (Signal.Observer.dispose observer))
              : _ Exit.t);
          Alcotest.fail "observe returned an invalidated observer")

let test_bind_switches_after_unnecessary_source_change () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let selector_calls = ref [] in
  let bound =
    Signal.bind watched (fun value ->
        selector_calls := value :: !selector_calls;
        Signal.const ("branch " ^ string_of_int value))
  in
  let source_observer =
    run_ok rt (Signal.Observer.observe watched (fun _ -> Effect.unit))
  in
  let bound_observer =
    run_ok rt (Signal.Observer.observe bound (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "initial branch" "branch 0"
    (run_ok rt (Signal.Observer.read bound_observer));
  Alcotest.(check (list int))
    "initial selector call" [ 0 ] (List.rev !selector_calls);
  run_ok rt (Signal.Observer.dispose bound_observer);
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "source observer saw update" 1
    (run_ok rt (Signal.Observer.read source_observer));
  Alcotest.(check (list int))
    "unnecessary bind not reselected" [ 0 ] (List.rev !selector_calls);
  let reobserved =
    run_ok rt (Signal.Observer.observe bound (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "reobserved branch is current" "branch 1"
    (run_ok rt (Signal.Observer.read reobserved));
  Alcotest.(check (list int))
    "bind reselected on reobserve" [ 0; 1 ] (List.rev !selector_calls);
  run_ok rt (Signal.Observer.dispose source_observer);
  run_ok rt (Signal.Observer.dispose reobserved)

let test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_invalidated_bind_rhs_cannot_be_observed () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial captured branch" 10
    (run_ok rt (Signal.Observer.read observer));
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "active branch switched" 20
    (run_ok rt (Signal.Observer.read observer));
  let before = run_ok rt (Signal.stats ()) in
  expect_fail "captured invalid scope observe" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Observer.observe captured (fun _ -> Effect.unit))));
  let after = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "failed observe did not add observer"
    before.Signal.active_observer_count after.Signal.active_observer_count;
  run_ok rt (Signal.Observer.dispose observer)

let test_invalidated_bind_rhs_cannot_be_wrapped () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "active branch switched" 20
    (run_ok rt (Signal.Observer.read observer));
  (match
     ignore (Signal.map (fun value -> value + 1) captured : int Signal.signal)
   with
  | exception Signal.Graph_error `Invalid_scope -> ()
  | exception exn ->
      Alcotest.failf "wrapped invalid scope construction: expected graph error, got %s"
        (Printexc.to_string exn)
  | () ->
      Alcotest.fail
        "wrapped invalid scope construction: expected graph error");
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization remains healthy" 21
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_rejects_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let selected =
    Signal.bind watched (fun _ ->
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
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "initial branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 1);
  expect_fail "reused dynamic-scope inner" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  captured := None;
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_rejects_root_wrapper_over_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let wrapper = ref None in
  let selected =
    Signal.bind watched (fun value ->
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
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "initial branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  let old_inner =
    match !captured with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  wrapper := Some (Signal.map (fun value -> value ^ " wrapped") old_inner);
  run_ok rt (Signal.Var.set source 1);
  expect_fail "root wrapper over reused dynamic-scope inner" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  wrapper := None;
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_rejects_new_scope_wrapper_over_reused_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let captured = ref None in
  let selected =
    Signal.bind watched (fun value ->
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
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "initial branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set source 1);
  expect_fail "new-scope wrapper over reused dynamic-scope inner"
    (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check string) "failed switch preserves previous branch" "branch 0"
    (run_ok rt (Signal.Observer.read observer));
  captured := None;
  run_ok rt Signal.stabilize;
  Alcotest.(check string) "later valid switch succeeds" "branch 1"
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_accepts_ancestor_dynamic_scope_inner () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let outer_source = Signal.Var.create true in
  let inner_source = Signal.Var.create 0 in
  let inner_watch = Signal.Var.watch inner_source in
  let selected =
    Signal.bind (Signal.Var.watch outer_source) (fun _ ->
        let ancestor = Signal.map (fun value -> value + 10) inner_watch in
        Signal.bind inner_watch (fun _ -> ancestor))
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial ancestor inner" 10
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set inner_source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "updated ancestor inner" 11
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_switch_invalidates_external_derived_branch_dependents () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let wrapped = Signal.map (fun value -> value + 1) captured in
  let wrapped_observer =
    run_ok rt (Signal.Observer.observe wrapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "wrapped branch initialized" 11
    (run_ok rt (Signal.Observer.read wrapped_observer));
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "selected switched to right" 20
    (run_ok rt (Signal.Observer.read selected_observer));
  expect_fail "wrapped branch observer invalidated" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read wrapped_observer)));
  run_ok rt (Signal.Observer.dispose wrapped_observer);
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization ignores invalidated wrapper" 21
    (run_ok rt (Signal.Observer.read selected_observer));
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_bind_switch_invalidates_observers_of_invalidated_scope () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let branch_observer =
    run_ok rt (Signal.Observer.observe captured (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "branch observer initialized" 10
    (run_ok rt (Signal.Observer.read branch_observer));
  let before_switch = run_ok rt (Signal.stats ()) in
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  let after_switch = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "selected switched to right" 20
    (run_ok rt (Signal.Observer.read selected_observer));
  expect_fail "invalidated branch observer read" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
  Alcotest.(check int) "invalidated branch observer is counted" 1
    after_switch.Signal.invalid_observer_count;
  Alcotest.(check bool) "invalidated branch nodes counted in stats" true
    (after_switch.Signal.dead_node_count > before_switch.Signal.dead_node_count);
  run_ok rt (Signal.Observer.dispose branch_observer);
  let after_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "disposed invalid branch observer is uncounted" 0
    after_dispose.Signal.invalid_observer_count;
  expect_fail "disposed invalid branch observer read" (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization ignores invalidated observer" 21
    (run_ok rt (Signal.Observer.read selected_observer));
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_bind_switch_skips_stale_branch_observer_before_invalidation () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let stale_branch_recomputes = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
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
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  run_ok rt (Signal.Observer.dispose initial_selected_observer);
  let branch_observer =
    run_ok rt (Signal.Observer.observe captured (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "branch observer initialized" 10
    (run_ok rt (Signal.Observer.read branch_observer));
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt (Signal.Var.set left 11);
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "selected switched to right" 20
    (run_ok rt (Signal.Observer.read selected_observer));
  Alcotest.(check int) "stale branch was not recomputed" 0
    !stale_branch_recomputes;
  expect_fail "invalidated branch observer read" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
  run_ok rt (Signal.Observer.dispose branch_observer);
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_old_branch_observer_not_computed_on_switch () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let selector = Signal.Var.create true in
  let branch_var = Signal.Var.create 0 in
  let captured_old = ref None in
  let old_branch_compute_count = ref 0 in
  let top =
    Signal.bind (Signal.Var.watch selector) (function
      | true ->
          let signal =
            Signal.Var.watch branch_var
            |> Signal.map (fun value ->
                   incr old_branch_compute_count;
                   if value = 1 then failwith "old branch was computed";
                   value)
          in
          captured_old := Some signal;
          signal
      | false -> Signal.const 42)
  in
  let top_observer =
    run_ok rt (Signal.Observer.observe top (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let old_signal =
    match !captured_old with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured old branch signal"
  in
  let old_observer =
    run_ok rt (Signal.Observer.observe old_signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set branch_var 1);
  run_ok rt (Signal.Var.set selector false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int)
    "old branch map not recomputed during switch" 1 !old_branch_compute_count;
  expect_fail "old branch observer invalidated" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read old_observer)));
  Alcotest.(check int) "top switched to new branch" 42
    (run_ok rt (Signal.Observer.read top_observer));
  run_ok rt (Signal.Observer.dispose old_observer);
  run_ok rt (Signal.Observer.dispose top_observer)

let test_dynamic_scope_invalidation_skips_callback () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 0 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map Fun.id in
          captured_left := Some signal;
          signal)
        else Signal.const 0)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let branch =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let branch_callbacks = ref 0 in
  let branch_observer =
    run_ok rt
      (Signal.Observer.observe branch (fun _ ->
           Effect.sync (fun () -> incr branch_callbacks)))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "branch observer initialized" 1 !branch_callbacks;
  run_ok rt (Signal.Var.set left 1);
  run_ok rt (Signal.Var.set choose_left false);
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose branch_observer))
          : _ Exit.t);
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose selected_observer))
          : _ Exit.t))
    (fun () ->
      run_ok rt Signal.stabilize;
      Alcotest.(check int)
        "invalidated branch callback is skipped" 1 !branch_callbacks;
      expect_fail "invalidated branch observer read" (( = ) `Invalid_scope)
        (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
      Alcotest.(check int) "selected value is unchanged" 0
        (run_ok rt (Signal.Observer.read selected_observer)))

let test_commit_skips_invalidated_staged_entries () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then (
          let signal = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some signal;
          signal)
        else Signal.Var.watch right)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let captured =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind RHS signal"
  in
  let branch_observer =
    run_ok rt (Signal.Observer.observe captured (fun _ -> Effect.unit))
  in
  run_ok rt (Signal.Var.set left 11);
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "selected switched to right" 20
    (run_ok rt (Signal.Observer.read selected_observer));
  expect_fail "invalidated branch observer read" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
  let options =
    {
      Signal.dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = false;
    }
  in
  let dot = run_ok rt (Signal.to_dot ~options ()) in
  Alcotest.(check bool) "invalid observer shown" true
    (contains_substring dot "state=invalid_scope");
  Alcotest.(check bool) "invalid observer remains uninitialized" true
    (contains_substring dot "state=invalid_scope value_state=uninitialized");
  Alcotest.(check bool) "invalid observer did not commit current value" false
    (contains_substring dot "state=invalid_scope value_state=current");
  run_ok rt (Signal.Observer.dispose branch_observer);
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_dynamic_signal_rewires_and_cycle_preserves_snapshot () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let a_target = Signal.Var.create (Signal.const 1) in
  let b_target = Signal.Var.create (Signal.const 10) in
  let a = Signal.bind (Signal.Var.watch a_target) (fun signal -> signal) in
  let b = Signal.bind (Signal.Var.watch b_target) (fun signal -> signal) in
  let a_observer =
    run_ok rt (Signal.Observer.observe a (fun _ -> Effect.unit))
  in
  let b_observer =
    run_ok rt (Signal.Observer.observe b (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial a" 1
    (run_ok rt (Signal.Observer.read a_observer));
  Alcotest.(check int) "initial b" 10
    (run_ok rt (Signal.Observer.read b_observer));
  run_ok rt (Signal.Var.set a_target b);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "one-way a follows b" 10
    (run_ok rt (Signal.Observer.read a_observer));
  Alcotest.(check int) "one-way b remains constant" 10
    (run_ok rt (Signal.Observer.read b_observer));
  run_ok rt (Signal.Var.set a_target (Signal.const 2));
  run_ok rt (Signal.Var.set b_target a);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reverse a constant" 2
    (run_ok rt (Signal.Observer.read a_observer));
  Alcotest.(check int) "reverse b follows a" 2
    (run_ok rt (Signal.Observer.read b_observer));
  run_ok rt (Signal.Var.set a_target b);
  run_ok rt (Signal.Var.set b_target a);
  expect_fail "dynamic signal cycle" (( = ) `Cycle)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "a snapshot preserved after cycle" 2
    (run_ok rt (Signal.Observer.read a_observer));
  Alcotest.(check int) "b snapshot preserved after cycle" 2
    (run_ok rt (Signal.Observer.read b_observer));
  run_ok rt (Signal.Observer.dispose a_observer);
  run_ok rt (Signal.Observer.dispose b_observer)

let test_dynamic_list_bind_switches_dependency_set () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let indices = Signal.Var.create [ 0; 2 ] in
  let values =
    [| Signal.Var.create 10; Signal.Var.create 20; Signal.Var.create 30;
       Signal.Var.create 40 |]
  in
  let calls = Array.make 4 0 in
  let watch_index index =
    Signal.Var.watch values.(index)
    |> Signal.map (fun value ->
           calls.(index) <- calls.(index) + 1;
           value)
  in
  let selected_sum =
    Signal.bind (Signal.Var.watch indices) (fun indices ->
        indices
        |> List.map watch_index
        |> Signal.all
        |> Signal.map (List.fold_left ( + ) 0))
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe selected_sum (record_observer events))
  in
  let check_calls label expected =
    Alcotest.(check (list int)) label expected (Array.to_list calls)
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial selected sum" 40
    (run_ok rt (Signal.Observer.read observer));
  check_calls "initial active inputs recomputed" [ 1; 0; 1; 0 ];
  run_ok rt (Signal.Var.set values.(1) 200);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "excluded input ignored" 40
    (run_ok rt (Signal.Observer.read observer));
  check_calls "excluded input did not recompute" [ 1; 0; 1; 0 ];
  run_ok rt (Signal.Var.set values.(2) 300);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "included input updates" 310
    (run_ok rt (Signal.Observer.read observer));
  check_calls "included input recomputed" [ 1; 0; 2; 0 ];
  run_ok rt (Signal.Var.set indices [ 1; 3 ]);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "new dependency set uses latest values" 240
    (run_ok rt (Signal.Observer.read observer));
  check_calls "new active inputs attach" [ 1; 1; 2; 1 ];
  run_ok rt (Signal.Var.set values.(0) 1000);
  run_ok rt (Signal.Var.set values.(2) 3000);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "old dependency set detached" 240
    (run_ok rt (Signal.Observer.read observer));
  check_calls "detached inputs ignored" [ 1; 1; 2; 1 ];
  run_ok rt (Signal.Var.set values.(1) 210);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "current dependency still active" 250
    (run_ok rt (Signal.Observer.read observer));
  check_calls "current input recomputed" [ 1; 2; 2; 1 ];
  (match List.rev !events with
   | [
       Signal.Initialized 40;
       Changed { old_value = 40; new_value = 310 };
       Changed { old_value = 310; new_value = 240 };
       Changed { old_value = 240; new_value = 250 };
     ] -> ()
   | _ -> Alcotest.fail "unexpected dynamic list observer events");
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_branch_churn_releases_inactive_scopes () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choice = Signal.Var.create `A in
  let sources =
    [| Signal.Var.create 10; Signal.Var.create 20; Signal.Var.create 30 |]
  in
  let calls = Array.make 3 0 in
  let index = function `A -> 0 | `B -> 1 | `C -> 2 in
  let selected =
    Signal.bind (Signal.Var.watch choice) (fun branch ->
        let index = index branch in
        Signal.Var.watch sources.(index)
        |> Signal.map (fun value ->
               calls.(index) <- calls.(index) + 1;
               value))
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe selected (record_observer events))
  in
  let check_calls label expected =
    Alcotest.(check (list int)) label expected (Array.to_list calls)
  in
  let set_sources a b c =
    run_ok rt (Signal.Var.set sources.(0) a);
    run_ok rt (Signal.Var.set sources.(1) b);
    run_ok rt (Signal.Var.set sources.(2) c)
  in
  let switch label branch expected_value expected_calls =
    run_ok rt (Signal.Var.set choice branch);
    run_ok rt Signal.stabilize;
    Alcotest.(check int) (label ^ " selected value") expected_value
      (run_ok rt (Signal.Observer.read observer));
    check_calls (label ^ " calls") expected_calls
  in
  run_ok rt Signal.stabilize;
  let before_churn = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "initial branch value" 10
    (run_ok rt (Signal.Observer.read observer));
  check_calls "initial calls" [ 1; 0; 0 ];
  set_sources 11 21 31;
  switch "switch to b" `B 21 [ 1; 1; 0 ];
  set_sources 12 22 32;
  switch "switch to c" `C 32 [ 1; 1; 1 ];
  set_sources 13 23 33;
  switch "reactivate a" `A 13 [ 2; 1; 1 ];
  set_sources 14 24 34;
  switch "reactivate b" `B 24 [ 2; 2; 1 ];
  set_sources 15 25 35;
  switch "reactivate a again" `A 15 [ 3; 2; 1 ];
  let after_churn = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool)
    "branch churn invalidated old scopes" true
    (after_churn.Signal.dynamic_scope_invalidations
     >= before_churn.Signal.dynamic_scope_invalidations + 5);
  Alcotest.(check bool)
    "branch churn released unnecessary nodes" true
    (after_churn.Signal.nodes_became_unnecessary
     > before_churn.Signal.nodes_became_unnecessary);
  Alcotest.(check int) "branch churn does not retain invalid nodes"
    before_churn.Signal.total_node_count after_churn.Signal.total_node_count;
  Alcotest.(check int) "branch churn did not add observers"
    before_churn.Signal.active_observer_count
    after_churn.Signal.active_observer_count;
  (match List.rev !events with
   | [
       Signal.Initialized 10;
       Changed { old_value = 10; new_value = 21 };
       Changed { old_value = 21; new_value = 32 };
       Changed { old_value = 32; new_value = 13 };
       Changed { old_value = 13; new_value = 24 };
       Changed { old_value = 24; new_value = 15 };
     ] -> ()
   | _ -> Alcotest.fail "unexpected bind churn observer events");
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_selector_failure_preserves_previous_branch () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_observer_phase_multiple_sets_publish_final_next_value () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let events = ref [] in
  let pending_values = ref [] in
  let snapshot_reads = ref [] in
  let observer_ref = ref None in
  let observer =
    run_ok rt
      (Signal.Observer.observe signal (fun update ->
           Effect.sync (fun () -> events := update :: !events)
           |> Effect.bind (fun () ->
                  match (!observer_ref, update) with
                  | Some observer, Signal.Initialized 1 ->
                      Signal.Var.set source 2
                      |> Effect.map_error (fun _ -> `Observer_failed)
                      |> Effect.bind (fun () ->
                             Effect.sync (fun () ->
                                 pending_values :=
                                   Signal.Var.value source :: !pending_values))
                      |> Effect.bind (fun () -> Signal.Var.set source 3)
                      |> Effect.map_error (fun _ -> `Observer_failed)
                      |> Effect.bind (fun () ->
                             Signal.Observer.read observer
                             |> Effect.map_error (fun _ -> `Observer_failed))
                      |> Effect.bind (fun snapshot ->
                             Effect.sync (fun () ->
                                 pending_values :=
                                   Signal.Var.value source :: !pending_values;
                                 snapshot_reads := snapshot :: !snapshot_reads))
                  | _ -> Effect.unit)))
  in
  observer_ref := Some observer;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "current stabilization snapshot remains stable" 1
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "callback saw pending source values" [ 2; 3 ]
    (List.rev !pending_values);
  Alcotest.(check (list int)) "callback observer read saw snapshot" [ 1 ]
    (List.rev !snapshot_reads);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "next stabilization publishes final pending value" 3
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !events with
   | [
       Signal.Initialized 1;
       Changed { old_value = 1; new_value = 3 };
     ] -> ()
   | _ -> Alcotest.fail "expected coalesced observer-phase mutation events");
  run_ok rt (Signal.Observer.dispose observer)

let test_dispose_unlinks_observer_from_graph () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let finalized = ref false in
  let create_and_dispose () =
    let payload = Bytes.make 1 '\000' in
    Gc.finalise (fun _ -> finalized := true) payload;
    let observer =
      run_ok rt
        (Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
             Effect.sync (fun () -> ignore (Bytes.get payload 0))))
    in
    run_ok rt (Signal.Observer.dispose observer)
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

let test_signal_version_overflow_does_not_publish_partial_snapshot () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Overflow_signal.Var.create 1 in
  let signal = Overflow_signal.Var.watch source in
  let events = ref [] in
  let observer =
    run_ok rt
      (Overflow_signal.Observer.observe signal (fun update ->
           Effect.sync (fun () -> events := update :: !events)))
  in
  run_ok rt Overflow_signal.stabilize;
  Overflow_signal.Private_test_hooks.set_signal_version signal max_int;
  run_ok rt (Overflow_signal.Var.set source 2);
  expect_fail "signal version overflow" (counter_overflow "signal version")
    (Eta_eio.Runtime.run rt (widen Overflow_signal.stabilize));
  Alcotest.(check int) "old snapshot remains after version overflow" 1
    (run_ok rt (Overflow_signal.Observer.read observer));
  Overflow_signal.Private_test_hooks.set_signal_version signal 0;
  run_ok rt Overflow_signal.stabilize;
  Alcotest.(check int) "retry publishes pending source" 2
    (run_ok rt (Overflow_signal.Observer.read observer));
  (match List.rev !events with
   | [ Overflow_signal.Initialized 1;
       Changed { old_value = 1; new_value = 2 } ] ->
       ()
   | _ -> Alcotest.fail "expected retry to deliver changed event");
  run_ok rt (Overflow_signal.Observer.dispose observer)

let test_var_create_counter_overflow_raises_graph_error () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  with_test_graph_lane rt Overflow_signal.graph (fun lane ->
      Eta_signal_testable.Graph.set_next_node_id Overflow_signal.graph lane
        max_int);
  match Overflow_signal.Var.create 1 with
  | exception Overflow_signal.Graph_error (`Counter_overflow name)
    when String.equal name "node id" ->
      ()
  | exception Overflow_signal.Graph_error _ ->
      Alcotest.fail "var create counter overflow: unexpected graph error"
  | exception exn ->
      Alcotest.failf "var create counter overflow: unexpected exception %s"
        (Printexc.to_string exn)
  | _ -> Alcotest.fail "var create counter overflow: expected graph error"

let test_stabilization_generation_overflow_is_typed_failure () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  with_test_graph_lane rt Overflow_signal.graph (fun lane ->
      Eta_signal_testable.Graph.set_generation Overflow_signal.graph lane
        max_int);
  expect_fail "stabilization generation overflow"
    (counter_overflow "stabilization generation")
    (Eta_eio.Runtime.run rt (widen Overflow_signal.stabilize))

let test_timer_refresh_token_overflow_is_typed_failure () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  with_test_graph_lane rt Overflow_signal.graph (fun lane ->
      Eta_signal_testable.Graph.set_next_timer_refresh_token
        Overflow_signal.graph lane max_int);
  expect_fail "timer refresh token overflow"
    (counter_overflow "timer refresh token")
    (Eta_eio.Runtime.run rt (widen Overflow_signal.stabilize))

let test_stats_counter_saturation_is_typed_failure () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let check name set_counter =
    with_test_graph_lane rt Overflow_signal.graph (fun lane ->
        set_counter lane max_int);
    expect_fail (name ^ " saturation") (counter_overflow name)
      (Eta_eio.Runtime.run rt (widen (Overflow_signal.stats ())));
    with_test_graph_lane rt Overflow_signal.graph (fun lane ->
        set_counter lane 0)
  in
  let check_stats_count name count =
    Fun.protect
      ~finally:(fun () ->
        Overflow_signal.Private_test_hooks.set_stats_count_override count None)
      (fun () ->
        Overflow_signal.Private_test_hooks.set_stats_count_override count
          (Some max_int);
        expect_fail (name ^ " saturation") (counter_overflow name)
          (Eta_eio.Runtime.run rt (widen (Overflow_signal.stats ()))))
  in
  check "stats pure_snapshot_commit_count" (fun lane value ->
      Eta_signal_testable.Graph.set_pure_snapshot_commit_count
        Overflow_signal.graph lane value);
  check "stats callback_delivery_count" (fun lane value ->
      Eta_signal_testable.Graph.set_counter Overflow_signal.graph
        lane Eta_signal_testable.Graph.Callback_delivery_count value);
  check_stats_count "stats total_node_count"
    Overflow_signal.Private_test_hooks.Stats_total_node_count;
  check "stats recompute_count" (fun lane value ->
      Eta_signal_testable.Graph.set_counter Overflow_signal.graph
        lane Eta_signal_testable.Graph.Recompute_count value);
  check "stats dynamic_scope_invalidations" (fun lane value ->
      Eta_signal_testable.Graph.set_counter Overflow_signal.graph
        lane Eta_signal_testable.Graph.Dynamic_scope_invalidations value);
  check "stats nodes_became_necessary" (fun lane value ->
      Eta_signal_testable.Graph.set_counter Overflow_signal.graph
        lane Eta_signal_testable.Graph.Nodes_became_necessary value);
  check "stats nodes_became_unnecessary" (fun lane value ->
      Eta_signal_testable.Graph.set_counter Overflow_signal.graph
        lane Eta_signal_testable.Graph.Nodes_became_unnecessary value);
  check "stats stream_bridge_drop_count" (fun lane value ->
      Eta_signal_testable.Graph.set_stream_bridge_metrics
        Overflow_signal.graph lane
        (Eta_signal_testable.Stream_bridge.create_metrics
           ~drop_count:value ()));
  check_stats_count "stats necessary_node_count"
    Overflow_signal.Private_test_hooks.Stats_necessary_node_count;
  check_stats_count "stats dead_node_count"
    Overflow_signal.Private_test_hooks.Stats_dead_node_count;
  check_stats_count "stats lane_cancelled_waiter_count"
    Overflow_signal.Private_test_hooks.Stats_lane_cancelled_waiter_count

let test_observer_registration_and_self_disposal_inside_callback () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let primary_events = ref [] in
  let late_events = ref [] in
  let primary_ref = ref None in
  let late_ref = ref None in
  let primary =
    run_ok rt
      (Signal.Observer.observe signal (fun update ->
           Effect.sync (fun () -> primary_events := update :: !primary_events)
           |> Effect.bind (fun () ->
                  match (!primary_ref, update) with
                  | Some primary, Signal.Initialized _ ->
                      Signal.Observer.observe signal (record_observer late_events)
                      |> Effect.map_error (fun _ -> `Observer_failed)
                      |> Effect.bind (fun late ->
                             Effect.sync (fun () -> late_ref := Some late)
                             |> Effect.bind (fun () ->
                                    Signal.Observer.dispose primary
                                    |> Effect.or_die (fun err ->
                                           Signal.Graph_error err)))
                  | _ -> Effect.unit)))
  in
  primary_ref := Some primary;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "late observer not run in current stabilization" 0
    (List.length !late_events);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "late observer initializes next stabilization" 1
    (List.length !late_events);
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "self-disposed observer has no future callbacks" 1
    (List.length !primary_events);
  (match List.rev !late_events with
   | [
       Signal.Initialized 1;
       Changed { old_value = 1; new_value = 2 };
     ] -> ()
   | _ -> Alcotest.fail "unexpected late observer events");
  (match !late_ref with
   | Some late -> run_ok rt (Signal.Observer.dispose late)
   | None -> Alcotest.fail "late observer was not registered")

let test_observer_effects_before_later_failure_are_not_rolled_back () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let effects = ref [] in
  let first_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           Effect.sync (fun () -> effects := "first" :: !effects)))
  in
  let failing_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ -> Effect.fail `Observer_failed))
  in
  expect_fail "later observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check (list string))
    "already-run observer effect remains" [ "first" ] (List.rev !effects);
  run_ok rt (Signal.Observer.dispose first_observer);
  run_ok rt (Signal.Observer.dispose failing_observer)

let test_observer_callback_construction_defect_does_not_poison_graph () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_observer_callback_interruption_releases_phase () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let block_callback = ref true in
  let started, started_resolver = Eio.Promise.create () in
  let cancel_ctx = ref None in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
           if !block_callback then (
             block_callback := false;
             Effect.sync (fun () -> Eio.Promise.resolve started_resolver ())
             |> Effect.bind (fun () -> Effect.never))
           else Effect.unit))
  in
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  Eio.Promise.await started;
  wait_until "observer cancellation context" (fun () -> Option.is_some !cancel_ctx);
  Alcotest.(check int) "snapshot published before observer interruption" 1
    (run_ok rt (Signal.Observer.read observer));
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  await_cancelled "observer callback stabilize" stabilizer;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "phase released after observer interruption" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_observe_failure_during_timer_start_does_not_leak () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let now_calls = ref 0 in
  let now_ms () =
    incr now_calls;
    if !now_calls <= 2 then 0
    else failwith "timer start clock failure"
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ()) in
  let before = run_ok rt (Signal.stats ()) in
  expect_die "stream observe timer start failure"
    (Eta_eio.Runtime.run rt
       (widen (Signal.Stream.observe ~capacity:1 signal)));
  let after = run_ok rt (Signal.stats ()) in
  Alcotest.(check int)
    "failed stream observe does not leak observer"
    before.Signal.active_observer_count after.Signal.active_observer_count;
  run_ok rt Signal.stabilize

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
    Signal.bind (Signal.Var.watch use_timer) (fun enabled ->
        if enabled then timer else Signal.const 0)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial non-timer branch" 0
    (run_ok rt (Signal.Observer.read observer));
  fail_next_now := true;
  run_ok rt (Signal.Var.set use_timer true);
  expect_die "timer branch start failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "failed start installed no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "timer restarted and ticked" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

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
    Signal.bind (Signal.Var.watch use_timer) (fun enabled ->
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
    run_ok rt
      (Signal.Observer.observe selected (fun update ->
           Effect.sync (fun () -> events := update :: !events)))
  in
  run_ok rt Signal.stabilize;
  let after_initial = run_ok rt (Signal.stats ()) in
  fail_next_now := true;
  run_ok rt (Signal.Var.set use_timer true);
  expect_die "timer branch start failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int)
    "post-commit failed start publishes snapshot for reads" 0
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "failed start did not deliver callback" [ -1 ]
    (event_new_values ());
  let after_failure = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "failed cleanup does not complete delivery"
    after_initial.Signal.callback_delivery_count
    after_failure.Signal.callback_delivery_count;
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int)) "retry delivers pending event once" [ -1; 0 ]
    (event_new_values ());
  run_ok rt (Signal.Observer.dispose observer)

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
    Signal.bind (Signal.Var.watch use_timers) (fun enabled ->
        if enabled then Signal.all [ failing; unstarted ]
        else Signal.const [ 0; 0 ])
  in
  let observer =
    run_ok rt (Signal.Observer.observe observed (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  fail_next_now := true;
  run_ok rt (Signal.Var.set use_timers true);
  expect_die "multi-timer start failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
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
  let dot = run_ok rt (Signal.to_dot ~options ()) in
  Alcotest.(check int)
    "failed refresh leaves no active timer without a start" 0
    (count_occurrences dot
       "timer_active=true timer_running=none timer_cancel=false");
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 2;
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int)) "both timers restart and tick" [ 1; 1 ]
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_reentrant_stabilization_is_typed_failure () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  expect_fail "reentrant update" (( = ) `Reentrant_update)
    (Eta_eio.Runtime.run rt
       (widen
          (Signal.Var.update_effect source (fun current ->
               Signal.Var.update_effect source (fun _ -> Effect.pure (current + 10))
               |> Effect.map (fun _ -> current + 1)))));
  Alcotest.(check int) "source unchanged" 1 (Signal.Var.value source)

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
  expect_fail "concurrent set" (( = ) `Reentrant_update)
    (Eta_eio.Runtime.run rt (widen (Signal.Var.set source 100)));
  Alcotest.(check int) "failed set leaves value unchanged" 1
    (Signal.Var.value source);
  Eio.Promise.resolve release_resolver ();
  Alcotest.(check int) "effectful update still commits" 11
    (expect_exit_ok "effectful update" (Eio.Promise.await_exn updating));
  Alcotest.(check int) "slot released after update" 12
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.pure (current + 1))))

let test_effectful_update_success_publishes_once () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_effectful_update_sees_pending_source_value () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let seen = ref None in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe observed (record_observer events))
  in
  run_ok rt Signal.stabilize;
  events := [];
  run_ok rt (Signal.Var.set source 2);
  Alcotest.(check int) "observer still has old snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "update result" 3
    (run_ok rt
       (Signal.Var.update_effect source (fun current ->
            Effect.sync (fun () -> seen := Some current)
            |> Effect.map (fun () -> current + 1))));
  Alcotest.(check (option int)) "callback sees pending source value" (Some 2)
    !seen;
  Alcotest.(check int) "source stores update result" 3 (Signal.Var.value source);
  Alcotest.(check int) "no event before stabilization" 0 (List.length !events);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer sees coalesced update" 3
    (run_ok rt (Signal.Observer.read observer));
  (match !events with
   | [ Signal.Changed { old_value = 1; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected pending set and effectful update to coalesce");
  run_ok rt (Signal.Observer.dispose observer)

let test_effectful_update_allows_other_variable_mutation () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_effectful_update_acquire_interruption_releases_slot () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := true;
  Cleanup_interrupt_runtime.now := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  (match
     Runtime.run rt
       (widen
          (Signal.Var.update_effect source (fun current ->
               Effect.pure (current + 1))))
   with
  | Exit.Error _ -> ()
  | Exit.Ok value ->
      Alcotest.failf "expected injected interruption, got Ok %d" value);
  Alcotest.(check int) "interrupted acquire leaves value unchanged" 1
    (Signal.Var.value source);
  (match
     Runtime.run rt
       (widen
          (Signal.Var.update_effect source (fun current ->
               Effect.pure (current + 1))))
   with
  | Exit.Ok value ->
      Alcotest.(check int) "slot released after acquire interruption" 2 value
  | Exit.Error cause ->
      Alcotest.failf "expected released slot, got %a" (Cause.pp pp_hidden) cause)

let test_queued_graph_operation_cancellation_does_not_run () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let before_stats = run_ok rt (Signal.stats ()) in
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
    (run_ok rt (Signal.Observer.read observer));
  let after_stats = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "cancelled waiter counted"
    (before_stats.Signal.lane_cancelled_waiter_count + 1)
    after_stats.Signal.lane_cancelled_waiter_count;
  Alcotest.(check int) "cancelled waiter not left waiting" 0
    after_stats.Signal.lane_waiter_count

let test_stats_report_lane_waiters () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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
  let stats =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen (Signal.stats ())))
  in
  let queued_set =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen (Signal.Var.set source 2)))
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool) "stats waits behind graph lane" false
    (Eio.Promise.is_resolved stats);
  Alcotest.(check bool) "set waits behind graph lane" false
    (Eio.Promise.is_resolved queued_set);
  Eio.Promise.resolve release_resolver ();
  ignore (expect_exit_ok "stabilizer" (Eio.Promise.await_exn stabilizer) : unit);
  let snapshot = expect_exit_ok "queued stats" (Eio.Promise.await_exn stats) in
  Alcotest.(check bool) "stats reports waiters queued behind it" true
    (snapshot.Signal.lane_waiter_count > 0);
  ignore (expect_exit_ok "queued set" (Eio.Promise.await_exn queued_set) : unit);
  Alcotest.(check int) "queued set ran after stats" 2 (Signal.Var.value source);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer sees queued set" 2
    (run_ok rt (Signal.Observer.read observer))

let test_active_graph_operation_interruption_releases_lane () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_graph_lane_granted_waiter_is_not_stranded_if_resolve_raises () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let fail_next_grant_resolve = ref false in
  let grant_resolve_failures = ref 0 in
  let module Base =
    (val Eta_eio.runtime ~sw ~clock : Runtime_contract.RUNTIME)
  in
  let module Hooked_runtime = struct
    type scope = Base.scope
    type cancel_context = Base.cancel_context
    type 'a promise = 'a Base.promise
    type 'a resolver = 'a Base.resolver
    type 'a stream = 'a Base.stream

    let root_scope = Base.root_scope
    let now_ms = Base.now_ms
    let sleep = Base.sleep
    let protect = Base.protect
    let run_scope = Base.run_scope
    let fail_scope = Base.fail_scope
    let fork = Base.fork
    let fork_daemon = Base.fork_daemon
    let await_cancel = Base.await_cancel
    let yield = Base.yield
    let check = Base.check
    let create_promise = Base.create_promise

    let resolve_promise resolver value =
      if !fail_next_grant_resolve then (
        fail_next_grant_resolve := false;
        incr grant_resolve_failures;
        raise Lane_grant_resolution_failed);
      Base.resolve_promise resolver value

    let await_promise = Base.await_promise
    let create_stream = Base.create_stream
    let stream_add = Base.stream_add
    let stream_take = Base.stream_take
    let stream_take_nonblocking = Base.stream_take_nonblocking
    let with_worker_context = Base.with_worker_context
    let in_worker_context = Base.in_worker_context
    let cancellation_reason = Base.cancellation_reason
    let multiple_exceptions = Base.multiple_exceptions
    let cancel_sub = Base.cancel_sub
    let cancel = Base.cancel
    let local_get = Base.local_get
    let local_with_binding = Base.local_with_binding
    let current_fiber_id = Base.current_fiber_id
    let with_fiber_identity = Base.with_fiber_identity
  end in
  let rt =
    Runtime.create_with_runtime
      (module Hooked_runtime : Runtime_contract.RUNTIME)
      ()
  in
  Fun.protect
    ~finally:Signal.Private_test_hooks.clear
    (fun () ->
      let started, started_resolver = Eio.Promise.create () in
      let release, release_resolver = Eio.Promise.create () in
      let hook_ran = ref false in
      let hook =
        {
          Signal.Private_test_hooks.run =
            (fun () ->
              Effect.sync (fun () ->
                  if not !hook_ran then (
                    hook_ran := true;
                    Eio.Promise.resolve started_resolver ();
                    Eio.Promise.await release)));
        }
      in
      Signal.Private_test_hooks.with_hook
        Signal.Private_test_hooks.After_graph_lane_acquired hook
      @@ fun () ->
      let first_stats =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt (widen (Signal.stats ())))
      in
      Eio.Promise.await started;
      let queued_stats =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt (widen (Signal.stats ())))
      in
      for _ = 1 to 5 do
        Eta_test.Async.yield ()
      done;
      Alcotest.(check bool) "stats waits behind graph lane" false
        (Eio.Promise.is_resolved queued_stats);
      fail_next_grant_resolve := true;
      Eio.Promise.resolve release_resolver ();
      for _ = 1 to 20 do
        Eta_test.Async.yield ()
      done;
      if not (Eio.Promise.is_resolved first_stats) then
        Alcotest.fail "first stats did not finish after lane release";
      ignore
        (expect_exit_ok "releasing stats ignores grant resolver failure"
           (Eio.Promise.await_exn first_stats)
          : Signal.stats);
      for _ = 1 to 20 do
        Eta_test.Async.yield ()
      done;
      if not (Eio.Promise.is_resolved queued_stats) then
        Alcotest.fail "queued stats was stranded after committed lane grant";
      let queued_snapshot =
        expect_exit_ok "queued stats after grant retry"
          (Eio.Promise.await_exn queued_stats)
      in
      Alcotest.(check int) "queued stats saw no stranded waiters" 0
        queued_snapshot.Signal.lane_waiter_count;
      Alcotest.(check int) "grant resolver failed once" 1
        !grant_resolve_failures;
      let later_snapshot = run_ok rt (Signal.stats ()) in
      Alcotest.(check int) "future stats calls do not hang" 0
        later_snapshot.Signal.lane_waiter_count)

let test_graph_lane_acquisition_stays_on_owner_domain () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let owner = Domain.self () in
  let acquired_domains = ref [] in
  Fun.protect
    ~finally:Signal.Private_test_hooks.clear
    (fun () ->
      let hook =
        {
          Signal.Private_test_hooks.run =
            (fun () ->
              Effect.sync (fun () ->
                  acquired_domains := Domain.self () :: !acquired_domains));
        }
      in
      Signal.Private_test_hooks.with_hook
        Signal.Private_test_hooks.After_graph_lane_acquired hook
      @@ fun () ->
      let source = Signal.Var.create 1 in
      let started, started_resolver = Eio.Promise.create () in
      let release, release_resolver = Eio.Promise.create () in
      let block_once = ref true in
      let signal =
        Signal.Var.watch source
        |> Signal.map (fun value ->
               if !block_once then (
                 block_once := false;
                 Eio.Promise.resolve started_resolver ();
                 Eio.Promise.await release);
               value)
      in
      let observer =
        run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
      in
      let stabilizer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eta_eio.Runtime.run rt (widen Signal.stabilize))
      in
      Eio.Promise.await started;
      let queued_stats =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eta_eio.Runtime.run rt (widen (Signal.stats ())))
      in
      for _ = 1 to 5 do
        Eta_test.Async.yield ()
      done;
      Alcotest.(check bool) "stats waits behind graph lane" false
        (Eio.Promise.is_resolved queued_stats);
      Eio.Promise.resolve release_resolver ();
      ignore
        (expect_exit_ok "stabilizer" (Eio.Promise.await_exn stabilizer) : unit);
      ignore
        (expect_exit_ok "queued stats" (Eio.Promise.await_exn queued_stats)
          : Signal.stats);
      run_ok rt (Signal.Observer.dispose observer);
      Alcotest.(check bool)
        "graph lane acquisitions stayed on owner domain" true
        (List.for_all (fun domain -> domain = owner) !acquired_domains);
      Alcotest.(check bool)
        "immediate and queued graph lane acquisitions were observed" true
        (List.length !acquired_domains >= 3))

let test_nested_runtime_graph_read_reenters_graph_lane () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Runtime_a = Make_isolated_sync_runtime () in
  let module Runtime_b = Make_isolated_sync_runtime () in
  let rt_a =
    Runtime.create_with_runtime
      (module Runtime_a : Runtime_contract.RUNTIME)
      ()
  in
  let rt_b =
    Runtime.create_with_runtime
      (module Runtime_b : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let nested_stats = ref None in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           nested_stats := Some (Runtime.run rt_b (widen (Signal.stats ())));
           value)
  in
  let observer =
    expect_exit_ok "observe"
      (Runtime.run rt_a
         (widen (Signal.Observer.observe signal (fun _ -> Effect.unit))))
  in
  ignore
    (expect_exit_ok "stabilize" (Runtime.run rt_a (widen Signal.stabilize))
      : unit);
  (match !nested_stats with
  | Some (Exit.Ok _stats) -> ()
  | Some (Exit.Error cause) ->
      Alcotest.failf "nested graph read should reenter lane, got %a"
        (Cause.pp pp_hidden) cause
  | None -> Alcotest.fail "nested graph read did not run");
  ignore
    (expect_exit_ok "dispose"
       (Runtime.run rt_a (widen (Signal.Observer.dispose observer)))
      : unit)

let test_observer_read_waits_for_graph_lane () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let block_once = ref false in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           if !block_once then (
             block_once := false;
             Eio.Promise.resolve started_resolver ();
             Eio.Promise.await release);
           value)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  block_once := true;
  run_ok rt (Signal.Var.set source 2);
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  Eio.Promise.await started;
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)))
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool) "read waits behind graph lane" false
    (Eio.Promise.is_resolved read);
  Eio.Promise.resolve release_resolver ();
  ignore (expect_exit_ok "stabilizer" (Eio.Promise.await_exn stabilizer) : unit);
  Alcotest.(check int) "read observes committed value after lane release" 2
    (expect_exit_ok "queued read" (Eio.Promise.await_exn read))

let test_time_interval_construction_waits_for_graph_lane () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let started, started_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let block_once = ref true in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           if !block_once then (
             block_once := false;
             Eio.Promise.resolve started_resolver ();
             Eio.Promise.await release);
           value)
  in
  ignore
    (run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
      : int Signal.observer);
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  Eio.Promise.await started;
  let constructor =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen (Signal.Time.interval (Duration.ms 10))))
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool) "timer construction waits behind graph lane" false
    (Eio.Promise.is_resolved constructor);
  Eio.Promise.resolve release_resolver ();
  ignore (expect_exit_ok "stabilizer" (Eio.Promise.await_exn stabilizer) : unit);
  expect_fail "timer constructor sees ambiguous phase after lane release"
    (( = ) `Ambiguous_scope)
    (Eio.Promise.await_exn constructor)

let test_observer_delivery_acknowledgement_uses_graph_lane () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let count_before_ack = ref None in
  let observer =
    expect_exit_ok "observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe observed (fun _update ->
                 Effect.sync (fun () ->
                     count_before_ack :=
                       Some !Cleanup_interrupt_runtime.local_binding_count)))))
  in
  Cleanup_interrupt_runtime.local_binding_count := 0;
  ignore
    (expect_exit_ok "stabilize"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  let before_ack =
    match !count_before_ack with
    | Some count -> count
    | None -> Alcotest.fail "observer callback did not run"
  in
  Alcotest.(check int)
    "acknowledgement, delivery completion, and phase cleanup enter the graph lane"
    3
    (!Cleanup_interrupt_runtime.local_binding_count - before_ack);
  ignore
    (expect_exit_ok "observer disposal"
       (Runtime.run rt (widen (Signal.Observer.dispose observer)))
      : unit)

let test_time_timer_generation_overflow_fails_loudly () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Overflow_signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Overflow_signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  Overflow_signal.Private_test_hooks.set_timer_generation signal max_int;
  expect_fail "timer generation overflow"
    (counter_overflow "timer generation")
    (Eta_eio.Runtime.run rt (widen (Overflow_signal.Observer.dispose observer)))

let test_time_timer_start_generation_overflow_is_precommit_failure () =
  let module Overflow_signal = Eta_signal_testable.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let use_timer = Overflow_signal.Var.create false in
  let timer_signal =
    run_ok rt (Overflow_signal.Time.interval (Duration.ms 10))
  in
  Overflow_signal.Private_test_hooks.set_timer_generation timer_signal max_int;
  let selected =
    Overflow_signal.bind (Overflow_signal.Var.watch use_timer) (fun active ->
        if active then timer_signal else Overflow_signal.const (-1))
  in
  let observer =
    run_ok rt (Overflow_signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Overflow_signal.stabilize;
  Alcotest.(check int) "initial inactive branch" (-1)
    (run_ok rt (Overflow_signal.Observer.read observer));
  run_ok rt (Overflow_signal.Var.set use_timer true);
  expect_fail "timer start generation overflow"
    (counter_overflow "timer generation")
    (Eta_eio.Runtime.run rt (widen Overflow_signal.stabilize));
  Alcotest.(check int) "snapshot did not switch after overflow" (-1)
    (run_ok rt (Overflow_signal.Observer.read observer))

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
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "late interval wake rescheduled" (fun () -> !sleep_calls >= 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "late interval wake catches up" 10
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer);
  release ()

let with_cooperative_timer_host ?(initial_ms = 0) ?(jump_ms = 10_000) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_ms = ref initial_ms in
  let sleep_calls = ref 0 in
  let yield_calls = ref 0 in
  let logger = Logger.in_memory () in
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
    ~now_ms:(fun () -> !now_ms) ~logger:(Logger.as_capability logger)
  @@ fun rt ->
  f rt sleep_calls yield_calls logger

let test_time_step_replay_catch_up_yields_between_batches () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host @@ fun rt sleep_calls yield_calls _logger ->
  let signal =
    run_ok rt (Signal.Time.step_replay ~every:(Duration.ms 10) ~initial:0 succ)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "catch-up timer attempted next sleep" (fun () -> !sleep_calls >= 2);
  Alcotest.(check bool)
    "large catch-up yielded cooperatively" true
    (!yield_calls > 0);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "step_replay catch-up applies every cadence" 1_000
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_step_replay_saturated_catch_up_yields_without_completion () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~jump_ms:max_int
  @@ fun rt sleep_calls yield_calls logger ->
  let applied = ref 0 in
  let signal =
    run_ok rt
      (Signal.Time.step_replay ~every:(Duration.ms 1) ~initial:0 (fun value ->
           incr applied;
           value + 1))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "saturated step_replay catch-up yielded" (fun () ->
      !yield_calls >= 3);
  Alcotest.(check int) "saturated catch-up still in first wake" 1
    !sleep_calls;
  Alcotest.(check bool)
    "saturated step_replay catch-up made cooperative progress" true
    (!applied >= 3 * 64);
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.(check int) "saturated step_replay logs no daemon diagnostic" 0
    (List.length (Logger.dump logger))

let test_time_step_saturated_catch_up_runs_once () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls yield_calls logger ->
  let applied = ref 0 in
  let missed_seen = ref None in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 1) ~initial:0 (fun ~missed value ->
           incr applied;
           missed_seen := Some missed;
           if value > max_int - missed then max_int else value + missed))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "saturated step catch-up processed" (fun () ->
      !applied >= 1);
  Alcotest.(check int) "saturated step used one update" 1
    !applied;
  let missed =
    match !missed_seen with
    | Some missed -> missed
    | None -> Alcotest.fail "step did not report missed cadences"
  in
  Alcotest.(check int) "saturated step missed count" max_int missed;
  Alcotest.(check int) "saturated step catch-up used one sleep" 1 !sleep_calls;
  Alcotest.(check int) "saturated step did not batch-yield" 0
    !yield_calls;
  Alcotest.(check int) "saturated step logs no daemon diagnostic" 0
    (List.length (Logger.dump logger));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "saturated step reaches max_int" max_int
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_large_catch_up_applies_beyond_old_cap () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~jump_ms:10_250
  @@ fun rt sleep_calls yield_calls logger ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "large catch-up processed" (fun () -> !sleep_calls >= 2);
  Alcotest.(check int) "large interval catch-up coalesced" 0 !yield_calls;
  Alcotest.(check int) "large catch-up logs no daemon diagnostic" 0
    (List.length (Logger.dump logger));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "large catch-up applies every interval cadence" 1_025
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.(check int) "dispose logs no daemon diagnostic" 0
    (List.length (Logger.dump logger))

let test_time_interval_saturated_catch_up_coalesces () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls yield_calls logger ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 1)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "saturated interval catch-up processed" (fun () ->
      !sleep_calls >= 1);
  Alcotest.(check int) "saturated interval catch-up did not batch-yield" 0
    !yield_calls;
  Alcotest.(check int) "saturated interval catch-up logs no daemon diagnostic" 0
    (List.length (Logger.dump logger));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "saturated interval catch-up reaches max_int" max_int
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_deadline_saturated_catch_up_does_not_overflow () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  (* Start at -1 so the first 1ms cadence is due at 0, reproducing the
     saturated successor edge through public timer APIs. *)
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls _yield_calls logger ->
  let signal =
    run_ok rt (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms 2))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "saturated deadline timer woke" (fun () -> !sleep_calls >= 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "saturated catch-up reaches deadline" true
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "saturated catch-up logs no daemon diagnostic" 0
    (List.length (Logger.dump logger));
  run_ok rt (Signal.Observer.dispose observer)

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
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Eio.Promise.await daemon_started;
  Alcotest.(check int) "uncancellable start has not installed a sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  run_ok rt (Signal.Observer.dispose observer);
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
       | Some rt, Some observer -> run_ok rt (Signal.Observer.dispose observer)
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
    run_ok rt (Signal.Time.now ~every:(Duration.days 1) ())
    |> Signal.map Signal.Time.to_ms
  in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then now_signal else Signal.const (-1))
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  observer_ref := Some observer;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial inactive branch" (-1)
    (run_ok rt (Signal.Observer.read observer));
  drop_demand_during_update_on_start := true;
  run_ok rt (Signal.Var.set use_timer true);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "start update was stopped before daemon start" 3
    !now_calls;
  expect_fail "observer disposed during update_on_start"
    (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)));
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
  let dot = run_ok rt (Signal.to_dot ~options ()) in
  Alcotest.(check int) "stopped update_on_start queued no source update" 0
    (count_occurrences dot "queued=true");
  Alcotest.(check int) "stopped update_on_start left no uncancellable timer" 0
    (count_occurrences dot "timer_state=running_uncancellable")

let test_time_timer_becomes_inert_after_dispose () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_time_timer_dispose_cancels_sleeping_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Observer.dispose observer);
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

let with_timer_cancel_tracking_host f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let owner_domain = Domain.self () in
  let graph_lifecycle_depth_key = Eio.Fiber.create_key () in
  let cancel_inside_local_binding = ref false in
  let cancel_outside_owner_domain = ref false in
  let fail_next_cancel = ref false in
  let graph_lifecycle_depth () =
    try Option.value (Eio.Fiber.get graph_lifecycle_depth_key) ~default:0
    with Stdlib.Effect.Unhandled _ -> 0
  in
  (* Eta_eio transports Runtime_contract locals as one context table. With
     Tracer.noop below and auto-instrumentation disabled by default, the only
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
        let depth =
          if context_has_graph_lifecycle_depth value then
            graph_lifecycle_depth () + 1
          else graph_lifecycle_depth ()
        in
        Eio.Fiber.with_binding graph_lifecycle_depth_key depth
          (fun () -> Eio.Fiber.with_binding key value f)

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
        Eio.Cancel.cancel cancel_context exn;
        if !fail_next_cancel then (
          fail_next_cancel := false;
          failwith "timer cancel failure")
    end
  end in
  let host =
    Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock env)
    ~tracer:Tracer.noop @@ fun rt ->
  f clock rt cancel_inside_local_binding cancel_outside_owner_domain
    fail_next_cancel

let test_time_timer_cancel_runs_outside_graph_lifecycle () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt cancel_inside_local_binding cancel_outside_owner_domain
         _fail_next_cancel ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.(check bool)
    "timer cancel ran outside graph lifecycle local binding" false
    !cancel_inside_local_binding;
  Alcotest.(check bool)
    "timer cancel ran on owner domain" false !cancel_outside_owner_domain

let test_time_invalidated_timer_cancel_runs_outside_graph_lifecycle () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt cancel_inside_local_binding cancel_outside_owner_domain
         _fail_next_cancel ->
  let use_timer = Signal.Var.create true in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun active ->
        if active then run_ok rt (Signal.Time.interval (Duration.days 1))
        else Signal.const 0)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Var.set use_timer false);
  run_ok rt Signal.stabilize;
  Alcotest.(check bool)
    "invalidated timer cancel ran outside graph lifecycle local binding" false
    !cancel_inside_local_binding;
  Alcotest.(check bool)
    "invalidated timer cancel ran on owner domain" false
    !cancel_outside_owner_domain;
  run_ok rt (Signal.Observer.dispose observer)

let test_time_timer_cancel_failure_preserves_committed_snapshot () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_timer_cancel_tracking_host
  @@ fun clock rt _cancel_inside_local_binding _cancel_outside_owner_domain
         fail_next_cancel ->
  let use_timer = Signal.Var.create true in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun active ->
        if active then run_ok rt (Signal.Time.interval (Duration.days 1))
        else Signal.const 42)
  in
  let callback_values = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe selected (function
        | Signal.Initialized value | Changed { new_value = value; _ } ->
            Effect.sync (fun () ->
                callback_values := value :: !callback_values)))
  in
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  Alcotest.(check (list int))
    "initial callback delivered" [ 0 ] (List.rev !callback_values);
  fail_next_cancel := true;
  run_ok rt (Signal.Var.set use_timer false);
  expect_finalizer_die "timer cancel failure" "timer cancel failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int)
    "snapshot committed before timer cancel failure" 42
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int))
    "timer cancel failure did not deliver callback" [ 0 ]
    (List.rev !callback_values);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "retry delivers pending branch switch" [ 0; 42 ]
    (List.rev !callback_values);
  run_ok rt (Signal.Observer.dispose observer)

let test_disposal_hooks_continue_after_failure () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let later_hook_ran = ref false in
  let observer =
    run_ok rt
      (Signal.Observer.observe_with_hooks
         ~on_finish:
           [
             (fun _ -> failwith "first dispose hook failure");
             (fun _ -> later_hook_ran := true);
             (fun _ -> failwith "third dispose hook failure");
           ]
         (Signal.Var.watch source) (fun _ -> Effect.unit))
  in
  let exit = Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer)) in
  expect_finalizer_die "first dispose hook failure"
    "first dispose hook failure" exit;
  expect_finalizer_die "third dispose hook failure"
    "third dispose hook failure" exit;
  Alcotest.(check bool) "later hook still ran" true !later_hook_ran

let test_stabilize_disposal_hook_failure_preserves_committed_snapshot () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let use_branch = Signal.Var.create true in
  let captured_branch = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_branch) (fun active ->
        if active then (
          let branch = Signal.const 1 in
          captured_branch := Some branch;
          branch)
        else Signal.const 2)
  in
  let callback_values = ref [] in
  let selected_observer =
    run_ok rt
      (Signal.Observer.observe selected (function
        | Signal.Initialized value | Changed { new_value = value; _ } ->
            Effect.sync (fun () ->
                callback_values := value :: !callback_values)))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "initial callback delivered" [ 1 ] (List.rev !callback_values);
  let branch =
    match !captured_branch with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured dynamic branch"
  in
  let _branch_observer =
    run_ok rt
      (Signal.Observer.observe_with_hooks
         ~on_finish:[ (fun _ -> failwith "branch dispose hook failure") ]
         branch (fun _ -> Effect.unit))
  in
  run_ok rt (Signal.Var.set use_branch false);
  expect_finalizer_die "branch dispose hook failure"
    "branch dispose hook failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int)
    "snapshot committed before disposal hook failure" 2
    (run_ok rt (Signal.Observer.read selected_observer));
  Alcotest.(check (list int))
    "disposal hook failure did not deliver callback" [ 1 ]
    (List.rev !callback_values);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "retry delivers pending branch switch" [ 1; 2 ]
    (List.rev !callback_values);
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_observer_dispose_interruption_runs_finish_hooks () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.now := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let hook_ran = ref false in
  let observer =
    expect_exit_ok "observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe_with_hooks
               ~on_finish:[ (fun _ -> hook_ran := true) ]
               (Signal.Var.watch source) (fun _ -> Effect.unit))))
  in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := true;
  (match Runtime.run rt (widen (Signal.Observer.dispose observer)) with
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected disposal interruption");
  Alcotest.(check bool)
    "interrupted dispose still runs finish hook" true !hook_ran

let test_stabilize_interruption_runs_invalidation_hooks () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.now := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let use_branch = Signal.Var.create true in
  let captured_branch = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_branch) (fun active ->
        if active then (
          let branch = Signal.const 1 in
          captured_branch := Some branch;
          branch)
        else Signal.const 0)
  in
  let selected_observer =
    expect_exit_ok "selected observer registration"
      (Runtime.run rt
         (widen (Signal.Observer.observe selected (fun _ -> Effect.unit))))
  in
  ignore
    (expect_exit_ok "initial stabilize"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  let branch =
    match !captured_branch with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured dynamic branch"
  in
  let hook_ran = ref false in
  let _branch_observer =
    expect_exit_ok "branch observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe_with_hooks
               ~on_finish:[ (fun _ -> hook_ran := true) ]
               branch (fun _ -> Effect.unit))))
  in
  ignore
    (expect_exit_ok "switch branch"
       (Runtime.run rt (widen (Signal.Var.set use_branch false)))
      : unit);
  Cleanup_interrupt_runtime.interrupt_next_protect_return := true;
  (match Runtime.run rt (widen Signal.stabilize) with
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected stabilize interruption");
  Alcotest.(check bool)
    "interrupted stabilize still runs invalidation hook" true !hook_ran;
  ignore
    (expect_exit_ok "selected observer dispose"
       (Runtime.run rt (widen (Signal.Observer.dispose selected_observer)))
      : unit)

let test_time_timer_dispose_hook_failure_still_cleans_graph () =
  let module Signal = Eta_signal_testable.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    run_ok rt
      (Signal.Observer.observe_with_hooks
         ~on_finish:[ (fun _ -> failwith "dispose hook failure") ]
         signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  expect_finalizer_die "dispose hook failure" "dispose hook failure"
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer)));
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.drain rt)
  in
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "failing dispose hook did not skip timer cleanup" true
    (Eio.Promise.is_resolved drained);
  Eio.Promise.await_exn drained

let test_time_invalidated_timer_cancels_sleeping_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let use_timer = Signal.Var.create true in
  let created_timers = ref 0 in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then (
          incr created_timers;
          run_ok rt (Signal.Time.interval (Duration.days 1)))
        else Signal.const 0)
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  Alcotest.(check int) "dynamic timer created once" 1 !created_timers;
  run_ok rt (Signal.Var.set use_timer false);
  run_ok rt Signal.stabilize;
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
  run_ok rt (Signal.Observer.dispose observer)

let test_time_timer_dispose_during_step_prevents_update () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let observer_ref = ref None in
  let disposed_during_step = ref false in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 (fun ~missed:_ value ->
           if not !disposed_during_step then (
             disposed_during_step := true;
             Option.iter
               (fun observer -> run_ok rt (Signal.Observer.dispose observer))
               !observer_ref);
           value + 1))
  in
  let first_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  observer_ref := Some first_observer;
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial step value" 0
    (run_ok rt (Signal.Observer.read first_observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check bool) "step disposed observer" true !disposed_during_step;
  let second_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "unnecessary timer step did not update source" 0
    (run_ok rt (Signal.Observer.read second_observer));
  run_ok rt (Signal.Observer.dispose second_observer)

let test_time_interval_restarts_after_reobserve () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let first_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt (Signal.Observer.dispose first_observer);
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "disposed timer stopped" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let second_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reobserved initial tick" 0
    (run_ok rt (Signal.Observer.read second_observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reobserved timer ticked" 1
    (run_ok rt (Signal.Observer.read second_observer));
  run_ok rt (Signal.Observer.dispose second_observer)

let test_time_interval_reobserve_ignores_stale_sleep () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let first_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Observer.dispose first_observer);
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  let second_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reobserved interval starts from cached value" 0
    (run_ok rt (Signal.Observer.read second_observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "old half-elapsed sleep does not tick reobserve" 0
    (run_ok rt (Signal.Observer.read second_observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "fresh reobserve sleep ticks after full interval" 1
    (run_ok rt (Signal.Observer.read second_observer));
  run_ok rt (Signal.Observer.dispose second_observer)

let test_time_timer_becomes_inert_after_bind_switch () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_time_branch_churn_keeps_single_active_sleeper () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create false in
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then timer else Signal.const (-1))
  in
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "inactive timer has no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  for i = 1 to 4 do
    run_ok rt (Signal.Var.set use_timer true);
    run_ok rt Signal.stabilize;
    wait_for_sleepers clock 1;
    Alcotest.(check int)
      (Printf.sprintf "active branch %d has one sleeper" i)
      1
      (Eta_test.Test_clock.sleeper_count clock);
    run_ok rt (Signal.Var.set use_timer false);
    run_ok rt Signal.stabilize;
    Eta_test.Test_clock.adjust clock (Duration.ms 10);
    Eta_test.Async.yield ();
    Alcotest.(check int)
      (Printf.sprintf "inactive branch %d has no sleeper" i)
      0
      (Eta_test.Test_clock.sleeper_count clock)
  done;
  run_ok rt (Signal.Observer.dispose observer)

let test_time_now_bind_activation_refreshes_current_stabilization () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create false in
  let now_signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ())
    |> Signal.map Signal.Time.to_ms
  in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then now_signal else Signal.const (-1))
  in
  Eta_test.Test_clock.adjust clock (Duration.ms 20);
  Eta_test.Async.yield ();
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok rt (Signal.Observer.dispose observer))
    (fun () ->
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "inactive branch value" (-1)
        (run_ok rt (Signal.Observer.read observer));
      run_ok rt (Signal.Var.set use_timer true);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "dynamic activation refreshes current snapshot" 20
        (run_ok rt (Signal.Observer.read observer)))

let test_time_now_uses_runtime_clock () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ())
    |> Signal.map Signal.Time.to_ms
  in
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

let test_time_now_uses_single_clock_snapshot_per_stabilization () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let current_now_ms = ref 0 in
  let now_ms () =
    let current = !current_now_ms in
    incr current_now_ms;
    current
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let left =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ())
    |> Signal.map Signal.Time.to_ms
  in
  let right =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ())
    |> Signal.map Signal.Time.to_ms
  in
  let pair = Signal.map2 (fun left right -> (left, right)) left right in
  let observer =
    run_ok rt (Signal.Observer.observe pair (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok rt (Signal.Observer.dispose observer))
    (fun () ->
      run_ok rt Signal.stabilize;
      let left, right = run_ok rt (Signal.Observer.read observer) in
      Alcotest.(check int) "same stabilization clock snapshot" left right)

let test_time_now_backward_clock_refresh_overrides_pending_update () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ())
    |> Signal.map Signal.Time.to_ms
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial now" 0
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 10;
  wait_for_sleepers clock 1;
  Eta_test.Test_clock.set_time clock 0;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "backward refresh wins over pending update" 0
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_now_reobserve_refreshes_while_old_sleep_pending () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ())
    |> Signal.map Signal.Time.to_ms
  in
  let first_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial now" 0
    (run_ok rt (Signal.Observer.read first_observer));
  run_ok rt (Signal.Observer.dispose first_observer);
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  let second_observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reobserved now refreshes immediately" 5
    (run_ok rt (Signal.Observer.read second_observer));
  run_ok rt (Signal.Observer.dispose second_observer)

let test_time_now_refreshes_after_idle_observe () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ())
    |> Signal.map Signal.Time.to_ms
  in
  Eta_test.Test_clock.adjust clock (Duration.ms 20);
  Eta_test.Async.yield ();
  Alcotest.(check int) "unobserved now has no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "idle now refreshes on observe" 20
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_after_deadline () =
  let module Signal = Eta_signal.Make (Observer_error) () in
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

let test_time_after_positive_duration_tolerates_advancing_clock () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let current_now_ms = ref 0 in
  let now_ms () =
    let current = !current_now_ms in
    incr current_now_ms;
    current
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~now_ms ()
  in
  ignore
    (run_ok rt
       (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms 1)))

let test_time_after_elapsed_before_observe () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt
      (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  Alcotest.(check int) "unobserved deadline has no sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "elapsed deadline refreshes on observe" true
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_after_bind_activation_refreshes_current_stabilization () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create false in
  let deadline =
    run_ok rt
      (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then deadline else Signal.const false)
  in
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok rt (Signal.Observer.dispose observer))
    (fun () ->
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "inactive branch value" false
        (run_ok rt (Signal.Observer.read observer));
      run_ok rt (Signal.Var.set use_timer true);
      run_ok rt Signal.stabilize;
      Alcotest.(check bool)
        "dynamic activation refreshes elapsed deadline" true
        (run_ok rt (Signal.Observer.read observer)))

let test_time_after_bind_activation_does_not_compute_stale_deadline () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create false in
  let deadline =
    run_ok rt
      (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  let selected =
    Signal.bind (Signal.Var.watch use_timer) (fun use_timer ->
        if use_timer then
          Signal.map
            (fun due ->
              if due then "elapsed"
              else failwith "stale deadline reached user code")
            deadline
        else Signal.const "inactive")
  in
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  Eta_test.Async.yield ();
  let observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok rt (Signal.Observer.dispose observer))
    (fun () ->
      run_ok rt Signal.stabilize;
      Alcotest.(check string) "inactive branch value" "inactive"
        (run_ok rt (Signal.Observer.read observer));
      run_ok rt (Signal.Var.set use_timer true);
      run_ok rt Signal.stabilize;
      Alcotest.(check string)
        "dynamic activation computes only refreshed deadline" "elapsed"
        (run_ok rt (Signal.Observer.read observer)))

let test_time_after_overflow_fails_with_deadline_overflow () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  Eta_test.Test_clock.set_time clock (max_int - 1);
  expect_fail "overflowing relative deadline" (( = ) `Deadline_overflow)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms 10))))

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
    run_ok rt (Signal.Time.after ~every:(Duration.ms 10) (Duration.ms 100))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "deadline daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "before deadline" false
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 150;
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "after deadline" true
        (run_ok rt (Signal.Observer.read observer)))

let test_time_interval_catches_up_arithmetically_without_daemon_yield () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "initial" 0
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 55;
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "5 missed cadences" 5
        (run_ok rt (Signal.Observer.read observer)))

let test_time_interval_does_not_recount_saturated_due () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  now_ms := max_int - 1;
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 1)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "initial interval" 0
        (run_ok rt (Signal.Observer.read observer));
      now_ms := max_int;
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "saturated due counted once" 1
        (run_ok rt (Signal.Observer.read observer));
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "saturated due is not recounted" 1
        (run_ok rt (Signal.Observer.read observer)))

let test_time_deadline_refresh_retries_after_downstream_defect () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let deadline =
    run_ok rt (Signal.Time.after ~every:(Duration.ms 10) (Duration.ms 100))
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
    run_ok rt (Signal.Observer.observe checked (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "deadline daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "before deadline" false
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 150;
      expect_die "deadline refresh rollback"
        (Eta_eio.Runtime.run rt (widen Signal.stabilize));
      Alcotest.(check bool) "rolled back deadline snapshot" false
        (run_ok rt (Signal.Observer.read observer));
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "deadline refresh retried" true
        (run_ok rt (Signal.Observer.read observer)))

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
    run_ok rt (Signal.Observer.observe checked (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "interval daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "initial" 0
        (run_ok rt (Signal.Observer.read observer));
      let before_failure_stats = run_ok rt (Signal.stats ()) in
      now_ms := 55;
      expect_die "interval refresh rollback"
        (Eta_eio.Runtime.run rt (widen Signal.stabilize));
      Alcotest.(check int) "rolled back interval snapshot" 0
        (run_ok rt (Signal.Observer.read observer));
      Alcotest.(check int)
        "rolled back interval refresh dirty flags"
        before_failure_stats.Signal.live_dirty_node_count
        (run_ok rt (Signal.stats ())).Signal.live_dirty_node_count;
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "interval refresh retried" 5
        (run_ok rt (Signal.Observer.read observer)))

let test_time_active_deadline_refreshes_before_daemon_runs () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal =
    run_ok rt (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "active deadline daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check bool) "initial active deadline" false
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 10;
      run_ok rt Signal.stabilize;
      Alcotest.(check bool)
        "active deadline refreshes during stabilization before daemon resumes"
        true
        (run_ok rt (Signal.Observer.read observer)))

let test_time_deadline_on_demand_finish_cancels_running_daemon () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal =
    run_ok rt (Signal.Time.after ~every:(Duration.days 1) (Duration.ms 5))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "initial deadline" false
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "deadline finished by on-demand refresh" true
    (run_ok rt (Signal.Observer.read observer));
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
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.(check bool)
    "on-demand deadline finish cancels sleeping daemon" true
    drained_without_clock_advance

let test_time_active_interval_refreshes_before_daemon_runs () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 5)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "active interval daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "initial active interval" 0
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 20;
      run_ok rt Signal.stabilize;
      Alcotest.(check int)
        "active interval catches up during stabilization before daemon resumes"
        4
        (run_ok rt (Signal.Observer.read observer)))

let test_time_step_does_not_catch_up_without_daemon_progress () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let interval = run_ok rt (Signal.Time.interval (Duration.ms 5)) in
  let step =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 5) ~initial:1
         (fun ~missed value -> value + missed))
  in
  let signal =
    Signal.map2 (fun interval step -> (interval, step)) interval step
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "active interval and step daemons are sleeping" (fun () ->
          !sleep_calls >= 2);
      run_ok rt Signal.stabilize;
      Alcotest.(check (pair int int)) "initial interval and step" (0, 1)
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 20;
      run_ok rt Signal.stabilize;
      Alcotest.(check (pair int int))
        "interval catches up but step waits for daemon progress" (4, 1)
        (run_ok rt (Signal.Observer.read observer)))

let test_time_step_replay_does_not_catch_up_without_daemon_progress () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let interval = run_ok rt (Signal.Time.interval (Duration.ms 5)) in
  let step =
    run_ok rt (Signal.Time.step_replay ~every:(Duration.ms 5) ~initial:1 succ)
  in
  let signal =
    Signal.map2 (fun interval step -> (interval, step)) interval step
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "active interval and step_replay daemons are sleeping"
        (fun () -> !sleep_calls >= 2);
      run_ok rt Signal.stabilize;
      Alcotest.(check (pair int int))
        "initial interval and step_replay" (0, 1)
        (run_ok rt (Signal.Observer.read observer));
      now_ms := 20;
      run_ok rt Signal.stabilize;
      Alcotest.(check (pair int int))
        "interval catches up but step_replay waits for daemon progress"
        (4, 1)
        (run_ok rt (Signal.Observer.read observer)))

let test_time_step_does_not_run_f_inside_stabilize () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_blocked_timer_daemon @@ fun rt now_ms sleep_calls ->
  let f_called = ref 0 in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 (fun ~missed:_ x ->
           incr f_called;
           if !f_called >= 0 then failwith "step f ran during stabilize"
           else x + 1))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "step daemon is sleeping" (fun () -> !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      now_ms := 20;
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "f not called by stabilize" 0 !f_called)

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
    run_ok rt (Signal.Time.after ~every:(Duration.ms 5) (Duration.ms 10))
  in
  let combined =
    Signal.map2 (fun value due -> if due then value else 0) mapped deadline
  in
  let observer =
    run_ok rt (Signal.Observer.observe combined (fun _ -> Effect.unit))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer))))
    (fun () ->
      wait_until "active deadline daemon is sleeping" (fun () ->
          !sleep_calls >= 1);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "initial combined value" 0
        (run_ok rt (Signal.Observer.read observer));
      pure_runs := 0;
      now_ms := 10;
      run_ok rt (Signal.Var.set source 2);
      run_ok rt Signal.stabilize;
      Alcotest.(check int) "refreshed combined value" 2
        (run_ok rt (Signal.Observer.read observer));
      Alcotest.(check int) "pre-timer pure closure ran once" 1 !pure_runs)

let test_time_step_function () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 5) ~initial:1
         (fun ~missed:_ n -> n * 2))
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

let test_time_step_defect_logs_daemon_diagnostic_and_restarts () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_logger_test_clock @@ fun _sw clock rt logger ->
  let fail = ref true in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 5) ~initial:1 (fun ~missed:_ n ->
           if !fail then (
             fail := false;
             failwith "time step defect");
           n + 1))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial step value" 1
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  Eta_eio.Runtime.drain rt;
  (match Logger.dump logger with
   | [ record ] ->
       Alcotest.(check bool) "diagnostic level" true
         (record.level = Logger.Error);
       Alcotest.(check string) "diagnostic body" "eta.daemon.failure"
         record.body;
       Alcotest.(check (option string))
         "step diagnostic span" (Some "eta_signal.time.step")
         (List.assoc_opt "eta.die.span_name" record.attrs);
       Alcotest.(check (option string))
         "step diagnostic annotation" (Some "step")
         (List.assoc_opt "eta.annotation.eta_signal.timer.kind" record.attrs);
       Alcotest.(check (option string))
         "step exception message" (Some "Failure(\"time step defect\")")
         (List.assoc_opt "exception.message" record.attrs)
   | records ->
       Alcotest.failf "expected one step daemon diagnostic, got %d"
         (List.length records));
  run_ok rt Signal.stabilize;
  wait_for_sleepers clock 1;
  Eta_test.Test_clock.adjust clock (Duration.ms 5);
  Eta_test.Async.yield ();
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "timer restarts after step defect" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_invalid_intervals_fail_cleanly () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let now_signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 1) ()) in
  let now_observer =
    run_ok rt (Signal.Observer.observe now_signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let future_deadline =
    match
      Signal.Time.add
        (run_ok rt (Signal.Observer.read now_observer))
        (Duration.ms 1)
    with
    | Ok timestamp -> timestamp
    | Error _ -> Alcotest.fail "expected future monotonic timestamp"
  in
  run_ok rt (Signal.Observer.dispose now_observer);
  expect_fail "invalid now cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.now ~every:Duration.zero ())));
  expect_fail "invalid deadline cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.deadline ~every:Duration.zero future_deadline)));
  expect_fail "invalid interval" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.interval Duration.zero)));
  expect_fail "invalid step cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen
          (Signal.Time.step ~every:Duration.zero ~initial:0
             (fun ~missed value -> value + missed))))

let test_time_deadline_validation_errors () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let now_signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 1) ()) in
  let now_observer =
    run_ok rt (Signal.Observer.observe now_signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let now = run_ok rt (Signal.Observer.read now_observer) in
  run_ok rt (Signal.Observer.dispose now_observer);
  expect_fail "invalid after interval" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:Duration.zero (Duration.ms 1))));
  expect_fail "past after duration" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) Duration.zero)));
  expect_fail "clamped past after duration" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms (-1)))));
  expect_fail "past deadline" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.deadline ~every:(Duration.ms 1) now)))

let with_yield_after_daemon_fork_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let daemon_forked, daemon_forked_resolver = Eio.Promise.create () in
  let daemon_forked_once = ref false in
  let module Eio_ops = struct
    module Time = Eio.Time
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
        Eio.Fiber.fork_daemon ~sw f;
        if not !daemon_forked_once then (
          daemon_forked_once := true;
          Eio.Promise.resolve daemon_forked_resolver ();
          Eio.Fiber.yield ())

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
  f sw rt daemon_forked

let test_stream_observe_timer_initialization_race () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_yield_after_daemon_fork_runtime @@ fun sw rt daemon_forked ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let stabilize =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Promise.await daemon_forked;
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  let observe =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen (Signal.Stream.observe signal)))
  in
  let observer, stream =
    expect_exit_ok "stream observe race registration"
      (Eio.Promise.await_exn observe)
  in
  expect_exit_ok "stream observe race stabilize"
    (Eio.Promise.await_exn stabilize);
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 0 ] -> ()
   | _ -> Alcotest.fail "expected initialized stream update");
  run_ok rt (Signal.Observer.dispose observer)

let test_observe_invalidated_before_return_fails () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_yield_after_daemon_fork_runtime @@ fun sw rt daemon_forked ->
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let use_branch = Signal.Var.create true in
  let captured = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_branch) (fun active ->
        if active then (
          let branch = Signal.map Fun.id timer in
          captured := Some branch;
          Signal.const 0)
        else Signal.const 1)
  in
  let selected_observer =
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let branch =
    match !captured with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch signal"
  in
  let switch_branch =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Promise.await daemon_forked;
        Eta_eio.Runtime.run rt
          (widen
             (Signal.Var.set use_branch false
              |> Effect.bind (fun () -> Signal.stabilize))))
  in
  let observe_branch =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen (Signal.Observer.observe branch (fun _ -> Effect.unit))))
  in
  ignore (expect_exit_ok "branch switch" (Eio.Promise.await_exn switch_branch) : unit);
  expect_fail "observe invalidated before return" (( = ) `Invalid_scope)
    (Eio.Promise.await_exn observe_branch);
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_registering_timer_demand_does_not_restart_active_pure_closures () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_yield_after_daemon_fork_runtime @@ fun sw rt daemon_forked ->
  let timer = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let source = Signal.Var.create 0 in
  let pure_runs = ref 0 in
  let mapped =
    Signal.map
      (fun value ->
        incr pure_runs;
        value)
      (Signal.Var.watch source)
  in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  pure_runs := 0;
  run_ok rt (Signal.Var.set source 1);
  let observe_timer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen (Signal.Observer.observe timer (fun _ -> Effect.unit))))
  in
  let stabilize =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Promise.await daemon_forked;
        Eta_eio.Runtime.run rt (widen Signal.stabilize))
  in
  let timer_observer =
    expect_exit_ok "registering timer observer"
      (Eio.Promise.await_exn observe_timer)
  in
  expect_exit_ok "stabilize while timer observer registers"
    (Eio.Promise.await_exn stabilize);
  Alcotest.(check int) "active pure closure ran once" 1 !pure_runs;
  Alcotest.(check int) "active observer updated" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose timer_observer);
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_bridge_interrupted_publish_does_not_duplicate () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let arm_interrupt = ref false in
  let marker =
    expect_exit_ok "marker observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe signal (fun _update ->
                 Effect.sync (fun () ->
                     if !arm_interrupt then
                       (* From this marker callback, the marker ack, stream
                          observer active check, and stream delivery claim enter
                          the lane before the stream delivery ack. *)
                       Cleanup_interrupt_runtime.interrupt_on_local_binding_count
                       := Some
                            (!Cleanup_interrupt_runtime.local_binding_count + 4))))))
  in
  let observer, stream =
    expect_exit_ok "stream observer registration"
      (Runtime.run rt (widen (Signal.Stream.observe signal)))
  in
  Cleanup_interrupt_runtime.local_binding_count := 0;
  arm_interrupt := true;
  (match Runtime.run rt (widen Signal.stabilize) with
  | exception Cleanup_interrupt -> ()
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected observer acknowledgement interrupt");
  arm_interrupt := false;
  ignore
    (expect_exit_ok "retry stabilize"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  ignore
    (expect_exit_ok "stream observer dispose"
       (Runtime.run rt (widen (Signal.Observer.dispose observer)))
      : unit);
  ignore
    (expect_exit_ok "marker observer dispose"
       (Runtime.run rt (widen (Signal.Observer.dispose marker)))
      : unit);
  (match
     expect_exit_ok "stream collect after interrupted publish"
       (Runtime.run rt
          (widen (Eta_stream.Stream.take 2 stream |> Eta_stream.run_collect)))
   with
   | [ Signal.Initialized 1 ] -> ()
   | [ Signal.Initialized 1; Signal.Initialized 1 ] ->
       Alcotest.fail "interrupted stream publish was delivered twice"
   | _ -> Alcotest.fail "expected one initialized stream update")

let test_stream_bridge_waiting_consumer_gets_reserved_sent_update_once () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let stream_consumer_waiting = ref false in
  let waiting, waiting_resolver = Eio.Promise.create () in
  let module Base =
    (val Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock env)
       : Runtime_contract.RUNTIME)
  in
  let module Hooked_runtime = struct
    include Base

    let now_ms () = Eta_test.Test_clock.now_ms clock
    let sleep duration = Eta_test.Test_clock.sleep clock duration

    let await_promise promise =
      if not !stream_consumer_waiting then (
        stream_consumer_waiting := true;
        Eio.Promise.resolve waiting_resolver ());
      Base.await_promise promise
  end in
  let rt =
    Runtime.create_with_runtime
      (module Hooked_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    expect_exit_ok "stream observer registration"
      (Runtime.run rt (widen (Signal.Stream.observe signal)))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose observer)) : _ Exit.t))
    (fun () ->
      let consumer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt
              (widen
                 (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
      in
      Eio.Promise.await waiting;
      expect_exit_ok "stabilize reserved stream send"
        (Runtime.run rt (widen Signal.stabilize));
      (match
         expect_exit_ok "waiting stream consumer"
           (Eio.Promise.await_exn consumer)
       with
       | [ Signal.Initialized 1 ] -> ()
       | _ -> Alcotest.fail "expected one initialized stream update");
      expect_exit_ok "retry stabilize"
        (Runtime.run rt (widen Signal.stabilize));
      expect_exit_ok "stream observer dispose"
        (Runtime.run rt (widen (Signal.Observer.dispose observer)));
      match
        expect_exit_ok "stream collect after reserved send"
          (Runtime.run rt
             (widen (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
      with
      | [] -> ()
      | [ Signal.Initialized 1 ] ->
          Alcotest.fail "reserved stream send was delivered twice"
      | _ -> Alcotest.fail "expected no buffered duplicate stream update")

let test_stream_bridge_consumer_wakeup_failure_does_not_fail_stabilize () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let fail_next_resolve = ref false in
  let resolve_failures = ref 0 in
  let stream_consumer_waiting = ref false in
  let waiting, waiting_resolver = Eio.Promise.create () in
  let module Base =
    (val Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock env)
       : Runtime_contract.RUNTIME)
  in
  let module Hooked_runtime = struct
    type scope = Base.scope
    type cancel_context = Base.cancel_context
    type 'a promise = 'a Base.promise
    type 'a resolver = 'a Base.resolver
    type 'a stream = 'a Base.stream

    let root_scope = Base.root_scope
    let now_ms () = Eta_test.Test_clock.now_ms clock
    let sleep duration = Eta_test.Test_clock.sleep clock duration
    let protect = Base.protect
    let run_scope = Base.run_scope
    let fail_scope = Base.fail_scope
    let fork = Base.fork
    let fork_daemon = Base.fork_daemon
    let await_cancel = Base.await_cancel
    let yield = Base.yield
    let check = Base.check
    let create_promise = Base.create_promise

    let resolve_promise resolver value =
      if !fail_next_resolve then (
        fail_next_resolve := false;
        incr resolve_failures;
        raise Cleanup_interrupt);
      Base.resolve_promise resolver value

    let await_promise promise =
      if not !stream_consumer_waiting then (
        stream_consumer_waiting := true;
        Eio.Promise.resolve waiting_resolver ());
      Base.await_promise promise

    let create_stream = Base.create_stream
    let stream_add = Base.stream_add
    let stream_take = Base.stream_take
    let stream_take_nonblocking = Base.stream_take_nonblocking
    let with_worker_context = Base.with_worker_context
    let in_worker_context = Base.in_worker_context

    let cancellation_reason = function
      | Cleanup_interrupt -> Some Cleanup_interrupt
      | exn -> Base.cancellation_reason exn

    let multiple_exceptions = Base.multiple_exceptions
    let cancel_sub = Base.cancel_sub
    let cancel = Base.cancel
    let local_get = Base.local_get
    let local_with_binding = Base.local_with_binding
    let current_fiber_id = Base.current_fiber_id
    let with_fiber_identity = Base.with_fiber_identity
  end in
  let rt =
    Runtime.create_with_runtime
      (module Hooked_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    expect_exit_ok "stream observer registration"
      (Runtime.run rt (widen (Signal.Stream.observe ~capacity:16 signal)))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Runtime.run rt (widen (Signal.Observer.dispose observer)) : _ Exit.t))
    (fun () ->
      let consumer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt
              (widen
                 (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
      in
      Eio.Promise.await waiting;
      fail_next_resolve := true;
      expect_exit_ok "stabilize after stream consumer wakeup failure"
        (Runtime.run rt (widen Signal.stabilize));
      Alcotest.(check int) "consumer wakeup failure injected" 1
        !resolve_failures;
      (match
         expect_exit_ok "stream consumer received published update"
           (Eio.Promise.await_exn consumer)
       with
       | [ Signal.Initialized 0 ] -> ()
       | _ -> Alcotest.fail "expected initialized stream update"))

let test_stream_bridge_interrupted_drop_callback_does_not_duplicate () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.interrupt_on_local_binding_count := None;
  Cleanup_interrupt_runtime.now := 0;
  Cleanup_interrupt_runtime.local_binding_count := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let drops = ref [] in
  let interrupt_first_drop = ref true in
  let before = expect_exit_ok "stats before drop retry"
      (Runtime.run rt (widen (Signal.stats ())))
  in
  let observer, stream =
    expect_exit_ok "stream observer registration"
      (Runtime.run rt
         (widen
            (Signal.Stream.observe ~capacity:1
               ~on_drop:(fun update ->
                 drops := update :: !drops;
                 if !interrupt_first_drop then (
                   interrupt_first_drop := false;
                   Cleanup_interrupt_runtime.interrupt_on_local_binding_count :=
                     Some
                       (!Cleanup_interrupt_runtime.local_binding_count + 1)))
               signal)))
  in
  ignore
    (expect_exit_ok "initial stabilize"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  ignore
    (expect_exit_ok "set source"
       (Runtime.run rt (widen (Signal.Var.set source 2)))
      : unit);
  (match Runtime.run rt (widen Signal.stabilize) with
  | exception Cleanup_interrupt -> ()
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected drop acknowledgement interrupt");
  ignore
    (expect_exit_ok "retry dropped update"
       (Runtime.run rt (widen Signal.stabilize))
      : unit);
  (match List.rev !drops with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | [ Signal.Changed { old_value = 1; new_value = 2 }; Signal.Changed _ ] ->
       Alcotest.fail "interrupted drop callback ran twice for one update"
   | _ -> Alcotest.fail "expected one dropped changed update");
  let after_retry =
    expect_exit_ok "stats after drop retry"
      (Runtime.run rt (widen (Signal.stats ())))
  in
  Alcotest.(check int) "retried drop counts once"
    (before.Signal.stream_bridge_drop_count + 1)
    after_retry.Signal.stream_bridge_drop_count;
  ignore
    (expect_exit_ok "stream observer dispose"
       (Runtime.run rt (widen (Signal.Observer.dispose observer)))
      : unit);
  (match
     expect_exit_ok "stream collect after interrupted drop"
       (Runtime.run rt
          (widen (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected buffered initialized stream update")

let test_stream_bridge_full_queue_failure_releases_phase () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let bridge_observer, stream =
    run_ok rt (Signal.Stream.observe ~capacity:1 signal)
  in
  let fail_next = ref false in
  let failing_observer =
    run_ok rt
      (Signal.Observer.observe signal (function
        | Signal.Changed _ when !fail_next -> Effect.fail `Observer_failed
        | _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  fail_next := true;
  run_ok rt (Signal.Var.set source 2);
  expect_fail "full bridge then observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "bridge snapshot published before failure" 2
    (run_ok rt (Signal.Observer.read bridge_observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update after dropped change");
  fail_next := false;
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "graph phase released after observer failure" 3
    (run_ok rt (Signal.Observer.read bridge_observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected later stream update after failure");
  run_ok rt (Signal.Observer.dispose bridge_observer);
  run_ok rt (Signal.Observer.dispose failing_observer)

let test_stream_bridge_dispose_during_observer_phase_is_deterministic () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let bridge_observer, stream = run_ok rt (Signal.Stream.observe signal) in
  let dispose_bridge = ref false in
  let disposer =
    run_ok rt
      (Signal.Observer.observe signal (function
        | Signal.Changed _ when !dispose_bridge ->
            Signal.Observer.dispose bridge_observer
            |> Effect.or_die (fun err -> Signal.Graph_error err)
        | _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update");
  dispose_bridge := true;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  expect_fail "bridge disposed during observer phase"
    (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read bridge_observer)));
  (match run_ok rt (Eta_stream.run_collect stream) with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ ->
       Alcotest.fail
         "expected changed stream update to drain before deterministic close");
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "disposer observer remains alive after bridge disposal" 3
    (run_ok rt (Signal.Observer.read disposer));
  run_ok rt (Signal.Observer.dispose disposer)

let () =
  Alcotest.run "eta_signal"
    [
      ( "core",
        [
          Alcotest.test_case "unnecessary root nodes are gc reclaimable" `Quick
            test_unnecessary_root_nodes_are_gc_reclaimable;
          Alcotest.test_case "functor instances stabilize independently" `Quick
            test_functor_instances_stabilize_independently;
          Alcotest.test_case "recompute order is topological" `Quick
            test_recompute_order_is_topological;
          Alcotest.test_case "observer callbacks run in registration order"
            `Quick
            test_observer_callbacks_run_in_registration_order;
          Alcotest.test_case "observer ordering across graph branches" `Quick
            test_observer_ordering_across_graph_branches_is_deterministic;
          Alcotest.test_case
            "observer independent branch order ignores registration" `Quick
            test_observer_independent_branch_order_ignores_registration_permutation;
          Alcotest.test_case
            "observer graph order precedes reverse registration fail-fast"
            `Quick
            test_observer_graph_order_precedes_reverse_registration_fail_fast;
          Alcotest.test_case
            "observer graph order uses staged bind switch" `Quick
            test_observer_graph_order_after_bind_switch_uses_new_inner;
          Alcotest.test_case "observer dispose skips collected event" `Quick
            test_observer_dispose_during_callback_skips_collected_event;
          Alcotest.test_case "observer dispose after active check skips callback"
            `Quick test_observer_dispose_after_active_check_skips_callback;
          Alcotest.test_case "observer dispose after claim skips callback" `Quick
            test_observer_dispose_after_delivery_claim_skips_callback;
          Alcotest.test_case "observer registration skips callbacks until returned"
            `Quick test_observer_registration_skips_callbacks_until_returned;
          Alcotest.test_case
            "observer activation waits for transfer before callbacks" `Quick
            test_observer_activation_waits_for_transfer_before_callbacks;
          Alcotest.test_case
            "observer interrupted activation disposes unowned observer" `Quick
            test_observer_activation_interruption_disposes_unowned_observer;
          Alcotest.test_case
            "observer activation abort cleanup preserves original failure"
            `Quick
            test_observer_activation_abort_cleanup_does_not_mask_failure;
          Alcotest.test_case
            "observer observe invalidated before transfer fails" `Quick
            test_observer_observe_invalidated_before_transfer_fails;
          Alcotest.test_case
            "bind switches after unnecessary source change" `Quick
            test_bind_switches_after_unnecessary_source_change;
          Alcotest.test_case "bind invalidates old scope" `Quick
            test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes;
          Alcotest.test_case "invalidated bind rhs cannot be observed" `Quick
            test_invalidated_bind_rhs_cannot_be_observed;
          Alcotest.test_case "invalidated bind rhs cannot be wrapped" `Quick
            test_invalidated_bind_rhs_cannot_be_wrapped;
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
          Alcotest.test_case "bind switch invalidates external branch dependents"
            `Quick test_bind_switch_invalidates_external_derived_branch_dependents;
          Alcotest.test_case "bind switch invalidates branch observers" `Quick
            test_bind_switch_invalidates_observers_of_invalidated_scope;
          Alcotest.test_case "bind switch skips stale branch observer" `Quick
            test_bind_switch_skips_stale_branch_observer_before_invalidation;
          Alcotest.test_case
            "old branch observer not computed on same stabilization switch"
            `Quick test_old_branch_observer_not_computed_on_switch;
          Alcotest.test_case "dynamic scope invalidation skips callback" `Quick
            test_dynamic_scope_invalidation_skips_callback;
          Alcotest.test_case "commit skips invalidated staged entries" `Quick
            test_commit_skips_invalidated_staged_entries;
          Alcotest.test_case "dynamic signal rewires and cycle" `Quick
            test_dynamic_signal_rewires_and_cycle_preserves_snapshot;
          Alcotest.test_case "dynamic list bind switches dependency set" `Quick
            test_dynamic_list_bind_switches_dependency_set;
          Alcotest.test_case "bind branch churn releases inactive scopes" `Quick
            test_bind_branch_churn_releases_inactive_scopes;
          Alcotest.test_case "bind selector failure preserves branch" `Quick
            test_bind_selector_failure_preserves_previous_branch;
          Alcotest.test_case "bind switch rollback preserves old branch" `Quick
            test_bind_switch_is_not_committed_when_later_pure_node_fails;
          Alcotest.test_case "bind cycle detection typed failure" `Quick
            test_bind_cycle_detection_is_typed_failure;
          Alcotest.test_case "observer phase multiple sets publish final value"
            `Quick test_observer_phase_multiple_sets_publish_final_next_value;
          Alcotest.test_case "dispose unlinks observer from graph" `Quick
            test_dispose_unlinks_observer_from_graph;
          Alcotest.test_case "version overflow does not publish snapshot" `Quick
            test_signal_version_overflow_does_not_publish_partial_snapshot;
          Alcotest.test_case "var create counter overflow raises graph error"
            `Quick test_var_create_counter_overflow_raises_graph_error;
          Alcotest.test_case "stabilization generation overflow typed failure"
            `Quick test_stabilization_generation_overflow_is_typed_failure;
          Alcotest.test_case "timer refresh token overflow typed failure" `Quick
            test_timer_refresh_token_overflow_is_typed_failure;
          Alcotest.test_case "stats counter saturation is typed failure" `Quick
            test_stats_counter_saturation_is_typed_failure;
          Alcotest.test_case "observer lifecycle changes inside callback"
            `Quick test_observer_registration_and_self_disposal_inside_callback;
          Alcotest.test_case "observer effects survive later failure" `Quick
            test_observer_effects_before_later_failure_are_not_rolled_back;
          Alcotest.test_case "observer construction defect does not poison"
            `Quick
            test_observer_callback_construction_defect_does_not_poison_graph;
          Alcotest.test_case "observer interruption releases phase" `Quick
            test_observer_callback_interruption_releases_phase;
          Alcotest.test_case "stream observe failure during timer start"
            `Quick
            test_stream_observe_failure_during_timer_start_does_not_leak;
          Alcotest.test_case "time timer start failure retries necessary timer"
            `Quick test_time_timer_start_failure_retries_necessary_timer;
          Alcotest.test_case
            "time timer start failure preserves pending observer event" `Quick
            test_time_timer_start_failure_preserves_pending_observer_event;
          Alcotest.test_case "time timer start failure rolls back unstarted timers"
            `Quick test_time_timer_start_failure_rolls_back_unstarted_timers;
          Alcotest.test_case "reentrant stabilization typed failure" `Quick
            test_reentrant_stabilization_is_typed_failure;
          Alcotest.test_case "reentrant stabilization keeps outer phase" `Quick
            test_reentrant_stabilization_does_not_clear_outer_phase;
          Alcotest.test_case "effectful update reentry typed failure" `Quick
            test_effectful_update_reentry_fails_and_preserves_value;
          Alcotest.test_case "concurrent effectful update fails fast" `Quick
            test_concurrent_effectful_update_same_variable_fails_fast;
          Alcotest.test_case
            "effectful update rejects concurrent set on same variable" `Quick
            test_effectful_update_rejects_concurrent_set_same_variable;
          Alcotest.test_case "effectful update publishes once" `Quick
            test_effectful_update_success_publishes_once;
          Alcotest.test_case "effectful update sees pending source value"
            `Quick test_effectful_update_sees_pending_source_value;
          Alcotest.test_case "effectful update allows other variable mutation"
            `Quick
            test_effectful_update_allows_other_variable_mutation;
          Alcotest.test_case "effectful update failure cleanup" `Quick
            test_effectful_update_failures_preserve_value_and_release_slot;
          Alcotest.test_case "effectful update interruption cleanup" `Quick
            test_effectful_update_interruption_preserves_value_and_releases_slot;
          Alcotest.test_case "effectful update acquire interruption cleanup"
            `Quick test_effectful_update_acquire_interruption_releases_slot;
          Alcotest.test_case "queued graph operation cancellation" `Quick
            test_queued_graph_operation_cancellation_does_not_run;
          Alcotest.test_case "stats report lane waiters" `Quick
            test_stats_report_lane_waiters;
          Alcotest.test_case "active graph interruption releases lane" `Quick
            test_active_graph_operation_interruption_releases_lane;
          Alcotest.test_case
            "graph lane granted waiter survives resolver failure" `Quick
            test_graph_lane_granted_waiter_is_not_stranded_if_resolve_raises;
          Alcotest.test_case "graph lane acquisitions stay on owner domain"
            `Quick test_graph_lane_acquisition_stays_on_owner_domain;
          Alcotest.test_case "nested runtime graph read reenters graph lane"
            `Quick test_nested_runtime_graph_read_reenters_graph_lane;
          Alcotest.test_case "observer read waits for graph lane" `Quick
            test_observer_read_waits_for_graph_lane;
          Alcotest.test_case "time interval construction waits for graph lane"
            `Quick test_time_interval_construction_waits_for_graph_lane;
          Alcotest.test_case
            "observer delivery acknowledgement uses graph lane" `Quick
            test_observer_delivery_acknowledgement_uses_graph_lane;
          Alcotest.test_case "time timer generation overflow fails loudly"
            `Quick test_time_timer_generation_overflow_fails_loudly;
          Alcotest.test_case
            "time timer start overflow is precommit failure" `Quick
            test_time_timer_start_generation_overflow_is_precommit_failure;
          Alcotest.test_case "time interval catches up after late sleep" `Quick
            test_time_interval_catches_up_after_late_sleep;
          Alcotest.test_case "time interval does not recount saturated due"
            `Quick test_time_interval_does_not_recount_saturated_due;
          Alcotest.test_case "time step_replay catch-up yields between batches"
            `Quick
            test_time_step_replay_catch_up_yields_between_batches;
          Alcotest.test_case
            "time saturated step_replay catch-up yields without completion"
            `Quick
            test_time_step_replay_saturated_catch_up_yields_without_completion;
          Alcotest.test_case
            "time step saturated catch-up runs once" `Quick
            test_time_step_saturated_catch_up_runs_once;
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
          Alcotest.test_case "time timer cancel outside graph lifecycle" `Quick
            test_time_timer_cancel_runs_outside_graph_lifecycle;
          Alcotest.test_case
            "time invalidated timer cancel outside graph lifecycle" `Quick
            test_time_invalidated_timer_cancel_runs_outside_graph_lifecycle;
          Alcotest.test_case "time timer cancel failure keeps snapshot" `Quick
            test_time_timer_cancel_failure_preserves_committed_snapshot;
          Alcotest.test_case "disposal hooks continue after failure" `Quick
            test_disposal_hooks_continue_after_failure;
          Alcotest.test_case "stabilize disposal hook failure keeps snapshot"
            `Quick
            test_stabilize_disposal_hook_failure_preserves_committed_snapshot;
          Alcotest.test_case "observer dispose interruption runs finish hooks"
            `Quick test_observer_dispose_interruption_runs_finish_hooks;
          Alcotest.test_case "stabilize interruption runs invalidation hooks"
            `Quick test_stabilize_interruption_runs_invalidation_hooks;
          Alcotest.test_case "time timer dispose hook failure cleans graph"
            `Quick test_time_timer_dispose_hook_failure_still_cleans_graph;
          Alcotest.test_case "time invalidated timer cancels sleeping daemon"
            `Quick test_time_invalidated_timer_cancels_sleeping_daemon;
          Alcotest.test_case "time timer dispose during step prevents update"
            `Quick test_time_timer_dispose_during_step_prevents_update;
          Alcotest.test_case "time interval restarts after reobserve" `Quick
            test_time_interval_restarts_after_reobserve;
          Alcotest.test_case "time interval ignores stale sleep after reobserve"
            `Quick test_time_interval_reobserve_ignores_stale_sleep;
          Alcotest.test_case "time timer inert after bind switch" `Quick
            test_time_timer_becomes_inert_after_bind_switch;
          Alcotest.test_case "time branch churn keeps single sleeper" `Quick
            test_time_branch_churn_keeps_single_active_sleeper;
          Alcotest.test_case "time now bind activation refreshes current" `Quick
            test_time_now_bind_activation_refreshes_current_stabilization;
          Alcotest.test_case "time now uses runtime clock" `Quick
            test_time_now_uses_runtime_clock;
          Alcotest.test_case "time now uses one clock snapshot" `Quick
            test_time_now_uses_single_clock_snapshot_per_stabilization;
          Alcotest.test_case "time now backward refresh overrides pending update"
            `Quick
            test_time_now_backward_clock_refresh_overrides_pending_update;
          Alcotest.test_case "time now refreshes on quick reobserve" `Quick
            test_time_now_reobserve_refreshes_while_old_sleep_pending;
          Alcotest.test_case "time now refreshes after idle observe" `Quick
            test_time_now_refreshes_after_idle_observe;
          Alcotest.test_case "time after deadline" `Quick
            test_time_after_deadline;
          Alcotest.test_case "time after positive duration tolerates advancing clock"
            `Quick test_time_after_positive_duration_tolerates_advancing_clock;
          Alcotest.test_case "time after elapsed before observe" `Quick
            test_time_after_elapsed_before_observe;
          Alcotest.test_case "time after bind activation refreshes current"
            `Quick test_time_after_bind_activation_refreshes_current_stabilization;
          Alcotest.test_case "time after bind activation skips stale compute"
            `Quick
            test_time_after_bind_activation_does_not_compute_stale_deadline;
          Alcotest.test_case "time after overflow fails with Deadline_overflow"
            `Quick test_time_after_overflow_fails_with_deadline_overflow;
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
          Alcotest.test_case
            "time step does not catch up without daemon progress" `Quick
            test_time_step_does_not_catch_up_without_daemon_progress;
          Alcotest.test_case
            "time step_replay does not catch up without daemon progress"
            `Quick
            test_time_step_replay_does_not_catch_up_without_daemon_progress;
          Alcotest.test_case "time step does not run function in stabilize"
            `Quick test_time_step_does_not_run_f_inside_stabilize;
          Alcotest.test_case "time active timer refresh does not restart pure pass"
            `Quick test_time_active_timer_refresh_does_not_restart_pure_pass;
          Alcotest.test_case "time step function" `Quick
            test_time_step_function;
          Alcotest.test_case "time step defect logs diagnostic" `Quick
            test_time_step_defect_logs_daemon_diagnostic_and_restarts;
          Alcotest.test_case "time invalid intervals fail cleanly" `Quick
            test_time_invalid_intervals_fail_cleanly;
          Alcotest.test_case "time deadline validation errors" `Quick
            test_time_deadline_validation_errors;
          Alcotest.test_case "stream observe timer initialization race" `Quick
            test_stream_observe_timer_initialization_race;
          Alcotest.test_case "observe invalidated before return fails" `Quick
            test_observe_invalidated_before_return_fails;
          Alcotest.test_case
            "registering timer demand does not restart active pure closures"
            `Quick
            test_registering_timer_demand_does_not_restart_active_pure_closures;
          Alcotest.test_case "stream bridge interrupted publish does not duplicate"
            `Quick test_stream_bridge_interrupted_publish_does_not_duplicate;
          Alcotest.test_case
            "stream bridge waiting consumer gets reserved update once" `Quick
            test_stream_bridge_waiting_consumer_gets_reserved_sent_update_once;
          Alcotest.test_case
            "stream bridge consumer wakeup failure does not fail stabilize"
            `Quick
            test_stream_bridge_consumer_wakeup_failure_does_not_fail_stabilize;
          Alcotest.test_case
            "stream bridge interrupted drop callback does not duplicate" `Quick
            test_stream_bridge_interrupted_drop_callback_does_not_duplicate;
          Alcotest.test_case
            "stream bridge full queue plus observer failure releases phase"
            `Quick test_stream_bridge_full_queue_failure_releases_phase;
          Alcotest.test_case "stream bridge dispose during observer phase"
            `Quick
            test_stream_bridge_dispose_during_observer_phase_is_deterministic;
        ] );
    ]
