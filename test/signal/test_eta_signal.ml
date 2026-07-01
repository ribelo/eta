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

module Signal = Eta_signal.Make (Observer_error) ()
module Other_signal = Eta_signal.Make (Observer_error) ()
module Dot_signal = Eta_signal.Make (Observer_error) ()
module Dependency_signal = Eta_signal.Make (Observer_error) ()

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

let expect_graph_error_exn label expected f =
  match f () with
  | exception Signal.Graph_error actual when actual = expected -> ()
  | exception exn ->
      Alcotest.failf "%s: expected graph error, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected graph error" label

let signal_graph_context_message =
  "Eta_signal: signal graph APIs must be called on the domain that created "
  ^ "the graph and not from runtime worker callbacks"

let signal_test_worker_context_active = ref false

let () =
  Runtime_contract.register_worker_context_probe (fun () ->
      !signal_test_worker_context_active)

let domain_spawn f =
  (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"]) f

let run_in_domain f =
  let domain = domain_spawn f in
  Domain.join domain

let expect_cross_domain_signal_context_failure label f =
  match
    run_in_domain @@ fun () ->
    try Ok (f (); false) with
    | Invalid_argument message -> Ok (String.equal message signal_graph_context_message)
    | exn -> Error (Printexc.to_string exn)
  with
  | Ok true -> ()
  | Ok false -> Alcotest.failf "%s: expected signal graph context failure" label
  | Error actual ->
      Alcotest.failf "%s: expected signal graph context failure, got %s" label
        actual

let expect_signal_context_failure label f =
  match f () with
  | exception Invalid_argument message
    when String.equal message signal_graph_context_message ->
      ()
  | exception exn ->
      Alcotest.failf "%s: expected signal graph context failure, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected signal graph context failure" label

let with_signal_test_worker_context f =
  signal_test_worker_context_active := true;
  Fun.protect ~finally:(fun () -> signal_test_worker_context_active := false) f

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

exception Cleanup_interrupt

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

let render pp value = Format.asprintf "%a" pp value

let check_render label pp value expected =
  Alcotest.(check string) label expected (render pp value)

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
  check_render "invalid observer scope" Signal.pp_observer_read_error
    `Invalid_scope "invalid dynamic scope";
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

let test_observe_after_stabilization_and_disposal_clears_graph () =
  with_runtime @@ fun rt ->
  run_ok rt Signal.stabilize;
  let before = run_ok rt (Signal.stats ()) in
  let before_dot_nodes = count_occurrences (run_ok rt (Signal.to_dot ())) "[label=" in
  let source = Signal.Var.create 1 in
  run_ok rt (Signal.Var.set source 2);
  let signal = Signal.Var.watch source |> Signal.map (fun value -> value + 1) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let after_observe = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "observer after prior stabilization sees latest source" 3
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check bool) "observe after stabilization adds demand" true
    (after_observe.Signal.necessary_node_count
     > before.Signal.necessary_node_count);
  Alcotest.(check bool) "to_dot shows observed graph" true
    (count_occurrences (run_ok rt (Signal.to_dot ())) "[label="
     > before_dot_nodes);
  run_ok rt (Signal.Observer.dispose observer);
  run_ok rt Signal.stabilize;
  let after_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "disposal returns active observer count to baseline"
    before.Signal.active_observer_count
    after_dispose.Signal.active_observer_count;
  Alcotest.(check bool) "disposal releases necessary graph" true
    (after_dispose.Signal.necessary_node_count
     <= before.Signal.necessary_node_count);
  Alcotest.(check bool) "to_dot returns to baseline necessary graph" true
    (count_occurrences (run_ok rt (Signal.to_dot ())) "[label="
     <= before_dot_nodes)

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

let test_graph_rejects_cross_domain_synchronous_apis () =
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  expect_cross_domain_signal_context_failure "cross-domain Var.create" (fun () ->
      ignore (Signal.Var.create 0 : int Signal.Var.t));
  expect_cross_domain_signal_context_failure "cross-domain Var.value" (fun () ->
      ignore (Signal.Var.value source : int));
  expect_cross_domain_signal_context_failure "cross-domain Var.watch" (fun () ->
      ignore (Signal.Var.watch source : int Signal.signal));
  expect_cross_domain_signal_context_failure "cross-domain const" (fun () ->
      ignore (Signal.const 0 : int Signal.signal));
  expect_cross_domain_signal_context_failure "cross-domain map" (fun () ->
      ignore (Signal.map (fun value -> value + 1) signal : int Signal.signal))

let test_graph_rejects_registered_worker_context () =
  let source = Signal.Var.create 1 in
  with_signal_test_worker_context @@ fun () ->
  expect_signal_context_failure "worker-context Var.value" (fun () ->
      ignore (Signal.Var.value source : int));
  expect_signal_context_failure "worker-context const" (fun () ->
      ignore (Signal.const 0 : int Signal.signal))

let test_graph_rejects_cross_domain_effectful_apis () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  expect_die "cross-domain Var.set"
    (run_effect_in_foreign_domain (Signal.Var.set source 2));
  expect_die "cross-domain Observer.observe"
    (run_effect_in_foreign_domain
       (Signal.Observer.observe signal (fun _ -> Effect.unit)));
  expect_die "cross-domain Observer.read"
    (run_effect_in_foreign_domain (Signal.Observer.read observer));
  expect_die "cross-domain Observer.dispose"
    (run_effect_in_foreign_domain (Signal.Observer.dispose observer));
  expect_die "cross-domain stats"
    (run_effect_in_foreign_domain (Signal.stats ()));
  expect_die "cross-domain to_dot"
    (run_effect_in_foreign_domain (Signal.to_dot ()));
  expect_die "cross-domain stabilize"
    (run_effect_in_foreign_domain Signal.stabilize);
  Alcotest.(check int) "cross-domain set did not mutate source" 1
    (Signal.Var.value source);
  run_ok rt (Signal.Observer.dispose observer)

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

let test_diamond_observers_see_glitch_free_snapshots () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let shared = Signal.Var.watch source |> Signal.map (fun n -> n * 10) in
  let left = Signal.map (fun n -> n + 1) shared in
  let right = Signal.map (fun n -> n + 2) shared in
  let downstream = Signal.map2 (fun left right -> (left, right)) left right in
  let left_observer = ref None in
  let right_observer = ref None in
  let downstream_observer = ref None in
  let events = ref [] in
  let check_snapshot label expected_left expected_right expected_downstream =
    match (!left_observer, !right_observer, !downstream_observer) with
    | Some left_observer, Some right_observer, Some downstream_observer ->
        Signal.Observer.read left_observer
        |> Effect.map_error (fun _ -> `Observer_failed)
        |> Effect.bind (fun actual_left ->
               Signal.Observer.read right_observer
               |> Effect.map_error (fun _ -> `Observer_failed)
               |> Effect.bind (fun actual_right ->
                      Signal.Observer.read downstream_observer
                      |> Effect.map_error (fun _ -> `Observer_failed)
                      |> Effect.bind (fun actual_downstream ->
                             Effect.sync (fun () ->
                                 Alcotest.(check int)
                                   (label ^ " left snapshot") expected_left
                                   actual_left;
                                 Alcotest.(check int)
                                   (label ^ " right snapshot") expected_right
                                   actual_right;
                                 Alcotest.(check (pair int int))
                                   (label ^ " downstream snapshot")
                                   expected_downstream actual_downstream))))
    | _ -> Effect.unit
  in
  let left_callback = function
    | Signal.Initialized value | Changed { new_value = value; _ } ->
        Effect.sync (fun () -> events := ("left", value) :: !events)
        |> Effect.bind (fun () ->
               check_snapshot "left callback" value (value + 1)
                 (value, value + 1))
  in
  let right_callback = function
    | Signal.Initialized value | Changed { new_value = value; _ } ->
        Effect.sync (fun () -> events := ("right", value) :: !events)
        |> Effect.bind (fun () ->
               check_snapshot "right callback" (value - 1) value
                 (value - 1, value))
  in
  let downstream_callback = function
    | Signal.Initialized value | Changed { new_value = value; _ } ->
        let expected_left, expected_right = value in
        Effect.sync (fun () -> events := ("downstream", expected_left) :: !events)
        |> Effect.bind (fun () ->
               check_snapshot "downstream callback" expected_left expected_right
                 value)
  in
  let left_handle = run_ok rt (Signal.Observer.observe left left_callback) in
  let right_handle = run_ok rt (Signal.Observer.observe right right_callback) in
  let downstream_handle =
    run_ok rt (Signal.Observer.observe downstream downstream_callback)
  in
  left_observer := Some left_handle;
  right_observer := Some right_handle;
  downstream_observer := Some downstream_handle;
  run_ok rt Signal.stabilize;
  Alcotest.(check (list (pair string int)))
    "initial callbacks see complete diamond"
    [ ("left", 11); ("right", 12); ("downstream", 11) ]
    (List.rev !events);
  events := [];
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list (pair string int)))
    "changed callbacks see complete diamond"
    [ ("left", 21); ("right", 22); ("downstream", 21) ]
    (List.rev !events);
  Alcotest.(check (pair int int)) "downstream observer final snapshot" (21, 22)
    (run_ok rt (Signal.Observer.read downstream_handle));
  run_ok rt (Signal.Observer.dispose left_handle);
  run_ok rt (Signal.Observer.dispose right_handle);
  run_ok rt (Signal.Observer.dispose downstream_handle)

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

let test_map_arity_matrix_initializes_and_coalesces () =
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
  let mapped =
    [
      Signal.const 10 |> Signal.map (fun n -> n + 1);
      Signal.map (fun a -> a) s1;
      Signal.map2 (fun a b -> a + b) s1 s2;
      Signal.map3 (fun a b c -> a + b + c) s1 s2 s3;
      Signal.map4 (fun a b c d -> a + b + c + d) s1 s2 s3 s4;
      Signal.map5 (fun a b c d e -> a + b + c + d + e) s1 s2 s3 s4 s5;
      Signal.map6
        (fun a b c d e f -> a + b + c + d + e + f)
        s1 s2 s3 s4 s5 s6;
      Signal.map7
        (fun a b c d e f g -> a + b + c + d + e + f + g)
        s1 s2 s3 s4 s5 s6 s7;
      Signal.map8
        (fun a b c d e f g h -> a + b + c + d + e + f + g + h)
        s1 s2 s3 s4 s5 s6 s7 s8;
      Signal.map9
        (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
        s1 s2 s3 s4 s5 s6 s7 s8 s9;
    ]
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe (Signal.all mapped) (record_observer events))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "map arities initialize"
    [ 11; 1; 3; 6; 10; 15; 21; 28; 36; 45 ]
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set v1 100);
  run_ok rt (Signal.Var.set v1 101);
  run_ok rt (Signal.Var.set v9 90);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "map arities publish final coalesced source values"
    [ 11; 101; 103; 106; 110; 115; 121; 128; 136; 226 ]
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "one initialization and one changed event" 2
    (List.length !events);
  run_ok rt (Signal.Observer.dispose observer)

let test_map_invariants_repeated_children_cutoff_and_final_values () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let shared_calls = ref 0 in
  let shared =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr shared_calls;
           value)
  in
  let repeated_map2 = Signal.map2 ( + ) shared shared in
  let repeated_map9 =
    Signal.map9
      (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
      shared shared shared shared shared shared shared shared shared
  in
  let cutoff_source = Signal.Var.create 0 in
  let cutoff_child =
    Signal.Var.watch cutoff_source
    |> Signal.map ~equal:Int.equal (fun value -> value mod 2)
  in
  let cutoff_calls = ref 0 in
  let cutoff_map9 =
    Signal.map9
      (fun a b c d e f g h i ->
        incr cutoff_calls;
        a + b + c + d + e + f + g + h + i)
      cutoff_child cutoff_child cutoff_child cutoff_child cutoff_child
      cutoff_child cutoff_child cutoff_child cutoff_child
  in
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let map2_calls = ref 0 in
  let two_inputs =
    Signal.map2
      (fun a b ->
        incr map2_calls;
        a + b)
      (Signal.Var.watch left) (Signal.Var.watch right)
  in
  let combined =
    Signal.all [ repeated_map2; repeated_map9; cutoff_map9; two_inputs ]
  in
  let observer =
    run_ok rt (Signal.Observer.observe combined (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int)) "initial invariant values" [ 2; 9; 0; 11 ]
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "repeated child recomputed once initially" 1 !shared_calls;
  Alcotest.(check int) "map2 computed once initially" 1 !map2_calls;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt (Signal.Var.set cutoff_source 2);
  run_ok rt (Signal.Var.set left 2);
  run_ok rt (Signal.Var.set right 20);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int))
    "updated invariant values" [ 4; 18; 0; 22 ]
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "repeated child recomputed once after update" 2
    !shared_calls;
  Alcotest.(check int) "child cutoff suppressed map9 recompute" 1 !cutoff_calls;
  Alcotest.(check int) "two changed inputs recomputed once" 2 !map2_calls;
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

let test_unnecessary_derived_recomputes_after_dependency_change () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let mapped_calls = ref 0 in
  let mapped =
    Signal.map
      (fun value ->
        incr mapped_calls;
        value + 1)
      watched
  in
  let source_observer =
    run_ok rt (Signal.Observer.observe watched (fun _ -> Effect.unit))
  in
  let mapped_observer =
    run_ok rt (Signal.Observer.observe mapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial mapped value" 1
    (run_ok rt (Signal.Observer.read mapped_observer));
  Alcotest.(check int) "initial mapped recompute" 1 !mapped_calls;
  run_ok rt (Signal.Observer.dispose mapped_observer);
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "source stayed necessary" 1
    (run_ok rt (Signal.Observer.read source_observer));
  Alcotest.(check int) "unnecessary mapped not recomputed" 1 !mapped_calls;
  let reobserved =
    run_ok rt (Signal.Observer.observe mapped (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reobserved mapped value is fresh" 2
    (run_ok rt (Signal.Observer.read reobserved));
  Alcotest.(check int) "mapped recomputed on reobserve" 2 !mapped_calls;
  run_ok rt (Signal.Observer.dispose source_observer);
  run_ok rt (Signal.Observer.dispose reobserved)

let test_newly_necessary_derived_chain_refreshes_dependency_versions () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let watched = Signal.Var.watch source in
  let first_calls = ref 0 in
  let second_calls = ref 0 in
  let first =
    Signal.map
      (fun value ->
        incr first_calls;
        value + 1)
      watched
  in
  let second =
    Signal.map
      (fun value ->
        incr second_calls;
        value * 10)
      first
  in
  let source_observer =
    run_ok rt (Signal.Observer.observe watched (fun _ -> Effect.unit))
  in
  let second_observer =
    run_ok rt (Signal.Observer.observe second (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial chain value" 10
    (run_ok rt (Signal.Observer.read second_observer));
  Alcotest.(check int) "initial first recompute" 1 !first_calls;
  Alcotest.(check int) "initial second recompute" 1 !second_calls;
  run_ok rt (Signal.Observer.dispose second_observer);
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "source remained necessary" 1
    (run_ok rt (Signal.Observer.read source_observer));
  Alcotest.(check int) "unnecessary first not recomputed" 1 !first_calls;
  Alcotest.(check int) "unnecessary second not recomputed" 1 !second_calls;
  let reobserved =
    run_ok rt (Signal.Observer.observe second (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reactivated chain value is fresh" 20
    (run_ok rt (Signal.Observer.read reobserved));
  Alcotest.(check int) "first recomputed on reactivation" 2 !first_calls;
  Alcotest.(check int) "second recomputed on reactivation" 2 !second_calls;
  run_ok rt (Signal.Observer.dispose source_observer);
  run_ok rt (Signal.Observer.dispose reobserved)

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

let test_derived_default_cutoff_is_physical_equality () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let mapped = Signal.Var.watch source |> Signal.map (fun _ -> Array.make 1 1) in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (record_observer events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  (match List.rev !events with
   | [ Signal.Initialized initialized; Changed { old_value; new_value } ] ->
       Alcotest.(check (list int)) "initialized derived value" [ 1 ]
         (Array.to_list initialized);
       Alcotest.(check (list int)) "old derived value" [ 1 ]
         (Array.to_list old_value);
       Alcotest.(check (list int)) "new derived value" [ 1 ]
         (Array.to_list new_value);
       Alcotest.(check bool) "fresh equal arrays still changed" false
         (old_value == new_value)
   | _ ->
       Alcotest.fail
         "expected derived physical cutoff to emit structurally equal block");
  run_ok rt (Signal.Observer.dispose observer)

let test_structural_cutoff_suppresses_fresh_equal_derived_values () =
  with_runtime @@ fun rt ->
  let array_equal left right =
    Array.length left = Array.length right
    && Array.for_all2 Int.equal left right
  in
  let source = Signal.Var.create 0 in
  let mapped =
    Signal.Var.watch source
    |> Signal.map ~equal:array_equal (fun value -> Array.make 1 (value mod 2))
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (record_observer events))
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  (match List.rev !events with
   | [ Signal.Initialized initialized ] ->
       Alcotest.(check (list int)) "initialized derived value" [ 0 ]
         (Array.to_list initialized)
   | _ ->
       Alcotest.fail
         "expected structural cutoff to suppress fresh equal block");
  Alcotest.(check (list int)) "observer current remains structural value" [ 0 ]
    (Array.to_list (run_ok rt (Signal.Observer.read observer)));
  run_ok rt (Signal.Observer.dispose observer)

let test_default_physical_cutoff_suppresses_in_place_mutation () =
  with_runtime @@ fun rt ->
  let block = Array.make 1 1 in
  let source = Signal.Var.create block in
  let mapped_calls = ref 0 in
  let mapped =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr mapped_calls;
           Array.get value 0)
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe mapped (record_observer events))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial mapped value" 1
    (run_ok rt (Signal.Observer.read observer));
  Array.set block 0 2;
  run_ok rt (Signal.Var.set source block);
  Alcotest.(check int) "direct source exposes mutated block" 2
    (Array.get (Signal.Var.value source) 0);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "physical cutoff suppresses recompute" 1 !mapped_calls;
  Alcotest.(check int) "observer keeps previous derived snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !events with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected no event after same-block mutation");
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

let test_observer_ordering_across_graph_branches_is_deterministic () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let upstream =
    Signal.Var.watch source |> Signal.map (fun value -> value + 1)
  in
  let downstream = Signal.map (fun value -> value * 10) upstream in
  let independent = Signal.Var.watch source |> Signal.map (fun value -> -value) in
  let events = ref [] in
  let record label _update =
    Effect.sync (fun () -> events := label :: !events)
  in
  let upstream_observer =
    run_ok rt (Signal.Observer.observe upstream (record "upstream"))
  in
  let downstream_observer =
    run_ok rt (Signal.Observer.observe downstream (record "downstream"))
  in
  let independent_observer =
    run_ok rt (Signal.Observer.observe independent (record "independent"))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "initial graph observer order"
    [ "upstream"; "downstream"; "independent" ]
    (List.rev !events);
  events := [];
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list string))
    "changed graph observer order"
    [ "upstream"; "downstream"; "independent" ]
    (List.rev !events);
  run_ok rt (Signal.Observer.dispose upstream_observer);
  run_ok rt (Signal.Observer.dispose downstream_observer);
  run_ok rt (Signal.Observer.dispose independent_observer)

let test_observer_callbacks_read_consistent_published_snapshot () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let left = Signal.Var.watch source |> Signal.map (fun value -> value + 1) in
  let right = Signal.Var.watch source |> Signal.map (fun value -> value + 2) in
  let total = Signal.map2 ( + ) left right in
  let left_observer = ref None in
  let right_observer = ref None in
  let total_observer = ref None in
  let snapshots = ref [] in
  let record_snapshot label =
    match (!left_observer, !right_observer, !total_observer) with
    | Some left_observer, Some right_observer, Some total_observer ->
        Signal.Observer.read left_observer
        |> Effect.map_error (fun _ -> `Observer_failed)
        |> Effect.bind (fun left_value ->
               Signal.Observer.read right_observer
               |> Effect.map_error (fun _ -> `Observer_failed)
               |> Effect.bind (fun right_value ->
                      Signal.Observer.read total_observer
                      |> Effect.map_error (fun _ -> `Observer_failed)
                      |> Effect.bind (fun total_value ->
                             Effect.sync (fun () ->
                                 snapshots :=
                                   (label, left_value, right_value, total_value)
                                   :: !snapshots))))
    | _ -> Effect.unit
  in
  let left_handle =
    run_ok rt
      (Signal.Observer.observe left (fun _ ->
           Signal.Var.set source 100
           |> Effect.map_error (fun _ -> `Observer_failed)
           |> Effect.bind (fun () -> record_snapshot "left")))
  in
  let right_handle =
    run_ok rt (Signal.Observer.observe right (fun _ -> record_snapshot "right"))
  in
  let total_handle =
    run_ok rt (Signal.Observer.observe total (fun _ -> record_snapshot "total"))
  in
  left_observer := Some left_handle;
  right_observer := Some right_handle;
  total_observer := Some total_handle;
  run_ok rt Signal.stabilize;
  snapshots := [];
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  let render_snapshot (label, left_value, right_value, total_value) =
    Printf.sprintf "%s:%d:%d:%d" label left_value right_value total_value
  in
  Alcotest.(check (list string))
    "all callbacks read same changed snapshot"
    [ "left:3:4:7"; "right:3:4:7"; "total:3:4:7" ]
    (List.rev_map render_snapshot !snapshots);
  Alcotest.(check int) "callback mutation waits for next stabilization" 7
    (run_ok rt (Signal.Observer.read total_handle));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "next stabilization sees callback mutation" 203
    (run_ok rt (Signal.Observer.read total_handle));
  run_ok rt (Signal.Observer.dispose left_handle);
  run_ok rt (Signal.Observer.dispose right_handle);
  run_ok rt (Signal.Observer.dispose total_handle)

let test_observer_dispose_during_callback_skips_collected_event () =
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
                  | Some observer -> Signal.Observer.dispose observer
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

let test_observer_registration_skips_callbacks_until_returned () =
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

let test_observer_observe_invalidated_after_activation_fails () =
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
      ( 4,
        fun () ->
          ignore
            (expect_exit_ok "branch switch after observer activation"
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

let test_bind_switches_after_unnecessary_source_change () =
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

let test_bind_invalidated_var_watchers_detach_from_sources () =
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
  Alcotest.(check int) "initial left branch" 10
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "switched to right branch" 20
    (run_ok rt (Signal.Observer.read observer));
  let before_inactive_set = run_ok rt (Signal.stats ()) in
  run_ok rt (Signal.Var.set left 11);
  run_ok rt Signal.stabilize;
  let after_inactive_set = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "inactive source set does not stale invalidated watchers"
    before_inactive_set.Signal.live_dirty_node_count
    after_inactive_set.Signal.live_dirty_node_count;
  Alcotest.(check int) "inactive source set keeps selected value" 20
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_invalidated_bind_rhs_cannot_be_observed () =
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
  expect_graph_error_exn "wrapped invalid scope construction" `Invalid_scope
    (fun () ->
      ignore (Signal.map (fun value -> value + 1) captured : int Signal.signal));
  run_ok rt (Signal.Var.set right 21);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization remains healthy" 21
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_bind_rejects_reused_dynamic_scope_inner () =
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

let signal_version signal =
  let signal_obj = Obj.repr signal in
  (Obj.obj (Obj.field signal_obj 6) : int)

let set_signal_version signal value =
  (* Public APIs cannot drive a signal version to [max_int] in a focused test. *)
  let signal_obj = Obj.repr signal in
  Obj.set_field signal_obj 6 (Obj.repr value)

let signal_valid signal =
  let signal_obj = Obj.repr signal in
  (Obj.obj (Obj.field signal_obj 18) : bool)

let set_signal_valid signal value =
  (* Public invalidation normally prunes invalid nodes immediately; this
     simulates a retained invalid node while checking the public stats contract. *)
  let signal_obj = Obj.repr signal in
  Obj.set_field signal_obj 18 (Obj.repr value)

let test_commit_skips_invalidated_staged_entries () =
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
  let branch_version = signal_version captured in
  let branch_observer =
    run_ok rt (Signal.Observer.observe captured (fun _ -> Effect.unit))
  in
  run_ok rt (Signal.Var.set left 11);
  run_ok rt (Signal.Var.set choose_left false);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "selected switched to right" 20
    (run_ok rt (Signal.Observer.read selected_observer));
  Alcotest.(check bool) "captured branch invalidated" false
    (signal_valid captured);
  Alcotest.(check int) "invalidated staged branch version unchanged"
    branch_version (signal_version captured);
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

let test_nested_bind_sum_matches_map3_and_recreates_rhs_scopes () =
  with_runtime @@ fun rt ->
  let a = Signal.Var.create 1 in
  let b = Signal.Var.create 2 in
  let c = Signal.Var.create 3 in
  let map_sum =
    Signal.map3 (fun a b c -> a + b + c) (Signal.Var.watch a)
      (Signal.Var.watch b) (Signal.Var.watch c)
  in
  let outer_rhs_calls = ref 0 in
  let inner_rhs_calls = ref 0 in
  let bind_sum =
    Signal.bind (Signal.Var.watch a) (fun a ->
        incr outer_rhs_calls;
        Signal.bind (Signal.Var.watch b) (fun b ->
            incr inner_rhs_calls;
            Signal.Var.watch c |> Signal.map (fun c -> a + b + c)))
  in
  let combined = Signal.both map_sum bind_sum in
  let observer =
    run_ok rt (Signal.Observer.observe combined (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let before_rewire = run_ok rt (Signal.stats ()) in
  Alcotest.(check (pair int int)) "initial sums match" (6, 6)
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "outer rhs created once" 1 !outer_rhs_calls;
  Alcotest.(check int) "inner rhs created once" 1 !inner_rhs_calls;
  run_ok rt (Signal.Var.set c 4);
  run_ok rt Signal.stabilize;
  Alcotest.(check (pair int int)) "leaf update keeps sums equal" (7, 7)
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "leaf update does not recreate outer rhs" 1
    !outer_rhs_calls;
  Alcotest.(check int) "leaf update does not recreate inner rhs" 1
    !inner_rhs_calls;
  run_ok rt (Signal.Var.set a 10);
  run_ok rt Signal.stabilize;
  let after_rewire = run_ok rt (Signal.stats ()) in
  Alcotest.(check (pair int int)) "outer source update keeps sums equal" (16, 16)
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "outer source recreates outer rhs" 2 !outer_rhs_calls;
  Alcotest.(check int) "outer source recreates nested rhs" 2 !inner_rhs_calls;
  Alcotest.(check bool) "nested bind invalidated stale scopes" true
    (after_rewire.Signal.dynamic_scope_invalidations
     > before_rewire.Signal.dynamic_scope_invalidations);
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
        | Signal.Initialized 1 ->
            Signal.Var.set source 2
            |> Effect.map_error (fun _ -> `Observer_failed)
        | Initialized _ | Changed _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "current stabilization snapshot" 1
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "next stabilization sees observer mutation" 2
    (run_ok rt (Signal.Observer.read observer))

let test_observer_phase_multiple_sets_publish_final_next_value () =
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
    before_read.Signal.pure_snapshot_commit_count
    after_read.Signal.pure_snapshot_commit_count;
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
    (after_second_stabilize.Signal.pure_snapshot_commit_count
     > after_stabilize.Signal.pure_snapshot_commit_count);
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

let test_dispose_unlinks_observer_from_graph () =
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

let test_signal_version_overflow_does_not_publish_partial_snapshot () =
  let module Overflow_signal = Eta_signal.Make (Observer_error) () in
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
  set_signal_version signal max_int;
  run_ok rt (Overflow_signal.Var.set source 2);
  expect_die "signal version overflow"
    (Eta_eio.Runtime.run rt (widen Overflow_signal.stabilize));
  Alcotest.(check int) "old snapshot remains after version overflow" 1
    (run_ok rt (Overflow_signal.Observer.read observer));
  set_signal_version signal 0;
  run_ok rt Overflow_signal.stabilize;
  Alcotest.(check int) "retry publishes pending source" 2
    (run_ok rt (Overflow_signal.Observer.read observer));
  (match List.rev !events with
   | [ Overflow_signal.Initialized 1;
       Changed { old_value = 1; new_value = 2 } ] ->
       ()
   | _ -> Alcotest.fail "expected retry to deliver changed event");
  run_ok rt (Overflow_signal.Observer.dispose observer)

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

let test_ambiguous_node_creation_during_observer_effect_is_typed_failure () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           Effect.sync (fun () ->
               ignore (Signal.const 1 : int Signal.signal))))
  in
  expect_fail "observer effect ambiguous scope" (( = ) `Ambiguous_scope)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_failure_fails_stabilize () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let observer =
    run_ok rt
      (Signal.Observer.observe observed (function
        | Initialized _ -> Effect.fail `Observer_failed
        | Changed _ -> Effect.unit))
  in
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_typed_failure_retries_after_flag_fixed () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let fail = ref false in
  let callback_values = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (function
        | Signal.Initialized value ->
            Effect.sync (fun () -> callback_values := value :: !callback_values)
        | Changed { new_value; _ } ->
            if !fail then Effect.fail `Observer_failed
            else
              Effect.sync (fun () ->
                  callback_values := new_value :: !callback_values)))
  in
  run_ok rt Signal.stabilize;
  fail := true;
  run_ok rt (Signal.Var.set source 2);
  expect_fail "observer typed failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "snapshot published before observer failure" 2
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "failing callback did not record side effect" [ 1 ]
    (List.rev !callback_values);
  fail := false;
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "later stabilization succeeds" 3
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "retry records later value" [ 1; 3 ]
    (List.rev !callback_values);
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_failed_delivery_coalesces_reverted_value () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let fail = ref false in
  let callback_values = ref [] in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (function
        | Signal.Initialized value ->
            Effect.sync (fun () -> callback_values := value :: !callback_values)
        | Changed { new_value; _ } ->
            if !fail then Effect.fail `Observer_failed
            else
              Effect.sync (fun () ->
                  callback_values := new_value :: !callback_values)))
  in
  run_ok rt Signal.stabilize;
  fail := true;
  run_ok rt (Signal.Var.set source 2);
  expect_fail "observer typed failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check int) "failed snapshot was published" 2
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "failed callback did not record side effect" [ 1 ]
    (List.rev !callback_values);
  fail := false;
  run_ok rt (Signal.Var.set source 1);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "reverted snapshot is current" 1
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check (list int)) "reverted failed blip is coalesced" [ 1 ]
    (List.rev !callback_values);
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check (list int)) "later distinct value still emits" [ 1; 2 ]
    (List.rev !callback_values);
  run_ok rt (Signal.Observer.dispose observer)

let test_observer_failure_is_fail_fast () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observed = Signal.Var.watch source in
  let later_ran = ref false in
  let failing_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ -> Effect.fail `Observer_failed))
  in
  let later_observer =
    run_ok rt
      (Signal.Observer.observe observed (fun _ ->
           Effect.sync (fun () -> later_ran := true)))
  in
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  Alcotest.(check bool) "later observer did not run" false !later_ran;
  Alcotest.(check int) "failing observer snapshot published" 1
    (run_ok rt (Signal.Observer.read failing_observer));
  Alcotest.(check int) "skipped observer snapshot published" 1
    (run_ok rt (Signal.Observer.read later_observer));
  run_ok rt (Signal.Observer.dispose failing_observer);
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "skipped observer event retries" true !later_ran;
  run_ok rt (Signal.Observer.dispose later_observer)

let test_observer_registration_and_self_disposal_inside_callback () =
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
                                    Signal.Observer.dispose primary))
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
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let now_calls = ref 0 in
  let now_ms () =
    incr now_calls;
    if !now_calls <= 2 then 0
    else failwith "timer start clock failure"
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~now_ms ()
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

let test_concurrent_effectful_update_same_variable_fails_fast () =
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

let test_effectful_update_acquire_interruption_releases_slot () =
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

let test_observer_read_waits_for_graph_lane () =
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

let test_stats_and_dot_are_read_only () =
  with_runtime @@ fun rt ->
  let check_stats label expected actual =
    Alcotest.(check int)
      (label ^ " pure_snapshot_commit_count")
      expected.Signal.pure_snapshot_commit_count
      actual.Signal.pure_snapshot_commit_count;
    Alcotest.(check int)
      (label ^ " callback_delivery_count")
      expected.Signal.callback_delivery_count
      actual.Signal.callback_delivery_count;
    Alcotest.(check int)
      (label ^ " total_node_count")
      expected.Signal.total_node_count actual.Signal.total_node_count;
    Alcotest.(check int)
      (label ^ " active_observer_count")
      expected.Signal.active_observer_count actual.Signal.active_observer_count;
    Alcotest.(check int)
      (label ^ " invalid_observer_count")
      expected.Signal.invalid_observer_count actual.Signal.invalid_observer_count;
    Alcotest.(check int)
      (label ^ " necessary_node_count")
      expected.Signal.necessary_node_count actual.Signal.necessary_node_count;
    Alcotest.(check int)
      (label ^ " dead_node_count")
      expected.Signal.dead_node_count actual.Signal.dead_node_count;
    Alcotest.(check int)
      (label ^ " live_dirty_node_count")
      expected.Signal.live_dirty_node_count actual.Signal.live_dirty_node_count;
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
      actual.Signal.nodes_became_unnecessary;
    Alcotest.(check int)
      (label ^ " stream_bridge_drop_count")
      expected.Signal.stream_bridge_drop_count
      actual.Signal.stream_bridge_drop_count;
    Alcotest.(check int)
      (label ^ " lane_waiter_count")
      expected.Signal.lane_waiter_count actual.Signal.lane_waiter_count;
    Alcotest.(check int)
      (label ^ " lane_cancelled_waiter_count")
      expected.Signal.lane_cancelled_waiter_count
      actual.Signal.lane_cancelled_waiter_count
  in
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
  Alcotest.(check bool) "live dirty nodes visible before stabilize" true
    (after_observe.Signal.live_dirty_node_count
     > before.Signal.live_dirty_node_count);
  run_ok rt Signal.stabilize;
  let after_stabilize = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "pure snapshot commit count increments"
    (before.Signal.pure_snapshot_commit_count + 1)
    after_stabilize.Signal.pure_snapshot_commit_count;
  Alcotest.(check int) "callback delivery count increments"
    (before.Signal.callback_delivery_count + 1)
    after_stabilize.Signal.callback_delivery_count;
  Alcotest.(check int) "invalid observers are explicit" 0
    after_stabilize.Signal.invalid_observer_count;
  Alcotest.(check int) "stabilize does not add dead nodes"
    before.Signal.dead_node_count
    after_stabilize.Signal.dead_node_count;
  Alcotest.(check bool) "recompute count visible" true
    (after_stabilize.Signal.recompute_count > before.Signal.recompute_count);
  Alcotest.(check bool) "live dirty nodes clear after stabilize" true
    (after_stabilize.Signal.live_dirty_node_count
     < after_observe.Signal.live_dirty_node_count);
  let after_stats_read = run_ok rt (Signal.stats ()) in
  check_stats "stats read-only" after_stabilize after_stats_read;
  let dot_before_unobserved = run_ok rt (Signal.to_dot ()) in
  Alcotest.(check bool)
    "dot dump is non-empty" true
    (String.length dot_before_unobserved > 0);
  let necessary_dot_nodes =
    count_occurrences dot_before_unobserved "[label="
  in
  let _unobserved =
    Signal.Var.watch (Signal.Var.create 10) |> Signal.map (fun n -> n + 1)
  in
  let before_dot = run_ok rt (Signal.stats ()) in
  let dot = run_ok rt (Signal.to_dot ()) in
  Alcotest.(check int) "dot ignores unobserved nodes" necessary_dot_nodes
    (count_occurrences dot "[label=");
  let after_dot = run_ok rt (Signal.stats ()) in
  check_stats "dot read-only" before_dot after_dot;
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

let test_stats_split_snapshot_commit_from_callback_delivery () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let fail_once = ref true in
  let observer =
    run_ok rt
      (Signal.Observer.observe (Signal.Var.watch source) (fun _update ->
           if !fail_once then (
             fail_once := false;
             Effect.fail `Observer_failed)
           else Effect.unit))
  in
  let before = run_ok rt (Signal.stats ()) in
  expect_fail "observer callback failure"
    (function
      | `Observer_error `Observer_failed -> true
      | _ -> false)
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  let after_failure = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "failed callback still committed pure snapshot"
    (before.Signal.pure_snapshot_commit_count + 1)
    after_failure.Signal.pure_snapshot_commit_count;
  Alcotest.(check int) "failed callback did not complete delivery"
    before.Signal.callback_delivery_count
    after_failure.Signal.callback_delivery_count;
  Alcotest.(check int) "no invalid observer hidden by necessary count" 0
    after_failure.Signal.invalid_observer_count;
  Alcotest.(check int) "failure does not add dead nodes"
    before.Signal.dead_node_count
    after_failure.Signal.dead_node_count;
  run_ok rt Signal.stabilize;
  let after_retry = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "retry commits second pure snapshot"
    (after_failure.Signal.pure_snapshot_commit_count + 1)
    after_retry.Signal.pure_snapshot_commit_count;
  Alcotest.(check int) "retry completes callback delivery"
    (after_failure.Signal.callback_delivery_count + 1)
    after_retry.Signal.callback_delivery_count;
  run_ok rt (Signal.Observer.dispose observer)

let test_repeated_dependencies_are_stored_once () =
  with_runtime @@ fun rt ->
  let source = Dependency_signal.Var.create 1 in
  let base = Dependency_signal.Var.watch source in
  let repeated =
    Dependency_signal.map2 (fun left _right -> left) base base
  in
  let observer =
    run_ok rt
      (Dependency_signal.Observer.observe repeated (fun _ -> Effect.unit))
  in
  run_ok rt Dependency_signal.stabilize;
  let options : Dependency_signal.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = false;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = false;
    }
  in
  let dot = run_ok rt (Dependency_signal.to_dot ~options ()) in
  Alcotest.(check int) "map2 stores one dependency edge" 1
    (count_occurrences dot "dependencies=1");
  Alcotest.(check int) "source records one dependent edge" 1
    (count_occurrences dot "dependents=1");
  Alcotest.(check int) "map2 does not store duplicate dependencies" 0
    (count_occurrences dot "dependencies=2");
  Alcotest.(check int) "source does not store duplicate dependents" 0
    (count_occurrences dot "dependents=2");
  run_ok rt (Dependency_signal.Observer.dispose observer)

let test_to_dot_deduplicates_repeated_dependency_edges () =
  with_runtime @@ fun rt ->
  let source = Dot_signal.Var.create 1 in
  let base = Dot_signal.Var.watch source in
  let repeated = Dot_signal.map2 (fun left _right -> left) base base in
  let observer =
    run_ok rt (Dot_signal.Observer.observe repeated (fun _ -> Effect.unit))
  in
  run_ok rt Dot_signal.stabilize;
  let dot = run_ok rt (Dot_signal.to_dot ()) in
  Alcotest.(check int) "repeated dependency edge rendered once" 1
    (count_occurrences dot " -> ");
  run_ok rt (Dot_signal.Observer.dispose observer)

let test_to_dot_debug_options_expose_hidden_state () =
  with_logger_test_clock @@ fun _sw _clock rt _logger ->
  let source = Dot_signal.Var.create 1 in
  let observed =
    Dot_signal.Var.watch source |> Dot_signal.map (fun value -> value + 1)
  in
  let _unobserved =
    Dot_signal.Var.watch (Dot_signal.Var.create 10)
    |> Dot_signal.map (fun value -> value + 1)
  in
  let timer = run_ok rt (Dot_signal.Time.interval (Duration.ms 50)) in
  let branch = Dot_signal.Var.create true in
  let scoped =
    Dot_signal.bind (Dot_signal.Var.watch branch) (fun enabled ->
        if enabled then Dot_signal.const 1 else Dot_signal.const 0)
  in
  let observer =
    run_ok rt (Dot_signal.Observer.observe observed (fun _ -> Effect.unit))
  in
  let timer_observer =
    run_ok rt (Dot_signal.Observer.observe timer (fun _ -> Effect.unit))
  in
  let scoped_observer =
    run_ok rt (Dot_signal.Observer.observe scoped (fun _ -> Effect.unit))
  in
  run_ok rt Dot_signal.stabilize;
  run_ok rt (Dot_signal.Var.set source 2);
  let necessary_dot = run_ok rt (Dot_signal.to_dot ()) in
  let debug_options : Dot_signal.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = true;
      dot_timers = true;
      dot_state = true;
      dot_dynamic_scopes = true;
    }
  in
  let debug_dot =
    run_ok rt (Dot_signal.to_dot ~options:debug_options ())
  in
  Alcotest.(check bool) "debug dot shows more than necessary graph" true
    (count_occurrences debug_dot "[label="
     > count_occurrences necessary_dot "[label=");
  Alcotest.(check bool) "debug dot shows observers" true
    (count_occurrences debug_dot "observer:" > 0);
  Alcotest.(check bool) "debug dot shows timer state" true
    (count_occurrences debug_dot "timer_active=true" > 0);
  Alcotest.(check bool) "debug dot shows timer lifecycle state" true
    (count_occurrences debug_dot "timer_state=" > 0);
  Alcotest.(check bool) "debug dot shows queued source state" true
    (count_occurrences debug_dot "queued=true" > 0);
  Alcotest.(check bool) "debug dot shows dirty state" true
    (count_occurrences debug_dot "dirty=true" > 0);
  Alcotest.(check bool) "debug dot shows dynamic scope state" true
    (count_occurrences debug_dot "scope=" > 0);
  Alcotest.(check bool) "debug dot labels signal identities" true
    (count_occurrences debug_dot "signal_id=s" > 0);
  Alcotest.(check bool) "debug dot labels source identities" true
    (count_occurrences debug_dot "var_id=v" > 0);
  Alcotest.(check bool) "debug dot labels scope identities" true
    (count_occurrences debug_dot "scope_id=sc" > 0);
  Alcotest.(check bool) "debug dot labels scope owners" true
    (count_occurrences debug_dot "scope_owner=s" > 0);
  Alcotest.(check bool) "debug dot labels scope parents" true
    (count_occurrences debug_dot "scope_parent=" > 0);
  run_ok rt (Dot_signal.Observer.dispose observer);
  run_ok rt (Dot_signal.Observer.dispose timer_observer);
  run_ok rt (Dot_signal.Observer.dispose scoped_observer)

let test_dead_nodes_and_dot_include_pruned_invalid_nodes () =
  let module Tombstone_signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let choose_left = Tombstone_signal.Var.create true in
  let captured_left = ref None in
  let selected =
    Tombstone_signal.bind (Tombstone_signal.Var.watch choose_left) (fun use_left ->
        if use_left then
          let signal =
            Tombstone_signal.const 10
            |> Tombstone_signal.map (fun value -> value + 1)
          in
          captured_left := Some signal;
          signal
        else Tombstone_signal.const 20)
  in
  let observer =
    run_ok rt (Tombstone_signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Tombstone_signal.stabilize;
  let branch =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind branch"
  in
  let branch_observer =
    run_ok rt (Tombstone_signal.Observer.observe branch (fun _ -> Effect.unit))
  in
  run_ok rt Tombstone_signal.stabilize;
  let before_switch = run_ok rt (Tombstone_signal.stats ()) in
  run_ok rt (Tombstone_signal.Var.set choose_left false);
  run_ok rt Tombstone_signal.stabilize;
  let after_switch = run_ok rt (Tombstone_signal.stats ()) in
  Alcotest.(check bool) "dead branch nodes are counted" true
    (after_switch.Tombstone_signal.dead_node_count
     > before_switch.Tombstone_signal.dead_node_count);
  let options : Tombstone_signal.dot_options =
    {
      dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = true;
    }
  in
  let dot = run_ok rt (Tombstone_signal.to_dot ~options ()) in
  Alcotest.(check bool) "all-including-invalid dot shows dead nodes" true
    (count_occurrences dot "valid=false" > 0);
  Alcotest.(check bool) "all-including-invalid dot namespaces tombstones" true
    (count_occurrences dot "dead_s" > 0);
  Alcotest.(check bool) "all-including-invalid dot shows invalid scopes" true
    (count_occurrences dot ":invalid" > 0);
  Alcotest.(check int) "all-including-invalid dot shows invalid observer" 1
    (count_occurrences dot "state=invalid_scope");
  Alcotest.(check int) "all-including-invalid dot shows both observers" 2
    (count_occurrences dot "observer:");
  Alcotest.(check int) "all-including-invalid dot shows observer edges" 2
    (count_occurrences dot "style=dashed,label=\"observes\"");
  run_ok rt (Tombstone_signal.Observer.dispose branch_observer);
  run_ok rt (Tombstone_signal.Observer.dispose observer)

let test_dead_node_count_ignores_retained_invalid_non_tombstones () =
  let module Dead_count_signal = Eta_signal.Make (Observer_error) () in
  with_runtime @@ fun rt ->
  let retained = Dead_count_signal.const 1 in
  let before = run_ok rt (Dead_count_signal.stats ()) in
  set_signal_valid retained false;
  let after = run_ok rt (Dead_count_signal.stats ()) in
  Alcotest.(check int)
    "retained invalid non-tombstone is not counted as dead"
    before.Dead_count_signal.dead_node_count
    after.Dead_count_signal.dead_node_count

let test_deterministic_model_matches_small_dynamic_graph () =
  with_runtime @@ fun rt ->
  let left = Signal.Var.create 1 in
  let right = Signal.Var.create 10 in
  let choose_left = Signal.Var.create true in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let both_sources =
    Signal.all [ Signal.Var.watch left; Signal.Var.watch right ]
    |> Signal.map (List.fold_left ( + ) 0)
  in
  let total = Signal.map2 ( + ) selected both_sources in
  let observer =
    run_ok rt (Signal.Observer.observe total (fun _ -> Effect.unit))
  in
  let model_left = ref 1 in
  let model_right = ref 10 in
  let model_choose_left = ref true in
  let expected () =
    let selected = if !model_choose_left then !model_left else !model_right in
    selected + !model_left + !model_right
  in
  let operations =
    [
      `Set_left 2;
      `Set_right 20;
      `Choose false;
      `Set_left 3;
      `Set_right 21;
      `Choose true;
      `Set_left 4;
      `Choose false;
      `Set_right 22;
      `Choose true;
    ]
  in
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial model value" (expected ())
    (run_ok rt (Signal.Observer.read observer));
  List.iteri
    (fun index operation ->
      (match operation with
       | `Set_left value ->
           model_left := value;
           run_ok rt (Signal.Var.set left value)
       | `Set_right value ->
           model_right := value;
           run_ok rt (Signal.Var.set right value)
       | `Choose value ->
           model_choose_left := value;
           run_ok rt (Signal.Var.set choose_left value));
      run_ok rt Signal.stabilize;
      Alcotest.(check int)
        (Printf.sprintf "model step %d" index)
        (expected ())
        (run_ok rt (Signal.Observer.read observer)))
    operations;
  run_ok rt (Signal.Observer.dispose observer);
  expect_fail "disposed model observer read" (( = ) `Disposed_observer)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read observer)))

let test_randomized_model_matches_small_signal_graph () =
  with_runtime @@ fun rt ->
  let next rng bound =
    rng := ((!rng * 1103515245) + 12345) land 0x3fffffff;
    !rng mod bound
  in
  let random_value rng = next rng 41 - 20 in
  let run_seed seed =
    let rng = ref seed in
    let a = Signal.Var.create 1 in
    let b = Signal.Var.create 2 in
    let c = Signal.Var.create 3 in
    let choose_pair = Signal.Var.create true in
    let offset = Signal.Var.create 0 in
    let model_a = ref 1 in
    let model_b = ref 2 in
    let model_c = ref 3 in
    let model_choose_pair = ref true in
    let model_offset = ref 0 in
    let mapped_a = Signal.Var.watch a |> Signal.map (fun value -> value + 10) in
    let pair_sum = Signal.map2 ( + ) mapped_a (Signal.Var.watch b) in
    let all_sum =
      Signal.all [ mapped_a; Signal.Var.watch b; Signal.Var.watch c ]
      |> Signal.map (List.fold_left ( + ) 0)
    in
    let selected =
      Signal.bind (Signal.Var.watch choose_pair) (fun use_pair ->
          if use_pair then pair_sum else all_sum)
    in
    let total = Signal.map2 ( + ) selected (Signal.Var.watch offset) in
    let expected () =
      let mapped_a = !model_a + 10 in
      let pair_sum = mapped_a + !model_b in
      let all_sum = mapped_a + !model_b + !model_c in
      let selected = if !model_choose_pair then pair_sum else all_sum in
      selected + !model_offset
    in
    let make_observer () =
      run_ok rt (Signal.Observer.observe total (fun _ -> Effect.unit))
    in
    let observer = ref (make_observer ()) in
    let check_read label expected =
      Alcotest.(check int) label expected
        (run_ok rt (Signal.Observer.read !observer))
    in
    let check_uninitialized label =
      expect_fail label
        (( = ) `Uninitialized_observer)
        (Eta_eio.Runtime.run rt (widen (Signal.Observer.read !observer)))
    in
    let check_disposed label disposed =
      expect_fail label
        (( = ) `Disposed_observer)
        (Eta_eio.Runtime.run rt (widen (Signal.Observer.read disposed)))
    in
    let last_stabilized = ref 0 in
    let apply_write step write_index =
      let label =
        Printf.sprintf "seed %d step %d write %d" seed step write_index
      in
      match next rng 5 with
      | 0 ->
          let value = random_value rng in
          model_a := value;
          run_ok rt (Signal.Var.set a value);
          Alcotest.(check int) (label ^ " source a") value (Signal.Var.value a)
      | 1 ->
          let value = random_value rng in
          model_b := value;
          run_ok rt (Signal.Var.set b value);
          Alcotest.(check int) (label ^ " source b") value (Signal.Var.value b)
      | 2 ->
          let value = random_value rng in
          model_c := value;
          run_ok rt (Signal.Var.set c value);
          Alcotest.(check int) (label ^ " source c") value (Signal.Var.value c)
      | 3 ->
          let value = next rng 2 = 0 in
          model_choose_pair := value;
          run_ok rt (Signal.Var.set choose_pair value);
          Alcotest.(check bool)
            (label ^ " source choose")
            value (Signal.Var.value choose_pair)
      | _ ->
          let value = random_value rng in
          model_offset := value;
          run_ok rt (Signal.Var.set offset value);
          Alcotest.(check int)
            (label ^ " source offset")
            value (Signal.Var.value offset)
    in
    check_uninitialized
      (Printf.sprintf "seed %d initial observer uninitialized" seed);
    run_ok rt Signal.stabilize;
    last_stabilized := expected ();
    check_read
      (Printf.sprintf "seed %d initial stabilized value" seed)
      !last_stabilized;
    for step = 1 to 40 do
      let write_count = 1 + next rng 4 in
      for write_index = 1 to write_count do
        apply_write step write_index
      done;
      if next rng 3 = 0 then
        check_read
          (Printf.sprintf "seed %d step %d read before stabilize" seed step)
          !last_stabilized;
      run_ok rt Signal.stabilize;
      last_stabilized := expected ();
      check_read
        (Printf.sprintf "seed %d step %d stabilized model" seed step)
        !last_stabilized;
      if next rng 7 = 0 then (
        let disposed = !observer in
        run_ok rt (Signal.Observer.dispose disposed);
        check_disposed
          (Printf.sprintf "seed %d step %d disposed observer read" seed step)
          disposed;
        observer := make_observer ();
        check_uninitialized
          (Printf.sprintf "seed %d step %d replacement uninitialized" seed step);
        run_ok rt Signal.stabilize;
        last_stabilized := expected ();
        check_read
          (Printf.sprintf "seed %d step %d replacement stabilized" seed step)
          !last_stabilized)
    done;
    let disposed = !observer in
    run_ok rt (Signal.Observer.dispose disposed);
    check_disposed (Printf.sprintf "seed %d final disposed read" seed) disposed
  in
  List.iter run_seed [ 7; 19; 101 ]

let test_fanout_fanin_cutoff_and_partial_disposal () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 0 in
  let root_calls = ref 0 in
  let root =
    Signal.Var.watch source
    |> Signal.map ~equal:Int.equal (fun value ->
           incr root_calls;
           value mod 2)
  in
  let child_calls = Array.make 8 0 in
  let children =
    List.init 8 (fun index ->
        Signal.map
          (fun value ->
            child_calls.(index) <- child_calls.(index) + 1;
            value + index)
          root)
  in
  let sum =
    Signal.all children |> Signal.map (List.fold_left ( + ) 0)
  in
  let first_observer =
    run_ok rt (Signal.Observer.observe sum (fun _ -> Effect.unit))
  in
  let second_observer =
    run_ok rt (Signal.Observer.observe sum (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let after_initial = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "initial fanin sum" 28
    (run_ok rt (Signal.Observer.read first_observer));
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "root recomputed for cutoff" 2 !root_calls;
  Alcotest.(check (list int))
    "root cutoff suppressed fanout children" (List.init 8 (fun _ -> 1))
    (Array.to_list child_calls);
  run_ok rt (Signal.Observer.dispose first_observer);
  let after_partial_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool) "shared graph remains necessary after partial dispose"
    true
    (after_partial_dispose.Signal.necessary_node_count
     = after_initial.Signal.necessary_node_count);
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "remaining observer sees fanin update" 36
    (run_ok rt (Signal.Observer.read second_observer));
  run_ok rt (Signal.Observer.dispose second_observer);
  let after_final_dispose = run_ok rt (Signal.stats ()) in
  Alcotest.(check bool) "final disposal clears necessary fanout" true
    (after_final_dispose.Signal.necessary_node_count
     < after_partial_dispose.Signal.necessary_node_count)

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

let seed_interval_source signal value =
  (* Public APIs cannot drive an interval to [max_int] in a focused test. *)
  let signal_obj = Obj.repr signal in
  let kind = Obj.field signal_obj 2 in
  if Obj.tag kind <> 1 then Alcotest.fail "expected interval source signal";
  let source = Obj.field kind 0 in
  Obj.set_field source 2 (Obj.repr value);
  Obj.set_field source 3 (Obj.repr value)

let set_signal_timer_generation signal value =
  (* Public APIs cannot drive timer generations to [max_int] in a focused test. *)
  let signal_obj = Obj.repr signal in
  let timer_opt = Obj.field signal_obj 19 in
  if Obj.is_int timer_opt then Alcotest.fail "expected timer signal";
  let timer = Obj.field timer_opt 0 in
  let timer_state = Obj.field timer 0 in
  if Obj.is_int timer_state then Alcotest.fail "expected timer state";
  let updated_state = Obj.new_block (Obj.tag timer_state) (Obj.size timer_state) in
  for index = 0 to Obj.size timer_state - 1 do
    Obj.set_field updated_state index (Obj.field timer_state index)
  done;
  Obj.set_field updated_state 0 (Obj.repr value);
  Obj.set_field timer 0 updated_state

let set_observer_on_dispose observer hooks =
  (* Public APIs only install internal stream hooks; this keeps the regression
     focused on hook failure without widening the signal API. *)
  let observer_obj = Obj.repr observer in
  Obj.set_field observer_obj 10 (Obj.repr hooks)

let test_time_interval_overflow_saturates () =
  with_logger_test_clock @@ fun _sw clock rt logger ->
  let signal = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  seed_interval_source signal max_int;
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "initial interval max" max_int
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "interval remains saturated" max_int
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "overflow logs no daemon diagnostic" 0
    (List.length (Logger.dump logger));
  run_ok rt (Signal.Observer.dispose observer);
  Alcotest.(check int) "dispose logs no daemon diagnostic" 0
    (List.length (Logger.dump logger))

let test_time_inactive_timer_stop_is_idempotent () =
  let module Idempotent_signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let signal =
    run_ok rt (Idempotent_signal.Time.interval (Duration.ms 10))
  in
  set_signal_timer_generation signal max_int;
  run_ok rt Idempotent_signal.stabilize;
  run_ok rt Idempotent_signal.stabilize

let test_time_timer_generation_overflow_fails_loudly () =
  let module Overflow_signal = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Overflow_signal.Time.interval (Duration.ms 10)) in
  let observer =
    run_ok rt (Overflow_signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  set_signal_timer_generation signal max_int;
  expect_die "timer generation overflow"
    (Eta_eio.Runtime.run rt (widen (Overflow_signal.Observer.dispose observer)))

let test_time_large_clock_jump_catches_up_without_auto_stabilize () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let check_timer_snapshot label
      ( expected_interval,
        expected_now,
        expected_after,
        expected_deadline,
        expected_step )
      (actual_interval, actual_now, actual_after, actual_deadline, actual_step) =
    Alcotest.(check int) (label ^ " interval") expected_interval actual_interval;
    Alcotest.(check int) (label ^ " now") expected_now actual_now;
    Alcotest.(check bool) (label ^ " after") expected_after actual_after;
    Alcotest.(check bool) (label ^ " deadline") expected_deadline actual_deadline;
    Alcotest.(check int) (label ^ " step") expected_step actual_step
  in
  let interval = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let now = run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ()) in
  let after =
    run_ok rt (Signal.Time.after ~every:(Duration.ms 10) (Duration.ms 50))
  in
  let deadline = run_ok rt (Signal.Time.deadline ~every:(Duration.ms 10) 50) in
  let step =
    run_ok rt (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 succ)
  in
  let combined =
    Signal.map5
      (fun interval now after deadline step ->
        (interval, now, after, deadline, step))
      interval now after deadline step
  in
  let events = ref [] in
  let observer =
    run_ok rt (Signal.Observer.observe combined (record_observer events))
  in
  wait_for_sleepers clock 5;
  run_ok rt Signal.stabilize;
  check_timer_snapshot "initial timer snapshot" (0, 0, false, false, 0)
    (run_ok rt (Signal.Observer.read observer));
  Eta_test.Test_clock.adjust clock (Duration.ms 100);
  Eta_test.Async.yield ();
  wait_until "large-jump timers settle" (fun () ->
      Eta_test.Test_clock.sleeper_count clock = 3);
  check_timer_snapshot "large clock jump does not auto-stabilize"
    (0, 0, false, false, 0)
    (run_ok rt (Signal.Observer.read observer));
  Alcotest.(check int) "large clock jump emitted no callback before stabilize" 1
    (List.length !events);
  run_ok rt Signal.stabilize;
  check_timer_snapshot "large clock jump catches up on explicit stabilize"
    (10, 100, true, true, 10)
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !events with
   | [
       Signal.Initialized (0, 0, false, false, 0);
       Changed
         {
           old_value = (0, 0, false, false, 0);
           new_value = (10, 100, true, true, 10);
         };
     ] -> ()
   | _ -> Alcotest.fail "unexpected large clock jump events");
  run_ok rt (Signal.Observer.dispose observer)

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

let test_time_step_catches_up_after_late_sleep () =
  with_late_timer_wake @@ fun rt sleep_calls release ->
  let signal =
    run_ok rt (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 succ)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "late step wake rescheduled" (fun () -> !sleep_calls >= 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "late step wake catches up" 10
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

let test_time_catch_up_yields_between_batches () =
  with_cooperative_timer_host @@ fun rt sleep_calls yield_calls _logger ->
  let signal =
    run_ok rt (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 succ)
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_until "catch-up timer attempted next sleep" (fun () -> !sleep_calls >= 2);
  Alcotest.(check bool)
    "large catch-up yielded cooperatively" true
    (!yield_calls > 0);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "step catch-up still applies every cadence" 1_000
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer)

let test_time_large_catch_up_applies_beyond_old_cap () =
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
  (* Start at -1 so the first 1ms cadence is due at 0, reproducing the
     saturated successor edge through public timer APIs. *)
  with_cooperative_timer_host ~initial_ms:(-1) ~jump_ms:max_int
  @@ fun rt sleep_calls _yield_calls logger ->
  let signal = run_ok rt (Signal.Time.deadline ~every:(Duration.ms 1) 1) in
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
  let now_signal = run_ok rt (Signal.Time.now ~every:(Duration.days 1) ()) in
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
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let observer =
    run_ok rt (Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
        Effect.unit))
  in
  let later_hook_ran = ref false in
  set_observer_on_dispose observer
    [
      (fun _ -> failwith "first dispose hook failure");
      (fun _ -> later_hook_ran := true);
      (fun _ -> failwith "third dispose hook failure");
    ];
  let exit = Eta_eio.Runtime.run rt (widen (Signal.Observer.dispose observer)) in
  expect_finalizer_die "first dispose hook failure"
    "first dispose hook failure" exit;
  expect_finalizer_die "third dispose hook failure"
    "third dispose hook failure" exit;
  Alcotest.(check bool) "later hook still ran" true !later_hook_ran

let test_stabilize_disposal_hook_failure_preserves_committed_snapshot () =
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
  let branch_observer =
    run_ok rt (Signal.Observer.observe branch (fun _ -> Effect.unit))
  in
  set_observer_on_dispose branch_observer
    [ (fun _ -> failwith "branch dispose hook failure") ];
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
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.now := 0;
  Hashtbl.clear Cleanup_interrupt_runtime.locals;
  let rt =
    Runtime.create_with_runtime
      (module Cleanup_interrupt_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let source = Signal.Var.create 1 in
  let observer =
    expect_exit_ok "observer registration"
      (Runtime.run rt
         (widen
            (Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
                 Effect.unit))))
  in
  let hook_ran = ref false in
  set_observer_on_dispose observer [ (fun _ -> hook_ran := true) ];
  Cleanup_interrupt_runtime.interrupt_next_protect_return := true;
  (match Runtime.run rt (widen (Signal.Observer.dispose observer)) with
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected disposal interruption");
  Alcotest.(check bool)
    "interrupted dispose still runs finish hook" true !hook_ran

let test_stabilize_interruption_runs_invalidation_hooks () =
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
  let branch_observer =
    expect_exit_ok "branch observer registration"
      (Runtime.run rt
         (widen (Signal.Observer.observe branch (fun _ -> Effect.unit))))
  in
  let hook_ran = ref false in
  set_observer_on_dispose branch_observer [ (fun _ -> hook_ran := true) ];
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
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let signal = run_ok rt (Signal.Time.interval (Duration.days 1)) in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  set_observer_on_dispose observer
    [ (fun _ -> failwith "dispose hook failure") ];
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
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let observer_ref = ref None in
  let disposed_during_step = ref false in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 10) ~initial:0 (fun value ->
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
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let use_timer = Signal.Var.create false in
  let now_signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ()) in
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

let test_time_now_reobserve_refreshes_while_old_sleep_pending () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 10) ()) in
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
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  let signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 5) ()) in
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

let test_time_after_saturates_overflowing_deadline () =
  Eta_test.with_test_clock @@ fun _sw clock rt ->
  Eta_test.Test_clock.set_time clock (max_int - 5);
  let signal =
    run_ok rt
      (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms 10))
  in
  let observer =
    run_ok rt (Signal.Observer.observe signal (fun _ -> Effect.unit))
  in
  wait_for_sleepers clock 1;
  run_ok rt Signal.stabilize;
  Alcotest.(check bool) "saturated future deadline starts pending" false
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

let test_time_step_defect_logs_daemon_diagnostic_and_restarts () =
  with_logger_test_clock @@ fun _sw clock rt logger ->
  let fail = ref true in
  let signal =
    run_ok rt
      (Signal.Time.step ~every:(Duration.ms 5) ~initial:1 (fun n ->
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
  expect_fail "past after duration" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) Duration.zero)));
  expect_fail "clamped past after duration" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.after ~every:(Duration.ms 1) (Duration.ms (-1)))));
  expect_fail "invalid step cadence" (( = ) `Invalid_interval)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.step ~every:Duration.zero ~initial:0 succ)));
  expect_fail "past deadline" (( = ) `Past_deadline)
    (Eta_eio.Runtime.run rt
       (widen (Signal.Time.deadline ~every:(Duration.ms 1) 0)))

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

let test_stream_bridge_interrupted_publish_does_not_duplicate () =
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

let test_stream_bridge_interrupted_sent_wakeup_does_not_duplicate () =
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
                       Cleanup_interrupt_runtime.after_local_binding_count :=
                         Some
                           ( !Cleanup_interrupt_runtime.local_binding_count
                             + 3,
                             fun () ->
                               Cleanup_interrupt_runtime
                               .interrupt_next_protect_return := true ))))))
  in
  let observer, stream =
    expect_exit_ok "stream observer registration"
      (Runtime.run rt (widen (Signal.Stream.observe signal)))
  in
  expect_die "park stream receiver"
    (Runtime.run rt
       (widen (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)));
  Cleanup_interrupt_runtime.local_binding_count := 0;
  arm_interrupt := true;
  (match Runtime.run rt (widen Signal.stabilize) with
  | exception Cleanup_interrupt -> ()
  | Exit.Error _ -> ()
  | Exit.Ok () -> Alcotest.fail "expected injected queue wakeup interrupt");
  arm_interrupt := false;
  Cleanup_interrupt_runtime.interrupt_next_protect_return := false;
  Cleanup_interrupt_runtime.after_local_binding_count := None;
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
     expect_exit_ok "stream collect after interrupted sent wakeup"
       (Runtime.run rt
          (widen (Eta_stream.Stream.take 2 stream |> Eta_stream.run_collect)))
   with
   | [ Signal.Initialized 1 ] -> ()
   | [ Signal.Initialized 1; Signal.Initialized 1 ] ->
       Alcotest.fail "interrupted sent wakeup was delivered twice"
   | _ -> Alcotest.fail "expected one initialized stream update")

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

let test_stream_bridge_rejects_cross_domain_consumer () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok rt (Signal.Stream.observe signal) in
  run_ok rt Signal.stabilize;
  expect_die "cross-domain stream bridge consumer"
    (run_effect_in_foreign_domain
       (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect));
  run_ok rt (Signal.Observer.dispose observer)

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

let test_stream_bridge_multiple_bridges_dispose_independently () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let first_observer, first_stream = run_ok rt (Signal.Stream.observe signal) in
  let second_observer, second_stream = run_ok rt (Signal.Stream.observe signal) in
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 first_stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected first bridge initialization");
  (match
     run_ok rt (Eta_stream.Stream.take 1 second_stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected second bridge initialization");
  run_ok rt (Signal.Observer.dispose first_observer);
  (match run_ok rt (Eta_stream.run_collect first_stream) with
   | [] -> ()
   | _ -> Alcotest.fail "expected first bridge to close");
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "second observer remains alive" 2
    (run_ok rt (Signal.Observer.read second_observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 second_stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected second bridge changed update");
  run_ok rt (Signal.Observer.dispose second_observer)

let test_stream_bridge_invalidated_scope_fails_stream () =
  with_runtime @@ fun rt ->
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
    run_ok rt (Signal.Observer.observe selected (fun _ -> Effect.unit))
  in
  run_ok rt Signal.stabilize;
  let branch =
    match !captured with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch signal"
  in
  let branch_observer, stream = run_ok rt (Signal.Stream.observe branch) in
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected branch stream initialization");
  run_ok rt (Signal.Var.set use_branch false);
  run_ok rt Signal.stabilize;
  expect_fail "invalidated branch stream" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Eta_stream.run_collect stream)));
  expect_fail "branch observer invalidated" (( = ) `Invalid_scope)
    (Eta_eio.Runtime.run rt (widen (Signal.Observer.read branch_observer)));
  Alcotest.(check int) "selected switched" 2
    (run_ok rt (Signal.Observer.read selected_observer));
  run_ok rt (Signal.Observer.dispose selected_observer)

let test_stream_bridge_equal_suppresses_updates () =
  with_runtime_and_switch @@ fun sw rt ->
  let fresh_a () = Bytes.to_string (Bytes.of_string "a") in
  let source = Signal.Var.create (fresh_a ()) in
  let signal = Signal.Var.watch source in
  let observer, stream =
    run_ok rt (Signal.Stream.observe ~equal:String.equal signal)
  in
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized "a" ] -> ()
   | _ -> Alcotest.fail "expected initialized stream update");
  let next =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt
          (widen (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
  in
  run_ok rt (Signal.Var.set source (fresh_a ()));
  run_ok rt Signal.stabilize;
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool) "equal update did not emit" false
    (Eio.Promise.is_resolved next);
  run_ok rt (Signal.Var.set source "b");
  run_ok rt Signal.stabilize;
  (match
     expect_exit_ok "stream equal changed update" (Eio.Promise.await_exn next)
   with
   | [ Signal.Changed { old_value = "a"; new_value = "b" } ] -> ()
   | _ -> Alcotest.fail "expected changed stream update after unequal value");
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_bridge_full_queue_does_not_block () =
  with_runtime_and_switch @@ fun sw rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    run_ok rt (Signal.Stream.observe ~capacity:1 signal)
  in
  let later_events = ref [] in
  let later_observer =
    run_ok rt (Signal.Observer.observe signal (record_observer later_events))
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
    "stabilization does not wait for bridge capacity" true
    (Eio.Promise.is_resolved stabilizer);
  ignore
    (expect_exit_ok "full bridge stabilize"
       (Eio.Promise.await_exn stabilizer)
      : unit);
  (match List.rev !later_events with
   | [
    Signal.Initialized 1;
    Signal.Changed { old_value = 1; new_value = 2 };
   ] ->
       ()
   | _ -> Alcotest.fail "expected later observer to run behind full bridge");
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update");
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected later changed stream update after drop");
  run_ok rt (Signal.Observer.dispose observer);
  run_ok rt (Signal.Observer.dispose later_observer)

let test_stream_bridge_drop_callback_reports_loss () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let drops = ref [] in
  let before = run_ok rt (Signal.stats ()) in
  let observer, stream =
    run_ok rt
      (Signal.Stream.observe ~capacity:1
         ~on_drop:(fun update -> drops := update :: !drops)
         signal)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer snapshot advances after dropped update" 2
    (run_ok rt (Signal.Observer.read observer));
  (match List.rev !drops with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected dropped stream update to be reported");
  let after_drop = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "stats reports stream bridge drop"
    (before.Signal.stream_bridge_drop_count + 1)
    after_drop.Signal.stream_bridge_drop_count;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected buffered initial update");
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  (match List.rev !drops with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "drop callback should not run for delivered update");
  let after_delivery = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "delivered update does not increment drop stats"
    after_drop.Signal.stream_bridge_drop_count
    after_delivery.Signal.stream_bridge_drop_count;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected delivered update after draining");
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_bridge_interrupted_drop_callback_does_not_duplicate () =
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

let test_stream_bridge_drop_callback_failure_does_not_count_retry () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let fail_drop = ref true in
  let before = run_ok rt (Signal.stats ()) in
  let observer, stream =
    run_ok rt
      (Signal.Stream.observe ~capacity:1
         ~on_drop:(fun _update ->
           if !fail_drop then (
             fail_drop := false;
             failwith "drop hook failure"))
         signal)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  expect_die "drop hook failure"
    (Eta_eio.Runtime.run rt (widen Signal.stabilize));
  let after_failed_drop = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "failed drop is not final loss"
    before.Signal.stream_bridge_drop_count
    after_failed_drop.Signal.stream_bridge_drop_count;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected buffered initial update");
  run_ok rt Signal.stabilize;
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected retried update to be delivered");
  let after_retry = run_ok rt (Signal.stats ()) in
  Alcotest.(check int) "delivered retry does not count as drop"
    before.Signal.stream_bridge_drop_count
    after_retry.Signal.stream_bridge_drop_count;
  run_ok rt (Signal.Observer.dispose observer)

let test_stream_bridge_full_queue_dispose_closes_without_waiting () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    run_ok rt (Signal.Stream.observe ~capacity:1 signal)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer snapshot advances while bridge full" 2
    (run_ok rt (Signal.Observer.read observer));
  run_ok rt (Signal.Observer.dispose observer);
  (match run_ok rt (Eta_stream.run_collect stream) with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected buffered update to drain after dispose")

let test_stream_bridge_full_queue_failure_releases_phase () =
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

let test_stream_bridge_repeated_full_queue_keeps_lane () =
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream =
    run_ok rt (Signal.Stream.observe ~capacity:1 signal)
  in
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 2);
  run_ok rt Signal.stabilize;
  run_ok rt (Signal.Var.set source 3);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "observer snapshot advances through dropped updates" 3
    (run_ok rt (Signal.Observer.read observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update after drops");
  run_ok rt (Signal.Var.set source 4);
  run_ok rt Signal.stabilize;
  Alcotest.(check int) "graph lane remains available" 4
    (run_ok rt (Signal.Observer.read observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 3; new_value = 4 } ] -> ()
   | _ -> Alcotest.fail "expected later changed stream update");
  run_ok rt (Signal.Observer.dispose observer);
  (match run_ok rt (Eta_stream.run_collect stream) with
   | [] -> ()
   | _ -> Alcotest.fail "expected stream to close after dispose")

let () =
  Alcotest.run "eta_signal"
    [
      ( "core",
        [
          Alcotest.test_case "error pretty printers are clear" `Quick
            test_error_pretty_printers_are_clear;
          Alcotest.test_case "observer initializes on stabilize" `Quick
            test_observer_initializes_on_stabilize;
          Alcotest.test_case "observe after stabilize and dispose clears graph"
            `Quick test_observe_after_stabilization_and_disposal_clears_graph;
          Alcotest.test_case "observer unsafe read reports invalid state"
            `Quick test_observer_unsafe_read_exn_reports_invalid_state;
          Alcotest.test_case "manual stabilization coalesces sets" `Quick
            test_manual_stabilization_coalesces_sets;
          Alcotest.test_case "functor instances stabilize independently" `Quick
            test_functor_instances_stabilize_independently;
          Alcotest.test_case "graph rejects cross-domain synchronous APIs" `Quick
            test_graph_rejects_cross_domain_synchronous_apis;
          Alcotest.test_case "graph rejects registered worker context" `Quick
            test_graph_rejects_registered_worker_context;
          Alcotest.test_case "graph rejects cross-domain effectful APIs" `Quick
            test_graph_rejects_cross_domain_effectful_apis;
          Alcotest.test_case "diamond recomputes shared node once" `Quick
            test_diamond_recomputes_shared_node_once;
          Alcotest.test_case "diamond observers see glitch-free snapshots"
            `Quick test_diamond_observers_see_glitch_free_snapshots;
          Alcotest.test_case "recompute order is topological" `Quick
            test_recompute_order_is_topological;
          Alcotest.test_case "n-ary maps, both, and all" `Quick
            test_n_ary_maps_both_and_all;
          Alcotest.test_case "map arity matrix initializes and coalesces"
            `Quick test_map_arity_matrix_initializes_and_coalesces;
          Alcotest.test_case "map invariants repeated children and cutoff"
            `Quick test_map_invariants_repeated_children_cutoff_and_final_values;
          Alcotest.test_case "cutoff suppresses downstream recompute" `Quick
            test_cutoff_suppresses_downstream_recompute;
          Alcotest.test_case
            "unnecessary derived recomputes after dependency change" `Quick
            test_unnecessary_derived_recomputes_after_dependency_change;
          Alcotest.test_case
            "newly necessary derived chain refreshes dependency versions" `Quick
            test_newly_necessary_derived_chain_refreshes_dependency_versions;
          Alcotest.test_case "source equality suppresses propagation" `Quick
            test_source_equality_suppresses_graph_propagation;
          Alcotest.test_case "default cutoff is physical equality" `Quick
            test_default_cutoff_is_physical_equality;
          Alcotest.test_case "derived default cutoff is physical equality"
            `Quick test_derived_default_cutoff_is_physical_equality;
          Alcotest.test_case
            "structural cutoff suppresses fresh equal derived values" `Quick
            test_structural_cutoff_suppresses_fresh_equal_derived_values;
          Alcotest.test_case "physical cutoff suppresses in-place mutation"
            `Quick test_default_physical_cutoff_suppresses_in_place_mutation;
          Alcotest.test_case "observer equality is observer-local" `Quick
            test_observer_equality_suppresses_only_that_observer;
          Alcotest.test_case "observer callbacks run in registration order"
            `Quick
            test_observer_callbacks_run_in_registration_order;
          Alcotest.test_case "observer ordering across graph branches" `Quick
            test_observer_ordering_across_graph_branches_is_deterministic;
          Alcotest.test_case "observer callbacks read consistent snapshot"
            `Quick test_observer_callbacks_read_consistent_published_snapshot;
          Alcotest.test_case "observer dispose skips collected event" `Quick
            test_observer_dispose_during_callback_skips_collected_event;
          Alcotest.test_case "observer dispose after active check skips callback"
            `Quick test_observer_dispose_after_active_check_skips_callback;
          Alcotest.test_case "observer registration skips callbacks until returned"
            `Quick test_observer_registration_skips_callbacks_until_returned;
          Alcotest.test_case
            "observer observe invalidated after activation fails" `Quick
            test_observer_observe_invalidated_after_activation_fails;
          Alcotest.test_case "bind detaches old dependency" `Quick
            test_bind_detaches_old_dependency;
          Alcotest.test_case
            "bind switches after unnecessary source change" `Quick
            test_bind_switches_after_unnecessary_source_change;
          Alcotest.test_case "bind invalidates old scope" `Quick
            test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes;
          Alcotest.test_case "bind invalidated var watchers detach" `Quick
            test_bind_invalidated_var_watchers_detach_from_sources;
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
          Alcotest.test_case "commit skips invalidated staged entries" `Quick
            test_commit_skips_invalidated_staged_entries;
          Alcotest.test_case "dynamic signal rewires and cycle" `Quick
            test_dynamic_signal_rewires_and_cycle_preserves_snapshot;
          Alcotest.test_case "dynamic list bind switches dependency set" `Quick
            test_dynamic_list_bind_switches_dependency_set;
          Alcotest.test_case "bind branch churn releases inactive scopes" `Quick
            test_bind_branch_churn_releases_inactive_scopes;
          Alcotest.test_case "nested bind matches map3 and recreates scopes"
            `Quick test_nested_bind_sum_matches_map3_and_recreates_rhs_scopes;
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
          Alcotest.test_case "observer phase multiple sets publish final value"
            `Quick test_observer_phase_multiple_sets_publish_final_next_value;
          Alcotest.test_case "observer read during callback" `Quick
            test_observer_read_during_callback_sees_current_snapshot;
          Alcotest.test_case "observer read does not force recompute" `Quick
            test_observer_read_does_not_force_recompute;
          Alcotest.test_case "dispose removes demand" `Quick
            test_dispose_removes_demand;
          Alcotest.test_case "dispose before initialization removes demand"
            `Quick
            test_dispose_before_initialization_removes_demand;
          Alcotest.test_case "dispose unlinks observer from graph" `Quick
            test_dispose_unlinks_observer_from_graph;
          Alcotest.test_case "pure failure does not publish snapshot" `Quick
            test_pure_failure_does_not_publish_partial_snapshot_and_can_retry;
          Alcotest.test_case "version overflow does not publish snapshot" `Quick
            test_signal_version_overflow_does_not_publish_partial_snapshot;
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
          Alcotest.test_case
            "observer effect ambiguous node creation typed failure" `Quick
            test_ambiguous_node_creation_during_observer_effect_is_typed_failure;
          Alcotest.test_case "observer failure fails stabilize" `Quick
            test_observer_failure_fails_stabilize;
          Alcotest.test_case "observer typed failure retries" `Quick
            test_observer_typed_failure_retries_after_flag_fixed;
          Alcotest.test_case "observer failed delivery coalesces reverted value"
            `Quick test_observer_failed_delivery_coalesces_reverted_value;
          Alcotest.test_case "observer failure is fail-fast" `Quick
            test_observer_failure_is_fail_fast;
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
          Alcotest.test_case "observer read waits for graph lane" `Quick
            test_observer_read_waits_for_graph_lane;
          Alcotest.test_case "time interval construction waits for graph lane"
            `Quick test_time_interval_construction_waits_for_graph_lane;
          Alcotest.test_case
            "observer delivery acknowledgement uses graph lane" `Quick
            test_observer_delivery_acknowledgement_uses_graph_lane;
          Alcotest.test_case "stats and dot introspection" `Quick
            test_stats_and_dot_are_read_only;
          Alcotest.test_case
            "stats split snapshot commit from callback delivery" `Quick
            test_stats_split_snapshot_commit_from_callback_delivery;
          Alcotest.test_case "repeated dependencies are stored once" `Quick
            test_repeated_dependencies_are_stored_once;
          Alcotest.test_case "to_dot deduplicates repeated dependency edges"
            `Quick test_to_dot_deduplicates_repeated_dependency_edges;
          Alcotest.test_case "to_dot debug options expose hidden state" `Quick
            test_to_dot_debug_options_expose_hidden_state;
          Alcotest.test_case "dead nodes and dot include pruned invalid nodes"
            `Quick test_dead_nodes_and_dot_include_pruned_invalid_nodes;
          Alcotest.test_case
            "dead node count ignores retained invalid non-tombstones" `Quick
            test_dead_node_count_ignores_retained_invalid_non_tombstones;
          Alcotest.test_case "deterministic model matches dynamic graph" `Quick
            test_deterministic_model_matches_small_dynamic_graph;
          Alcotest.test_case "randomized model matches dynamic graph" `Quick
            test_randomized_model_matches_small_signal_graph;
          Alcotest.test_case "fanout fanin cutoff and partial disposal" `Quick
            test_fanout_fanin_cutoff_and_partial_disposal;
          Alcotest.test_case "time interval starts on observe" `Quick
            test_time_interval_starts_only_when_observed;
          Alcotest.test_case "time interval needs stabilization" `Quick
            test_time_interval_requires_explicit_stabilization;
          Alcotest.test_case "time interval overflow saturates" `Quick
            test_time_interval_overflow_saturates;
          Alcotest.test_case "time inactive timer stop is idempotent" `Quick
            test_time_inactive_timer_stop_is_idempotent;
          Alcotest.test_case "time timer generation overflow fails loudly"
            `Quick test_time_timer_generation_overflow_fails_loudly;
          Alcotest.test_case "time large clock jump catches up explicitly"
            `Quick test_time_large_clock_jump_catches_up_without_auto_stabilize;
          Alcotest.test_case "time interval catches up after late sleep" `Quick
            test_time_interval_catches_up_after_late_sleep;
          Alcotest.test_case "time step catches up after late sleep" `Quick
            test_time_step_catches_up_after_late_sleep;
          Alcotest.test_case "time step catch-up yields between batches" `Quick
            test_time_catch_up_yields_between_batches;
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
          Alcotest.test_case "time after saturates overflowing deadline"
            `Quick test_time_after_saturates_overflowing_deadline;
          Alcotest.test_case "time absolute deadline" `Quick
            test_time_absolute_deadline;
          Alcotest.test_case "time step function" `Quick
            test_time_step_function;
          Alcotest.test_case "time step defect logs diagnostic" `Quick
            test_time_step_defect_logs_daemon_diagnostic_and_restarts;
          Alcotest.test_case "time validation errors" `Quick
            test_time_validation_errors;
          Alcotest.test_case "stream observe timer initialization race" `Quick
            test_stream_observe_timer_initialization_race;
          Alcotest.test_case "observe invalidated before return fails" `Quick
            test_observe_invalidated_before_return_fails;
          Alcotest.test_case "stream bridge interrupted publish does not duplicate"
            `Quick test_stream_bridge_interrupted_publish_does_not_duplicate;
          Alcotest.test_case
            "stream bridge interrupted sent wakeup does not duplicate" `Quick
            test_stream_bridge_interrupted_sent_wakeup_does_not_duplicate;
          Alcotest.test_case "stream bridge emits after stabilize" `Quick
            test_stream_bridge_emits_after_stabilize;
          Alcotest.test_case "stream bridge validates capacity" `Quick
            test_stream_bridge_validates_capacity;
          Alcotest.test_case "stream bridge rejects cross-domain consumer"
            `Quick test_stream_bridge_rejects_cross_domain_consumer;
          Alcotest.test_case "stream bridge closes on dispose" `Quick
            test_stream_bridge_closes_on_observer_dispose;
          Alcotest.test_case "stream bridge take keeps observer" `Quick
            test_stream_bridge_take_does_not_dispose_observer;
          Alcotest.test_case "stream bridge multiple bridges dispose separately"
            `Quick test_stream_bridge_multiple_bridges_dispose_independently;
          Alcotest.test_case "stream bridge invalidated scope fails stream"
            `Quick test_stream_bridge_invalidated_scope_fails_stream;
          Alcotest.test_case "stream bridge equality suppresses" `Quick
            test_stream_bridge_equal_suppresses_updates;
          Alcotest.test_case "stream bridge full queue does not block"
            `Quick test_stream_bridge_full_queue_does_not_block;
          Alcotest.test_case "stream bridge drop callback reports loss"
            `Quick test_stream_bridge_drop_callback_reports_loss;
          Alcotest.test_case
            "stream bridge interrupted drop callback does not duplicate" `Quick
            test_stream_bridge_interrupted_drop_callback_does_not_duplicate;
          Alcotest.test_case
            "stream bridge failed drop callback does not count retry" `Quick
            test_stream_bridge_drop_callback_failure_does_not_count_retry;
          Alcotest.test_case "stream bridge full queue dispose closes"
            `Quick test_stream_bridge_full_queue_dispose_closes_without_waiting;
          Alcotest.test_case
            "stream bridge full queue plus observer failure releases phase"
            `Quick test_stream_bridge_full_queue_failure_releases_phase;
          Alcotest.test_case "stream bridge dispose during observer phase"
            `Quick
            test_stream_bridge_dispose_during_observer_phase_is_deterministic;
          Alcotest.test_case "stream bridge repeated full queue keeps lane"
            `Quick test_stream_bridge_repeated_full_queue_keeps_lane;
        ] );
    ]
