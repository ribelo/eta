module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run runtime eff = Eta.Runtime.run runtime (widen eff)

let run_ok runtime eff =
  match run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let expect_fail label pred = function
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let expect_die label = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected defect, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected defect, got Ok" label

let signal_graph_context_message_prefix =
  "Eta_signal: signal graph APIs must be called"

let is_signal_graph_context_message message =
  String.starts_with ~prefix:signal_graph_context_message_prefix message

let signal_test_worker_context_active = ref false

let () =
  Eta.Runtime_contract.register_worker_context_probe (fun () ->
      !signal_test_worker_context_active)

let domain_spawn f =
  (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"]) f

let run_in_foreign_domain f =
  let domain = domain_spawn f in
  Domain.join domain

let run_effect_in_foreign_domain eff =
  run_in_foreign_domain @@ fun () ->
  Eta_test.with_test_clock @@ fun _sw _clock runtime -> run runtime eff

let expect_cross_domain_signal_context_failure label f =
  match
    run_in_foreign_domain @@ fun () ->
    try Ok (f (); false) with
    | Invalid_argument message -> Ok (is_signal_graph_context_message message)
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
    when is_signal_graph_context_message message ->
      ()
  | exception exn ->
      Alcotest.failf "%s: expected signal graph context failure, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected signal graph context failure" label

let with_signal_test_worker_context f =
  signal_test_worker_context_active := true;
  Fun.protect
    ~finally:(fun () -> signal_test_worker_context_active := false)
    f

let render pp value = Format.asprintf "%a" pp value

let check_render label pp value expected =
  Alcotest.(check string) label expected (render pp value)

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

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

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 200

let with_logger_test_clock f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let logger = Eta.Logger.in_memory () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  f sw clock runtime logger

let test_error_pretty_printers_are_clear () =
  let module S = Eta_signal.Make (Observer_error) () in
  check_render "ambiguous scope" S.pp_graph_error `Ambiguous_scope
    "ambiguous dynamic scope";
  check_render "cycle" S.pp_graph_error `Cycle "cycle detected";
  check_render "invalid scope" S.pp_graph_error `Invalid_scope
    "invalid dynamic scope";
  check_render "reentrant stabilization" S.pp_graph_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "reentrant update" S.pp_graph_error `Reentrant_update
    "same-variable effectful update reentry";
  check_render "disposed observer" S.pp_observer_read_error
    `Disposed_observer "disposed observer";
  check_render "invalid observer scope" S.pp_observer_read_error
    `Invalid_scope "invalid dynamic scope";
  check_render "no current observer value" S.pp_observer_read_error
    `No_current_value "no current observer value";
  check_render "uninitialized observer" S.pp_observer_read_error
    `Uninitialized_observer "uninitialized observer";
  check_render "stabilize graph error" S.pp_stabilize_error
    `Reentrant_stabilization "reentrant stabilization";
  check_render "stabilize observer error" S.pp_stabilize_error
    (`Observer_error `Observer_failed) "observer callback failed: observer failed";
  check_render "deadline overflow" S.pp_time_error `Deadline_overflow
    "deadline arithmetic overflow";
  check_render "invalid interval" S.pp_time_error `Invalid_interval
    "invalid interval";
  check_render "past deadline" S.pp_time_error `Past_deadline
    "deadline is in the past";
  check_render "stream graph error" S.pp_stream_error `Cycle
    "cycle detected";
  check_render "invalid stream capacity" S.pp_stream_error
    `Invalid_capacity "stream bridge capacity must be positive"

let test_graph_rejects_cross_domain_synchronous_apis () =
  let module S = Eta_signal.Make (Observer_error) () in
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  expect_cross_domain_signal_context_failure "cross-domain Var.create" (fun () ->
      ignore (S.Var.create 0 : int S.Var.t));
  expect_cross_domain_signal_context_failure "cross-domain Var.value" (fun () ->
      ignore (S.Var.value source : int));
  expect_cross_domain_signal_context_failure "cross-domain Var.watch" (fun () ->
      ignore (S.Var.watch source : int S.signal));
  expect_cross_domain_signal_context_failure "cross-domain const" (fun () ->
      ignore (S.const 0 : int S.signal));
  expect_cross_domain_signal_context_failure "cross-domain map" (fun () ->
      ignore (S.map (fun value -> value + 1) signal : int S.signal))

let test_graph_rejects_registered_worker_context () =
  let module S = Eta_signal.Make (Observer_error) () in
  let source = S.Var.create 1 in
  with_signal_test_worker_context @@ fun () ->
  expect_signal_context_failure "worker-context Var.value" (fun () ->
      ignore (S.Var.value source : int));
  expect_signal_context_failure "worker-context const" (fun () ->
      ignore (S.const 0 : int S.signal))

let test_graph_rejects_cross_domain_effectful_apis () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  expect_die "cross-domain Var.set"
    (run_effect_in_foreign_domain (S.Var.set source 2));
  expect_die "cross-domain Observer.observe"
    (run_effect_in_foreign_domain
       (S.Observer.observe signal (fun _ -> E.unit)));
  expect_die "cross-domain Observer.read"
    (run_effect_in_foreign_domain (S.Observer.read observer));
  expect_die "cross-domain Observer.dispose"
    (run_effect_in_foreign_domain (S.Observer.dispose observer));
  expect_die "cross-domain stats"
    (run_effect_in_foreign_domain (S.stats ()));
  expect_die "cross-domain to_dot"
    (run_effect_in_foreign_domain (S.to_dot ()));
  expect_die "cross-domain stabilize"
    (run_effect_in_foreign_domain S.stabilize);
  Alcotest.(check int) "cross-domain set did not mutate source" 1
    (S.Var.value source);
  run_ok runtime (S.Observer.dispose observer)

let test_n_ary_maps_both_and_all () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let v1 = S.Var.create 1 in
  let v2 = S.Var.create 2 in
  let v3 = S.Var.create 3 in
  let v4 = S.Var.create 4 in
  let v5 = S.Var.create 5 in
  let v6 = S.Var.create 6 in
  let v7 = S.Var.create 7 in
  let v8 = S.Var.create 8 in
  let v9 = S.Var.create 9 in
  let s1 = S.Var.watch v1 in
  let s2 = S.Var.watch v2 in
  let s3 = S.Var.watch v3 in
  let s4 = S.Var.watch v4 in
  let s5 = S.Var.watch v5 in
  let s6 = S.Var.watch v6 in
  let s7 = S.Var.watch v7 in
  let s8 = S.Var.watch v8 in
  let s9 = S.Var.watch v9 in
  let sum3 = S.map3 (fun a b c -> a + b + c) s1 s2 s3 in
  let sum4 = S.map4 (fun a b c d -> a + b + c + d) s1 s2 s3 s4 in
  let sum5 =
    S.map5 (fun a b c d e -> a + b + c + d + e) s1 s2 s3 s4 s5
  in
  let sum6 =
    S.map6
      (fun a b c d e f -> a + b + c + d + e + f)
      s1 s2 s3 s4 s5 s6
  in
  let sum7 =
    S.map7
      (fun a b c d e f g -> a + b + c + d + e + f + g)
      s1 s2 s3 s4 s5 s6 s7
  in
  let sum8 =
    S.map8
      (fun a b c d e f g h -> a + b + c + d + e + f + g + h)
      s1 s2 s3 s4 s5 s6 s7 s8
  in
  let sum9 =
    S.map9
      (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
      s1 s2 s3 s4 s5 s6 s7 s8 s9
  in
  let pair_sum = S.both s1 s2 |> S.map (fun (a, b) -> a + b) in
  let all_sum = S.all [ s1; s2; s3 ] |> S.map (List.fold_left ( + ) 0) in
  let combined =
    S.all [ sum3; sum4; sum5; sum6; sum7; sum8; sum9; pair_sum; all_sum ]
    |> S.map (List.fold_left ( + ) 0)
  in
  let observer = run_ok runtime (S.Observer.observe combined (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "initial combined n-ary value" 170
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set v9 10);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "map9 updates through all" 171
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set v1 11);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "shared source updates all combinators" 261
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Observer.dispose observer)

let test_map_arity_matrix_initializes_and_coalesces () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let v1 = S.Var.create 1 in
  let v2 = S.Var.create 2 in
  let v3 = S.Var.create 3 in
  let v4 = S.Var.create 4 in
  let v5 = S.Var.create 5 in
  let v6 = S.Var.create 6 in
  let v7 = S.Var.create 7 in
  let v8 = S.Var.create 8 in
  let v9 = S.Var.create 9 in
  let s1 = S.Var.watch v1 in
  let s2 = S.Var.watch v2 in
  let s3 = S.Var.watch v3 in
  let s4 = S.Var.watch v4 in
  let s5 = S.Var.watch v5 in
  let s6 = S.Var.watch v6 in
  let s7 = S.Var.watch v7 in
  let s8 = S.Var.watch v8 in
  let s9 = S.Var.watch v9 in
  let mapped =
    [
      S.const 10 |> S.map (fun n -> n + 1);
      S.map (fun a -> a) s1;
      S.map2 (fun a b -> a + b) s1 s2;
      S.map3 (fun a b c -> a + b + c) s1 s2 s3;
      S.map4 (fun a b c d -> a + b + c + d) s1 s2 s3 s4;
      S.map5 (fun a b c d e -> a + b + c + d + e) s1 s2 s3 s4 s5;
      S.map6
        (fun a b c d e f -> a + b + c + d + e + f)
        s1 s2 s3 s4 s5 s6;
      S.map7
        (fun a b c d e f g -> a + b + c + d + e + f + g)
        s1 s2 s3 s4 s5 s6 s7;
      S.map8
        (fun a b c d e f g h -> a + b + c + d + e + f + g + h)
        s1 s2 s3 s4 s5 s6 s7 s8;
      S.map9
        (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
        s1 s2 s3 s4 s5 s6 s7 s8 s9;
    ]
  in
  let events = ref [] in
  let observer =
    run_ok runtime (S.Observer.observe (S.all mapped) (record events))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check (list int))
    "map arities initialize"
    [ 11; 1; 3; 6; 10; 15; 21; 28; 36; 45 ]
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set v1 100);
  run_ok runtime (S.Var.set v1 101);
  run_ok runtime (S.Var.set v9 90);
  run_ok runtime S.stabilize;
  Alcotest.(check (list int))
    "map arities publish final coalesced source values"
    [ 11; 101; 103; 106; 110; 115; 121; 128; 136; 226 ]
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "one initialization and one changed event" 2
    (List.length !events);
  run_ok runtime (S.Observer.dispose observer)

let test_map_invariants_repeated_children_cutoff_and_final_values () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let shared_calls = ref 0 in
  let shared =
    S.Var.watch source
    |> S.map (fun value ->
           incr shared_calls;
           value)
  in
  let repeated_map2 = S.map2 ( + ) shared shared in
  let repeated_map9 =
    S.map9
      (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
      shared shared shared shared shared shared shared shared shared
  in
  let cutoff_source = S.Var.create 0 in
  let cutoff_child =
    S.Var.watch cutoff_source |> S.map ~equal:Int.equal (fun value -> value mod 2)
  in
  let cutoff_calls = ref 0 in
  let cutoff_map9 =
    S.map9
      (fun a b c d e f g h i ->
        incr cutoff_calls;
        a + b + c + d + e + f + g + h + i)
      cutoff_child cutoff_child cutoff_child cutoff_child cutoff_child
      cutoff_child cutoff_child cutoff_child cutoff_child
  in
  let left = S.Var.create 1 in
  let right = S.Var.create 10 in
  let map2_calls = ref 0 in
  let two_inputs =
    S.map2
      (fun a b ->
        incr map2_calls;
        a + b)
      (S.Var.watch left) (S.Var.watch right)
  in
  let combined = S.all [ repeated_map2; repeated_map9; cutoff_map9; two_inputs ] in
  let first_observer =
    run_ok runtime (S.Observer.observe combined (fun _ -> E.unit))
  in
  let second_observer =
    run_ok runtime (S.Observer.observe combined (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let after_initial = run_ok runtime (S.stats ()) in
  Alcotest.(check (list int)) "initial invariant values" [ 2; 9; 0; 11 ]
    (run_ok runtime (S.Observer.read first_observer));
  Alcotest.(check int) "repeated child recomputed once initially" 1 !shared_calls;
  Alcotest.(check int) "map2 computed once initially" 1 !map2_calls;
  run_ok runtime (S.Var.set source 2);
  run_ok runtime (S.Var.set cutoff_source 2);
  run_ok runtime (S.Var.set left 2);
  run_ok runtime (S.Var.set right 20);
  run_ok runtime S.stabilize;
  Alcotest.(check (list int))
    "updated invariant values" [ 4; 18; 0; 22 ]
    (run_ok runtime (S.Observer.read first_observer));
  Alcotest.(check int) "repeated child recomputed once after update" 2
    !shared_calls;
  Alcotest.(check int) "child cutoff suppressed map9 recompute" 1 !cutoff_calls;
  Alcotest.(check int) "two changed inputs recomputed once" 2 !map2_calls;
  run_ok runtime (S.Observer.dispose first_observer);
  let after_partial_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "partial disposal keeps shared graph necessary"
    after_initial.S.necessary_node_count
    after_partial_dispose.S.necessary_node_count;
  run_ok runtime (S.Var.set source 3);
  run_ok runtime (S.Var.set cutoff_source 3);
  run_ok runtime S.stabilize;
  Alcotest.(check (list int))
    "remaining observer sees post-disposal update" [ 6; 27; 9; 22 ]
    (run_ok runtime (S.Observer.read second_observer));
  Alcotest.(check int) "cutoff fanin recomputes when child changes" 2
    !cutoff_calls;
  run_ok runtime (S.Observer.dispose second_observer);
  let after_final_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check bool) "final disposal releases shared graph" true
    (after_final_dispose.S.necessary_node_count
     < after_partial_dispose.S.necessary_node_count)

let test_repeated_dependencies_are_deduplicated_in_diagnostics () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let base = S.Var.watch source in
  let repeated = S.map2 (fun left _right -> left) base base in
  let observer =
    run_ok runtime (S.Observer.observe repeated (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let options : S.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = false;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = false;
    }
  in
  let diagnostic_dot = run_ok runtime (S.to_dot ~options ()) in
  Alcotest.(check int) "map2 stores one dependency" 1
    (count_occurrences diagnostic_dot "dependencies=1");
  Alcotest.(check int) "source stores one dependent" 1
    (count_occurrences diagnostic_dot "dependents=1");
  Alcotest.(check int) "map2 does not store duplicate dependencies" 0
    (count_occurrences diagnostic_dot "dependencies=2");
  Alcotest.(check int) "source does not store duplicate dependents" 0
    (count_occurrences diagnostic_dot "dependents=2");
  let necessary_dot = run_ok runtime (S.to_dot ()) in
  Alcotest.(check int) "to_dot renders repeated dependency edge once" 1
    (count_occurrences necessary_dot " -> ");
  run_ok runtime (S.Observer.dispose observer)

let test_explicit_stabilization_boundary () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let derived = S.Var.watch source |> S.map (fun value -> value * 10) in
  let updates = ref [] in
  let observer = run_ok runtime (S.Observer.observe derived (record updates)) in
  expect_fail "read before first stabilization" (( = ) `Uninitialized_observer)
    (run runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 2);
  Alcotest.(check int) "set does not deliver callbacks" 0 (List.length !updates);
  expect_fail "set does not initialize observer" (( = ) `Uninitialized_observer)
    (run runtime (S.Observer.read observer));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "first stabilized value" 20
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 3);
  Alcotest.(check int) "read stays on committed snapshot" 20
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "second set still has no callback" 1 (List.length !updates);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "second stabilized value" 30
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !updates with
   | [ S.Initialized 20; S.Changed { old_value = 20; new_value = 30 } ] -> ()
   | _ -> Alcotest.fail "unexpected explicit stabilization updates");
  run_ok runtime (S.Observer.dispose observer)

let test_functor_instances_stabilize_independently () =
  let module First = Eta_signal.Make (Observer_error) () in
  let module Second = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let first_source = First.Var.create 1 in
  let second_source = Second.Var.create 10 in
  let first_events = ref 0 in
  let second_events = ref 0 in
  let first_observer =
    run_ok runtime
      (First.Observer.observe (First.Var.watch first_source) (fun _ ->
           E.sync (fun () -> incr first_events)))
  in
  let second_observer =
    run_ok runtime
      (Second.Observer.observe (Second.Var.watch second_source) (fun _ ->
           E.sync (fun () -> incr second_events)))
  in
  run_ok runtime First.stabilize;
  Alcotest.(check int) "first graph initialized" 1
    (run_ok runtime (First.Observer.read first_observer));
  expect_fail "second graph remains uninitialized"
    (( = ) `Uninitialized_observer)
    (run runtime (Second.Observer.read second_observer));
  run_ok runtime (First.Var.set first_source 2);
  run_ok runtime (Second.Var.set second_source 20);
  run_ok runtime First.stabilize;
  Alcotest.(check int) "first graph changed" 2
    (run_ok runtime (First.Observer.read first_observer));
  expect_fail "second graph is still uninitialized"
    (( = ) `Uninitialized_observer)
    (run runtime (Second.Observer.read second_observer));
  run_ok runtime Second.stabilize;
  Alcotest.(check int) "second graph initializes with latest source" 20
    (run_ok runtime (Second.Observer.read second_observer));
  Alcotest.(check int) "first graph event count" 2 !first_events;
  Alcotest.(check int) "second graph event count" 1 !second_events;
  run_ok runtime (First.Observer.dispose first_observer);
  run_ok runtime (Second.Observer.dispose second_observer)

let test_observer_read_does_not_force_recompute () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let recomputes = ref 0 in
  let signal =
    S.Var.watch source
    |> S.map (fun value ->
           incr recomputes;
           value)
  in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let after_stabilize = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set source 2);
  let before_read = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "read returns old stabilized snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  let after_read = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "observer read does not stabilize"
    before_read.S.pure_snapshot_commit_count
    after_read.S.pure_snapshot_commit_count;
  Alcotest.(check int) "observer read does not recompute"
    before_read.S.recompute_count after_read.S.recompute_count;
  Alcotest.(check int) "pending update was not recomputed by read" 1
    !recomputes;
  run_ok runtime S.stabilize;
  let after_second_stabilize = run_ok runtime (S.stats ()) in
  Alcotest.(check bool) "later stabilization recomputes" true
    (after_second_stabilize.S.recompute_count > after_read.S.recompute_count);
  Alcotest.(check int) "map recomputed by later stabilization" 2 !recomputes;
  Alcotest.(check bool) "stabilization count advanced" true
    (after_second_stabilize.S.pure_snapshot_commit_count
     > after_stabilize.S.pure_snapshot_commit_count);
  Alcotest.(check int) "observer sees new snapshot after stabilize" 2
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Observer.dispose observer)

let test_observer_graph_delivery_order_is_deterministic () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let check_events label expected events =
    Alcotest.(check (list string)) label expected (List.rev !events);
    events := []
  in
  let dispose_all observers =
    List.iter
      (fun observer -> run_ok runtime (S.Observer.dispose observer))
      observers
  in
  let check_dependency_order label registration_order =
    let source = S.Var.create 1 in
    let upstream =
      S.Var.watch source |> S.map (fun value -> value + 1)
    in
    let downstream = S.map (fun value -> value * 10) upstream in
    let independent =
      S.Var.watch source |> S.map (fun value -> -value)
    in
    let events = ref [] in
    let record label _update =
      E.sync (fun () -> events := label :: !events)
    in
    let observe = function
      | "upstream" -> S.Observer.observe upstream (record "upstream")
      | "downstream" ->
          S.Observer.observe downstream (record "downstream")
      | "independent" ->
          S.Observer.observe independent (record "independent")
      | unexpected ->
          Alcotest.failf "unexpected observer label %S" unexpected
    in
    let observers =
      List.map (fun name -> run_ok runtime (observe name)) registration_order
    in
    let expected = [ "upstream"; "downstream"; "independent" ] in
    run_ok runtime S.stabilize;
    check_events (label ^ " initial dependency order") expected events;
    run_ok runtime (S.Var.set source 2);
    run_ok runtime S.stabilize;
    check_events (label ^ " changed dependency order") expected events;
    dispose_all observers
  in
  check_dependency_order "creation registration"
    [ "upstream"; "downstream"; "independent" ];
  check_dependency_order "reverse dependency registration"
    [ "downstream"; "upstream"; "independent" ];
  check_dependency_order "reverse registration"
    [ "independent"; "downstream"; "upstream" ];

  let check_independent_order label registration_order =
    let source = S.Var.create 1 in
    let left = S.Var.watch source |> S.map (fun value -> value + 1) in
    let middle =
      S.Var.watch source |> S.map (fun value -> value + 2)
    in
    let right = S.Var.watch source |> S.map (fun value -> value + 3) in
    let events = ref [] in
    let record label _update =
      E.sync (fun () -> events := label :: !events)
    in
    let observe = function
      | "left" -> S.Observer.observe left (record "left")
      | "middle" -> S.Observer.observe middle (record "middle")
      | "right" -> S.Observer.observe right (record "right")
      | unexpected ->
          Alcotest.failf "unexpected observer label %S" unexpected
    in
    let observers =
      List.map (fun name -> run_ok runtime (observe name)) registration_order
    in
    let expected = [ "left"; "middle"; "right" ] in
    run_ok runtime S.stabilize;
    check_events (label ^ " initial independent order") expected events;
    run_ok runtime (S.Var.set source 2);
    run_ok runtime S.stabilize;
    check_events (label ^ " changed independent order") expected events;
    dispose_all observers
  in
  check_independent_order "independent creation registration"
    [ "left"; "middle"; "right" ];
  check_independent_order "independent reverse registration"
    [ "right"; "middle"; "left" ];
  check_independent_order "independent mixed registration"
    [ "middle"; "right"; "left" ];

  let source = S.Var.create 1 in
  let independent_source = S.Var.create 2 in
  let watched = S.Var.watch source in
  let independent = S.Var.watch independent_source in
  let events = ref [] in
  let record label _update =
    E.sync (fun () -> events := label :: !events)
  in
  let same_first =
    run_ok runtime (S.Observer.observe watched (record "same-1"))
  in
  let same_second =
    run_ok runtime (S.Observer.observe watched (record "same-2"))
  in
  let independent_observer =
    run_ok runtime (S.Observer.observe independent (record "independent"))
  in
  let observers = [ same_first; same_second; independent_observer ] in
  let expected = [ "same-1"; "same-2"; "independent" ] in
  run_ok runtime S.stabilize;
  check_events "same-signal initial observer order" expected events;
  run_ok runtime (S.Var.set independent_source 20);
  run_ok runtime (S.Var.set source 10);
  run_ok runtime S.stabilize;
  check_events "same-signal changed observer order" expected events;
  dispose_all observers

let test_observer_unsafe_read_exn_reports_invalid_state () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let observer =
    run_ok runtime (S.Observer.observe (S.Var.watch source) (fun _ -> E.unit))
  in
  Alcotest.check_raises "unsafe read before stabilize"
    (Invalid_argument "Eta_signal observer is not initialized")
    (fun () -> ignore (S.Observer.unsafe_read_exn observer : int));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "unsafe read stabilized value" 1
    (S.Observer.unsafe_read_exn observer);
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.check_raises "unsafe read after dispose"
    (Invalid_argument "Eta_signal observer is disposed")
    (fun () -> ignore (S.Observer.unsafe_read_exn observer : int))

let test_diagnostics_track_observation_and_disposal () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let check_stats_unchanged label expected actual =
    Alcotest.(check bool) label true (expected = actual)
  in
  run_ok runtime S.stabilize;
  let before = run_ok runtime (S.stats ()) in
  let before_dot_nodes =
    count_occurrences (run_ok runtime (S.to_dot ())) "[label="
  in
  let source = S.Var.create 1 in
  run_ok runtime (S.Var.set source 2);
  let signal = S.Var.watch source |> S.map (fun value -> value + 1) in
  let observer =
    run_ok runtime (S.Observer.observe signal (fun _ -> E.unit))
  in
  let after_observe = run_ok runtime (S.stats ()) in
  Alcotest.(check bool) "observe records necessary transition" true
    (after_observe.S.nodes_became_necessary
     > before.S.nodes_became_necessary);
  Alcotest.(check int) "observe increments active observer count"
    (before.S.active_observer_count + 1)
    after_observe.S.active_observer_count;
  Alcotest.(check bool) "observe after stabilization adds demand" true
    (after_observe.S.necessary_node_count > before.S.necessary_node_count);
  Alcotest.(check bool) "observe exposes live dirty nodes before stabilize"
    true
    (after_observe.S.live_dirty_node_count > before.S.live_dirty_node_count);
  let after_stats_read = run_ok runtime (S.stats ()) in
  check_stats_unchanged "stats is read-only" after_observe after_stats_read;
  run_ok runtime S.stabilize;
  let after_stabilize = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "observer after prior stabilization sees latest source"
    3
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "stabilization commits pure snapshot"
    (before.S.pure_snapshot_commit_count + 1)
    after_stabilize.S.pure_snapshot_commit_count;
  Alcotest.(check int) "stabilization delivers observer callbacks"
    (before.S.callback_delivery_count + 1)
    after_stabilize.S.callback_delivery_count;
  Alcotest.(check int) "stabilization keeps invalid observers explicit" 0
    after_stabilize.S.invalid_observer_count;
  Alcotest.(check int) "stabilization does not create dead nodes"
    before.S.dead_node_count after_stabilize.S.dead_node_count;
  Alcotest.(check bool) "stabilization records recomputation" true
    (after_stabilize.S.recompute_count > before.S.recompute_count);
  Alcotest.(check bool) "stabilization clears live dirty nodes" true
    (after_stabilize.S.live_dirty_node_count
     < after_observe.S.live_dirty_node_count);
  let dot_before_unobserved = run_ok runtime (S.to_dot ()) in
  Alcotest.(check bool) "to_dot returns diagnostics" true
    (String.length dot_before_unobserved > 0);
  let necessary_dot_nodes =
    count_occurrences dot_before_unobserved "[label="
  in
  let unobserved =
    S.Var.watch (S.Var.create 10) |> S.map (fun value -> value + 1)
  in
  ignore (Sys.opaque_identity unobserved);
  let before_dot = run_ok runtime (S.stats ()) in
  let dot = run_ok runtime (S.to_dot ()) in
  Alcotest.(check int) "to_dot ignores unobserved nodes" necessary_dot_nodes
    (count_occurrences dot "[label=");
  let after_dot = run_ok runtime (S.stats ()) in
  check_stats_unchanged "to_dot is read-only" before_dot after_dot;
  Alcotest.(check bool) "to_dot shows observed graph" true
    (count_occurrences (run_ok runtime (S.to_dot ())) "[label="
     > before_dot_nodes);
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime S.stabilize;
  let after_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "disposal returns active observer count to baseline"
    before.S.active_observer_count after_dispose.S.active_observer_count;
  Alcotest.(check bool) "disposal releases necessary graph" true
    (after_dispose.S.necessary_node_count
     < after_stabilize.S.necessary_node_count);
  Alcotest.(check bool) "disposal records unnecessary transition" true
    (after_dispose.S.nodes_became_unnecessary
     > after_stabilize.S.nodes_became_unnecessary);
  Alcotest.(check bool) "to_dot returns to baseline necessary graph" true
    (count_occurrences (run_ok runtime (S.to_dot ())) "[label="
     <= before_dot_nodes)

let test_diagnostic_dot_options_expose_public_metadata () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let observed =
    S.Var.watch source |> S.map (fun value -> value + 1)
  in
  let unobserved =
    S.Var.watch (S.Var.create 10) |> S.map (fun value -> value + 1)
  in
  let timer = run_ok runtime (S.Time.interval (Eta.Duration.ms 50)) in
  let branch = S.Var.create true in
  let scoped =
    S.bind (S.Var.watch branch) (fun enabled ->
        if enabled then S.const 1 else S.const 0)
  in
  let observer =
    run_ok runtime (S.Observer.observe observed (fun _ -> E.unit))
  in
  let timer_observer =
    run_ok runtime (S.Observer.observe timer (fun _ -> E.unit))
  in
  let scoped_observer =
    run_ok runtime (S.Observer.observe scoped (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 2);
  let necessary_dot = run_ok runtime (S.to_dot ()) in
  let debug_options : S.dot_options =
    {
      dot_scope = `All_valid;
      dot_observers = true;
      dot_timers = true;
      dot_state = true;
      dot_dynamic_scopes = true;
    }
  in
  let debug_dot =
    ignore (Sys.opaque_identity unobserved);
    run_ok runtime (S.to_dot ~options:debug_options ())
  in
  Alcotest.(check bool) "debug dot shows more than necessary graph" true
    (count_occurrences debug_dot "[label="
     > count_occurrences necessary_dot "[label=");
  Alcotest.(check bool) "debug dot shows observers" true
    (count_occurrences debug_dot "observer:" > 0);
  Alcotest.(check bool) "debug dot shows timer activity" true
    (count_occurrences debug_dot "timer_active=true" > 0);
  Alcotest.(check bool) "debug dot shows timer lifecycle" true
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
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime (S.Observer.dispose timer_observer);
  run_ok runtime (S.Observer.dispose scoped_observer)

let test_invalidated_branch_diagnostics_are_retained () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = S.Var.create true in
  let captured_left = ref None in
  let selected =
    S.bind (S.Var.watch choose_left) (fun use_left ->
        if use_left then
          let signal = S.const 10 |> S.map (fun value -> value + 1) in
          captured_left := Some signal;
          signal
        else S.const 20)
  in
  let observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured bind branch"
  in
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let before_switch = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set choose_left false);
  run_ok runtime S.stabilize;
  let after_switch = run_ok runtime (S.stats ()) in
  Alcotest.(check bool) "invalidated branch is counted as dead" true
    (after_switch.S.dead_node_count > before_switch.S.dead_node_count);
  let options : S.dot_options =
    {
      dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = true;
    }
  in
  let dot = run_ok runtime (S.to_dot ~options ()) in
  Alcotest.(check bool) "dot includes invalid node tombstones" true
    (count_occurrences dot "valid=false" > 0);
  Alcotest.(check bool) "dot namespaces invalid node tombstones" true
    (count_occurrences dot "dead_s" > 0);
  Alcotest.(check bool) "dot includes invalid dynamic scopes" true
    (count_occurrences dot ":invalid" > 0);
  Alcotest.(check int) "dot includes invalid observer" 1
    (count_occurrences dot "state=invalid_scope");
  Alcotest.(check int) "dot includes both observer handles" 2
    (count_occurrences dot "observer:");
  Alcotest.(check int) "dot includes observer edges" 2
    (count_occurrences dot "style=dashed,label=\"observes\"");
  run_ok runtime (S.Observer.dispose branch_observer);
  run_ok runtime (S.Observer.dispose observer)

let test_diagnostics_stay_read_only_after_nested_bind_replacement () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let options : S.dot_options =
    {
      dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = true;
      dot_dynamic_scopes = true;
    }
  in
  let check_diagnostics_read_only label =
    let before = run_ok runtime (S.stats ()) in
    let dot = run_ok runtime (S.to_dot ~options ()) in
    let after_dot = run_ok runtime (S.stats ()) in
    Alcotest.(check bool) (label ^ " to_dot is read-only") true
      (before = after_dot);
    let after_stats = run_ok runtime (S.stats ()) in
    Alcotest.(check bool) (label ^ " stats is read-only") true
      (before = after_stats);
    dot
  in
  let choose_left = S.Var.create true in
  let offset = S.Var.create 0 in
  let left = S.Var.create 10 in
  let right = S.Var.create 100 in
  let captured_left = ref None in
  let selected =
    S.bind (S.Var.watch choose_left) (fun use_left ->
        S.bind (S.Var.watch offset) (fun offset ->
            let signal =
              if use_left then S.Var.watch left |> S.map (( + ) offset)
              else S.Var.watch right |> S.map (( + ) offset)
            in
            if use_left && Option.is_none !captured_left then
              captured_left := Some signal;
            signal))
  in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !captured_left with
    | Some signal -> signal
    | None -> Alcotest.fail "expected captured nested bind branch"
  in
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let after_initial = run_ok runtime (S.stats ()) in
  let initial_dot = check_diagnostics_read_only "initial nested bind" in
  Alcotest.(check int) "initial dot shows both observers" 2
    (count_occurrences initial_dot "observer:");
  run_ok runtime (S.Var.set offset 7);
  run_ok runtime (S.Var.set choose_left false);
  run_ok runtime S.stabilize;
  let after_switch = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "selected switched through nested bind" 107
    (run_ok runtime (S.Observer.read selected_observer));
  expect_fail "captured branch observer invalidated" (( = ) `Invalid_scope)
    (run runtime (S.Observer.read branch_observer));
  Alcotest.(check int) "one invalid observer is counted" 1
    after_switch.S.invalid_observer_count;
  Alcotest.(check bool) "nested switch invalidated dynamic scope" true
    (after_switch.S.dynamic_scope_invalidations
     > after_initial.S.dynamic_scope_invalidations);
  Alcotest.(check bool) "nested switch records dead branch nodes" true
    (after_switch.S.dead_node_count > after_initial.S.dead_node_count);
  let switch_dot = check_diagnostics_read_only "after nested bind switch" in
  Alcotest.(check int) "switch dot shows invalid observer" 1
    (count_occurrences switch_dot "state=invalid_scope");
  run_ok runtime (S.Observer.dispose branch_observer);
  let after_partial_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "partial disposal leaves selected observer active" 1
    after_partial_dispose.S.active_observer_count;
  Alcotest.(check int) "partial disposal removes invalid observer count" 0
    after_partial_dispose.S.invalid_observer_count;
  let partial_dot =
    check_diagnostics_read_only "after invalid branch disposal"
  in
  Alcotest.(check int) "partial dot shows remaining observer" 1
    (count_occurrences partial_dot "observer:");
  run_ok runtime (S.Observer.dispose selected_observer);
  let after_final_dispose = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "final disposal removes active observers" 0
    after_final_dispose.S.active_observer_count;
  let final_dot = check_diagnostics_read_only "after final disposal" in
  Alcotest.(check int) "final dot hides disposed observers" 0
    (count_occurrences final_dot "observer:")

let test_invalid_observer_diagnostics_survive_tombstone_eviction () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let selector = S.Var.create 0 in
  let first_branch = ref None in
  let selected =
    S.bind (S.Var.watch selector) (fun index ->
        let signal = S.const index |> S.map (fun value -> value) in
        if index = 0 then first_branch := Some signal;
        signal)
  in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !first_branch with
    | Some signal -> signal
    | None -> Alcotest.fail "expected first dynamic branch"
  in
  let branch_observer =
    run_ok runtime (S.Observer.observe branch (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  for index = 1 to 1_100 do
    run_ok runtime (S.Var.set selector index);
    run_ok runtime S.stabilize
  done;
  let options : S.dot_options =
    {
      dot_scope = `All_including_invalid;
      dot_observers = true;
      dot_timers = false;
      dot_state = false;
      dot_dynamic_scopes = false;
    }
  in
  let dot = run_ok runtime (S.to_dot ~options ()) in
  Alcotest.(check int) "dot keeps invalid observer handle visible" 1
    (count_occurrences dot "state=invalid_scope");
  Alcotest.(check int) "dot labels evicted observer target id" 1
    (count_occurrences dot "missing_observed_signal_id=s");
  run_ok runtime (S.Observer.dispose branch_observer);
  run_ok runtime (S.Observer.dispose selected_observer)

let test_default_cutoff_is_physical_equality () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let initial = Array.make 1 1 in
  let next = Array.copy initial in
  Alcotest.(check bool) "test values are distinct blocks" false
    (initial == next);
  let source = S.Var.create initial in
  let events = ref [] in
  let observer =
    run_ok runtime (S.Observer.observe (S.Var.watch source) (record events))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source next);
  run_ok runtime S.stabilize;
  (match List.rev !events with
   | [ S.Initialized initialized; S.Changed { old_value; new_value } ] ->
       Alcotest.(check (list int)) "initialized value" [ 1 ]
         (Array.to_list initialized);
       Alcotest.(check bool) "old value is initial block" true
         (old_value == initial);
       Alcotest.(check bool) "new value is next block" true
         (new_value == next)
   | _ -> Alcotest.fail "expected initialized and changed events");
  Alcotest.(check bool) "observer current is next block" true
    (run_ok runtime (S.Observer.read observer) == next);
  run_ok runtime (S.Observer.dispose observer)

let test_default_physical_cutoff_suppresses_in_place_mutation () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let block = Array.make 1 1 in
  let source = S.Var.create block in
  let mapped_calls = ref 0 in
  let mapped =
    S.Var.watch source
    |> S.map (fun value ->
           incr mapped_calls;
           Array.get value 0)
  in
  let events = ref [] in
  let callbacks = ref 0 in
  let observer =
    run_ok runtime
      (S.Observer.observe mapped (fun update ->
           E.sync (fun () ->
               incr callbacks;
               events := update :: !events)))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "initial callback delivered" 1 !callbacks;
  Alcotest.(check int) "initial mapped value" 1
    (run_ok runtime (S.Observer.read observer));
  Array.set block 0 2;
  run_ok runtime (S.Var.set source block);
  Alcotest.(check int) "direct source exposes mutated block" 2
    (Array.get (S.Var.value source) 0);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "physical cutoff suppresses recompute" 1
    !mapped_calls;
  Alcotest.(check int) "same-block mutation emits no second callback" 1
    !callbacks;
  Alcotest.(check int) "observer keeps previous derived snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !events with
   | [ S.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected no event after same-block mutation");
  run_ok runtime (S.Observer.dispose observer)

let test_equality_defects_preserve_committed_snapshots () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let cutoff_source = S.Var.create 1 in
  let cutoff_signal =
    S.Var.watch cutoff_source
    |> S.map
         ~equal:(fun _old_value _new_value -> failwith "cutoff equality")
         (fun value -> value)
  in
  let cutoff_observer =
    run_ok runtime (S.Observer.observe cutoff_signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set cutoff_source 2);
  expect_die "cutoff equality defect" (run runtime S.stabilize);
  Alcotest.(check int) "cutoff defect preserves snapshot" 1
    (run_ok runtime (S.Observer.read cutoff_observer));
  run_ok runtime (S.Observer.dispose cutoff_observer);

  let source_equal_fails = ref true in
  let source =
    S.Var.create
      ~equal:(fun _old_value _new_value ->
        if !source_equal_fails then failwith "source equality";
        false)
      1
  in
  let source_observer =
    run_ok runtime (S.Observer.observe (S.Var.watch source) (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 2);
  expect_die "source equality defect" (run runtime S.stabilize);
  Alcotest.(check int) "source equality defect preserves snapshot" 1
    (run_ok runtime (S.Observer.read source_observer));
  source_equal_fails := false;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "source equality retry publishes value" 2
    (run_ok runtime (S.Observer.read source_observer));
  run_ok runtime (S.Observer.dispose source_observer);

  let observer_equal_fails = ref true in
  let observer_source = S.Var.create 1 in
  let observer_events = ref [] in
  let observer =
    run_ok runtime
      (S.Observer.observe
         ~equal:(fun _old_value _new_value ->
           if !observer_equal_fails then failwith "observer equality";
           false)
         (S.Var.watch observer_source)
         (record observer_events))
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set observer_source 2);
  expect_die "observer equality defect" (run runtime S.stabilize);
  Alcotest.(check int) "observer equality defect preserves current" 1
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "observer equality defect skips callback" 1
    (List.length !observer_events);
  observer_equal_fails := false;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observer equality retry publishes value" 2
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "observer equality retry delivers callback" 2
    (List.length !observer_events);
  run_ok runtime (S.Observer.dispose observer)

let test_ambiguous_scope_failures_are_typed () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let expect_ambiguous label eff =
    expect_fail label (( = ) `Ambiguous_scope) (run runtime eff)
  in
  let pure_source = S.Var.create 1 in
  let pure_signal =
    S.Var.watch pure_source
    |> S.map (fun value ->
           ignore (S.const value : int S.signal);
           value)
  in
  let pure_observer =
    run_ok runtime (S.Observer.observe pure_signal (fun _ -> E.unit))
  in
  expect_ambiguous "pure node construction" S.stabilize;
  run_ok runtime (S.Observer.dispose pure_observer);

  let explicit_source = S.Var.create 1 in
  let hidden_source = S.Var.create 10 in
  let var_value_signal =
    S.Var.watch explicit_source
    |> S.map (fun value -> value + S.Var.value hidden_source)
  in
  let var_value_observer =
    run_ok runtime (S.Observer.observe var_value_signal (fun _ -> E.unit))
  in
  expect_ambiguous "pure Var.value" S.stabilize;
  run_ok runtime (S.Observer.dispose var_value_observer);

  let create_watch_source = S.Var.create 1 in
  let create_watch_signal =
    S.Var.watch create_watch_source
    |> S.map (fun value ->
           let created = S.Var.create value in
           ignore (S.Var.watch created : int S.signal);
           value)
  in
  let create_watch_observer =
    run_ok runtime (S.Observer.observe create_watch_signal (fun _ -> E.unit))
  in
  expect_ambiguous "pure Var.watch after Var.create" S.stabilize;
  run_ok runtime (S.Observer.dispose create_watch_observer);

  let observer_callback_source = S.Var.create 1 in
  let observer_callback_observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch observer_callback_source) (fun _ ->
           ignore (S.const 1 : int S.signal);
           E.unit))
  in
  expect_ambiguous "observer callback construction" S.stabilize;
  run_ok runtime (S.Observer.dispose observer_callback_observer);

  let observer_effect_source = S.Var.create 1 in
  let observer_effect_observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch observer_effect_source) (fun _ ->
           E.sync (fun () -> ignore (S.const 1 : int S.signal))))
  in
  expect_ambiguous "observer effect construction" S.stabilize;
  run_ok runtime (S.Observer.dispose observer_effect_observer)

let test_bind_self_cycle_is_typed_failure () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let trigger = S.Var.create () in
  let holder = ref None in
  let cyclic =
    S.bind (S.Var.watch trigger) (fun () ->
        match !holder with
        | Some signal -> signal
        | None -> Alcotest.fail "cycle holder was not initialized")
  in
  holder := Some cyclic;
  let observer = run_ok runtime (S.Observer.observe cyclic (fun _ -> E.unit)) in
  expect_fail "self cycle" (( = ) `Cycle) (run runtime S.stabilize);
  run_ok runtime (S.Observer.dispose observer)

let test_reentrant_stabilization_is_typed_failure () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let nested = ref None in
  let observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch source) (fun _ ->
           E.exit S.stabilize
           |> E.bind (fun exit -> E.sync (fun () -> nested := Some exit))))
  in
  run_ok runtime S.stabilize;
  (match !nested with
   | Some (Eta.Exit.Error (Eta.Cause.Fail `Reentrant_stabilization)) -> ()
   | Some (Eta.Exit.Error cause) ->
       Alcotest.failf "unexpected nested cause %a" (Eta.Cause.pp pp_hidden)
         cause
   | Some (Eta.Exit.Ok ()) ->
       Alcotest.fail "nested stabilize unexpectedly succeeded"
   | None -> Alcotest.fail "nested stabilize did not run");
  run_ok runtime (S.Observer.dispose observer)

let test_reentrant_stabilization_preserves_outer_delivery_phase () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let observed = S.Var.watch source in
  let nested = ref [] in
  let record_nested () =
    E.exit S.stabilize
    |> E.bind (fun exit -> E.sync (fun () -> nested := exit :: !nested))
  in
  let first_observer =
    run_ok runtime (S.Observer.observe observed (fun _ -> record_nested ()))
  in
  let second_observer =
    run_ok runtime (S.Observer.observe observed (fun _ -> record_nested ()))
  in
  run_ok runtime S.stabilize;
  let is_reentrant = function
    | Eta.Exit.Error (Eta.Cause.Fail `Reentrant_stabilization) -> true
    | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false
  in
  Alcotest.(check int) "two nested attempts" 2 (List.length !nested);
  Alcotest.(check bool)
    "all nested attempts remained reentrant" true
    (List.for_all is_reentrant !nested);
  run_ok runtime (S.Observer.dispose first_observer);
  run_ok runtime (S.Observer.dispose second_observer)

let test_effectful_update_reentry_is_typed_failure () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  expect_fail "effectful update reentry" (( = ) `Reentrant_update)
    (run runtime
       (S.Var.update_effect source (fun current ->
            S.Var.update_effect source (fun _ -> E.pure (current + 10))
            |> E.map (fun _ -> current + 1))));
  Alcotest.(check int) "source unchanged" 1 (S.Var.value source)

let test_pure_failure_preserves_snapshot_and_retries () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let initially_failing_source = S.Var.create 1 in
  let fail_initially = ref true in
  let initially_failing =
    S.Var.watch initially_failing_source
    |> S.map (fun value ->
           if !fail_initially then (
             fail_initially := false;
             failwith "initial contract pure failure");
           value)
  in
  let initial_observer =
    run_ok runtime (S.Observer.observe initially_failing (fun _ -> E.unit))
  in
  expect_die "initial pure failure" (run runtime S.stabilize);
  expect_fail "read after failed initial stabilization"
    (( = ) `No_current_value)
    (run runtime (S.Observer.read initial_observer));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "later stabilization initializes observer" 1
    (run_ok runtime (S.Observer.read initial_observer));
  run_ok runtime (S.Observer.dispose initial_observer);
  let source = S.Var.create 1 in
  let signal =
    S.Var.watch source
    |> S.map (fun value ->
           if value = 2 then failwith "contract pure failure";
           value)
  in
  let observer = run_ok runtime (S.Observer.observe signal (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 2);
  expect_die "pure failure" (run runtime S.stabilize);
  Alcotest.(check int) "old snapshot remains after pure failure" 1
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Var.set source 3);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "later stabilization retries from pending graph" 3
    (run_ok runtime (S.Observer.read observer));
  run_ok runtime (S.Observer.dispose observer)

let test_observer_phase_mutation_is_delayed () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let updates = ref [] in
  let pending_values = ref [] in
  let snapshot_reads = ref [] in
  let observer_ref = ref None in
  let observer =
    run_ok runtime
      (S.Observer.observe signal (fun update ->
           record updates update
           |> E.bind (fun () ->
                  match (!observer_ref, update) with
                  | Some observer, S.Initialized 1 ->
                      S.Var.set source 2
                      |> E.map_error (fun _ -> `Observer_failed)
                      |> E.bind (fun () ->
                             E.sync (fun () ->
                                 pending_values :=
                                   S.Var.value source :: !pending_values))
                      |> E.bind (fun () -> S.Var.set source 3)
                      |> E.map_error (fun _ -> `Observer_failed)
                      |> E.bind (fun () ->
                             S.Observer.read observer
                             |> E.map_error (fun _ -> `Observer_failed))
                      |> E.bind (fun snapshot ->
                             E.sync (fun () ->
                                 pending_values :=
                                   S.Var.value source :: !pending_values;
                                 snapshot_reads := snapshot :: !snapshot_reads))
                  | Some _, (Initialized _ | Changed _) | None, _ -> E.unit)))
  in
  observer_ref := Some observer;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observer-phase read uses committed snapshot" 1
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check (list int)) "observer-phase writes update pending source"
    [ 2; 3 ] (List.rev !pending_values);
  Alcotest.(check (list int)) "observer-phase callback read sees snapshot"
    [ 1 ] (List.rev !snapshot_reads);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observer mutation publishes next stabilization" 3
    (run_ok runtime (S.Observer.read observer));
  (match List.rev !updates with
   | [ S.Initialized 1; S.Changed { old_value = 1; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "unexpected observer-phase updates");
  run_ok runtime (S.Observer.dispose observer)

let test_observer_lifecycle_changes_inside_callback () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let primary_events = ref [] in
  let late_events = ref [] in
  let primary_ref = ref None in
  let late_ref = ref None in
  let primary =
    run_ok runtime
      (S.Observer.observe signal (fun update ->
           record primary_events update
           |> E.bind (fun () ->
                  match (!primary_ref, update) with
                  | Some primary, S.Initialized _ ->
                      S.Observer.observe signal (record late_events)
                      |> E.map_error (fun _ -> `Observer_failed)
                      |> E.bind (fun late ->
                             E.sync (fun () -> late_ref := Some late)
                             |> E.bind (fun () ->
                                    S.Observer.dispose primary
                                    |> E.or_die (fun err ->
                                           S.Graph_error err)))
                  | _ -> E.unit)))
  in
  primary_ref := Some primary;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "late observer not run in current stabilization" 0
    (List.length !late_events);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "late observer initializes next stabilization" 1
    (List.length !late_events);
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "self-disposed observer has no future callbacks" 1
    (List.length !primary_events);
  (match List.rev !late_events with
   | [ S.Initialized 1; Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "unexpected late observer events");
  match !late_ref with
  | Some late -> run_ok runtime (S.Observer.dispose late)
  | None -> Alcotest.fail "late observer was not registered"

let test_observer_dispose_skips_collected_event () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let observed = S.Var.watch source in
  let events = ref [] in
  let later_observer = ref None in
  let first_observer =
    run_ok runtime
      (S.Observer.observe observed (fun _ ->
           let open Eta.Syntax in
           let* () = E.sync (fun () -> events := "first" :: !events) in
           match !later_observer with
           | Some observer ->
               S.Observer.dispose observer
               |> E.or_die (fun err -> S.Graph_error err)
           | None -> E.sync (fun () -> Alcotest.fail "missing observer")))
  in
  let second_observer =
    run_ok runtime
      (S.Observer.observe observed (fun _ ->
           E.sync (fun () -> events := "second" :: !events)))
  in
  later_observer := Some second_observer;
  run_ok runtime S.stabilize;
  Alcotest.(check (list string))
    "collected event is skipped after same-stabilization disposal"
    [ "first" ] (List.rev !events);
  expect_fail "same-stabilization disposed observer read"
    (( = ) `Disposed_observer)
    (run runtime (S.Observer.read second_observer));
  events := [];
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check (list string))
    "disposed observer is absent from later stabilization" [ "first" ]
    (List.rev !events);
  run_ok runtime (S.Observer.dispose first_observer)

let test_observer_callbacks_read_consistent_published_snapshot () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let left = S.Var.watch source |> S.map (fun value -> value + 1) in
  let right = S.Var.watch source |> S.map (fun value -> value + 2) in
  let total = S.map2 ( + ) left right in
  let left_observer = ref None in
  let right_observer = ref None in
  let total_observer = ref None in
  let snapshots = ref [] in
  let record_snapshot label =
    match (!left_observer, !right_observer, !total_observer) with
    | Some left_observer, Some right_observer, Some total_observer ->
        S.Observer.read left_observer
        |> E.map_error (fun _ -> `Observer_failed)
        |> E.bind (fun left_value ->
               S.Observer.read right_observer
               |> E.map_error (fun _ -> `Observer_failed)
               |> E.bind (fun right_value ->
                      S.Observer.read total_observer
                      |> E.map_error (fun _ -> `Observer_failed)
                      |> E.bind (fun total_value ->
                             E.sync (fun () ->
                                 snapshots :=
                                   (label, left_value, right_value, total_value)
                                   :: !snapshots))))
    | _ -> E.unit
  in
  let left_handle =
    run_ok runtime
      (S.Observer.observe left (fun _ ->
           S.Var.set source 100
           |> E.map_error (fun _ -> `Observer_failed)
           |> E.bind (fun () -> record_snapshot "left")))
  in
  let right_handle =
    run_ok runtime (S.Observer.observe right (fun _ -> record_snapshot "right"))
  in
  let total_handle =
    run_ok runtime (S.Observer.observe total (fun _ -> record_snapshot "total"))
  in
  left_observer := Some left_handle;
  right_observer := Some right_handle;
  total_observer := Some total_handle;
  run_ok runtime S.stabilize;
  snapshots := [];
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let render_snapshot (label, left_value, right_value, total_value) =
    Printf.sprintf "%s:%d:%d:%d" label left_value right_value total_value
  in
  Alcotest.(check (list string))
    "all callbacks read same changed snapshot"
    [ "left:3:4:7"; "right:3:4:7"; "total:3:4:7" ]
    (List.sort String.compare (List.map render_snapshot !snapshots));
  Alcotest.(check int) "callback mutation waits for next stabilization" 7
    (run_ok runtime (S.Observer.read total_handle));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "next stabilization sees callback mutation" 203
    (run_ok runtime (S.Observer.read total_handle));
  run_ok runtime (S.Observer.dispose left_handle);
  run_ok runtime (S.Observer.dispose right_handle);
  run_ok runtime (S.Observer.dispose total_handle)

let test_observer_failure_commits_snapshot_and_retries_delivery () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let watched = S.Var.watch source in
  let delivered = ref [] in
  let later_delivered = ref [] in
  let fail_next_change = ref false in
  let observer =
    run_ok runtime
      (S.Observer.observe watched (fun update ->
           match update with
           | S.Initialized _ -> record delivered update
           | S.Changed _ when !fail_next_change ->
               fail_next_change := false;
               E.fail `Observer_failed
           | S.Changed _ -> record delivered update))
  in
  let later_observer =
    run_ok runtime
      (S.Observer.observe watched (fun update ->
           match update with
           | S.Initialized _ -> E.unit
           | S.Changed _ -> record later_delivered update))
  in
  run_ok runtime S.stabilize;
  fail_next_change := true;
  run_ok runtime (S.Var.set source 1);
  let before_failure = run_ok runtime (S.stats ()) in
  expect_fail "observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (run runtime S.stabilize);
  let after_failure = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "failed delivery still commits pure snapshot"
    (before_failure.S.pure_snapshot_commit_count + 1)
    after_failure.S.pure_snapshot_commit_count;
  Alcotest.(check int) "failed delivery does not complete callbacks"
    before_failure.S.callback_delivery_count
    after_failure.S.callback_delivery_count;
  Alcotest.(check int) "failed delivery leaves observer valid" 0
    after_failure.S.invalid_observer_count;
  Alcotest.(check int) "failed delivery does not create dead nodes"
    before_failure.S.dead_node_count after_failure.S.dead_node_count;
  Alcotest.(check int) "snapshot committed despite observer failure" 1
    (run_ok runtime (S.Observer.read observer));
  Alcotest.(check int) "later observer sees committed snapshot" 1
    (run_ok runtime (S.Observer.read later_observer));
  Alcotest.(check (list int))
    "later observer delivery waits for retry" []
    (List.map
       (function
         | S.Initialized value -> value
         | S.Changed { new_value; _ } -> new_value)
       (List.rev !later_delivered));
  run_ok runtime S.stabilize;
  let after_retry = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "retry commits another pure snapshot"
    (after_failure.S.pure_snapshot_commit_count + 1)
    after_retry.S.pure_snapshot_commit_count;
  Alcotest.(check int) "retry completes callback delivery"
    (after_failure.S.callback_delivery_count + 1)
    after_retry.S.callback_delivery_count;
  (match List.rev !delivered with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected failed delivery to retry");
  (match List.rev !later_delivered with
   | [ S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected skipped observer delivery to retry");
  run_ok runtime (S.Observer.dispose observer);
  run_ok runtime (S.Observer.dispose later_observer)

let test_observer_callback_failure_channels_are_distinct () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let typed_source = S.Var.create 1 in
  let typed_observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch typed_source) (fun _update ->
           E.fail `Observer_failed))
  in
  expect_fail "observer typed failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (run runtime S.stabilize);
  run_ok runtime (S.Observer.dispose typed_observer);

  let defect_source = S.Var.create 1 in
  let defect_observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch defect_source) (fun _update ->
           failwith "contract callback construction defect"))
  in
  expect_die "callback construction defect" (run runtime S.stabilize);
  run_ok runtime (S.Observer.dispose defect_observer)

let test_derived_demand_reactivates_fresh () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let single_source = S.Var.create 0 in
  let single_watched = S.Var.watch single_source in
  let single_calls = ref 0 in
  let single =
    single_watched
    |> S.map (fun value ->
           incr single_calls;
           value + 1)
  in
  let single_source_observer =
    run_ok runtime (S.Observer.observe single_watched (fun _ -> E.unit))
  in
  let single_observer =
    run_ok runtime (S.Observer.observe single (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "single derived initial value" 1
    (run_ok runtime (S.Observer.read single_observer));
  Alcotest.(check int) "single derived initial recompute" 1 !single_calls;
  run_ok runtime (S.Observer.dispose single_observer);
  run_ok runtime (S.Var.set single_source 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "single source stayed necessary" 1
    (run_ok runtime (S.Observer.read single_source_observer));
  Alcotest.(check int) "unnecessary single derived did not recompute" 1
    !single_calls;
  let single_reobserved =
    run_ok runtime (S.Observer.observe single (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "reobserved single derived value is fresh" 2
    (run_ok runtime (S.Observer.read single_reobserved));
  Alcotest.(check int) "single derived recomputed on reobserve" 2
    !single_calls;
  run_ok runtime (S.Observer.dispose single_source_observer);
  run_ok runtime (S.Observer.dispose single_reobserved);
  let chain_source = S.Var.create 0 in
  let chain_watched = S.Var.watch chain_source in
  let first_calls = ref 0 in
  let second_calls = ref 0 in
  let first =
    chain_watched
    |> S.map (fun value ->
           incr first_calls;
           value + 1)
  in
  let second =
    first
    |> S.map (fun value ->
           incr second_calls;
           value * 10)
  in
  let chain_source_observer =
    run_ok runtime (S.Observer.observe chain_watched (fun _ -> E.unit))
  in
  let second_observer =
    run_ok runtime (S.Observer.observe second (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "initial chain value" 10
    (run_ok runtime (S.Observer.read second_observer));
  Alcotest.(check int) "initial first recompute" 1 !first_calls;
  Alcotest.(check int) "initial second recompute" 1 !second_calls;
  run_ok runtime (S.Observer.dispose second_observer);
  run_ok runtime (S.Var.set chain_source 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "chain source stayed necessary" 1
    (run_ok runtime (S.Observer.read chain_source_observer));
  Alcotest.(check int) "unnecessary first did not recompute" 1 !first_calls;
  Alcotest.(check int) "unnecessary second did not recompute" 1 !second_calls;
  let chain_reobserved =
    run_ok runtime (S.Observer.observe second (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "reactivated chain value is fresh" 20
    (run_ok runtime (S.Observer.read chain_reobserved));
  Alcotest.(check int) "first recomputed on reactivation" 2 !first_calls;
  Alcotest.(check int) "second recomputed on reactivation" 2 !second_calls;
  run_ok runtime (S.Observer.dispose chain_source_observer);
  run_ok runtime (S.Observer.dispose chain_reobserved)

let test_demand_boundary_for_derived_nodes_and_timers () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let source = S.Var.create 0 in
  let recomputes = ref 0 in
  let derived =
    S.Var.watch source
    |> S.map (fun value ->
           incr recomputes;
           value + 1)
  in
  run_ok runtime (S.Var.set source 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "unobserved derived node did not recompute" 0
    !recomputes;
  let derived_observer =
    run_ok runtime (S.Observer.observe derived (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observed derived node recomputed" 1 !recomputes;
  let timer = run_ok runtime (S.Time.interval (Eta.Duration.ms 10)) in
  Eio.Fiber.yield ();
  Alcotest.(check int) "constructing timer does not start sleeper" 0
    (Eta_test.Test_clock.sleeper_count clock);
  let timer_updates = ref [] in
  let timer_observer =
    run_ok runtime (S.Observer.observe timer (record timer_updates))
  in
  wait_until "timer sleeper" (fun () ->
      Eta_test.Test_clock.sleeper_count clock >= 1);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "observed timer initializes at zero" 0
    (run_ok runtime (S.Observer.read timer_observer));
  Alcotest.(check int) "initial timer callback delivered" 1
    (List.length !timer_updates);
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 10);
  Eio.Fiber.yield ();
  Alcotest.(check int) "timer read before stabilize remains old" 0
    (run_ok runtime (S.Observer.read timer_observer));
  Alcotest.(check int) "timer tick did not run callback before stabilize" 1
    (List.length !timer_updates);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "timer update requires explicit stabilize" 1
    (run_ok runtime (S.Observer.read timer_observer));
  (match List.rev !timer_updates with
   | [ S.Initialized 0; S.Changed { old_value = 0; new_value = 1 } ] -> ()
   | _ -> Alcotest.fail "expected timer update after explicit stabilize");
  run_ok runtime (S.Observer.dispose timer_observer);
  run_ok runtime (S.Observer.dispose derived_observer)

let test_time_invalid_intervals_fail_cleanly () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let now_signal = run_ok runtime (S.Time.now ~every:(Eta.Duration.ms 1) ()) in
  let now_observer =
    run_ok runtime (S.Observer.observe now_signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let future_deadline =
    match
      S.Time.add
        (run_ok runtime (S.Observer.read now_observer))
        (Eta.Duration.ms 1)
    with
    | Ok timestamp -> timestamp
    | Error _ -> Alcotest.fail "expected future monotonic timestamp"
  in
  run_ok runtime (S.Observer.dispose now_observer);
  expect_fail "invalid now cadence" (( = ) `Invalid_interval)
    (run runtime (S.Time.now ~every:Eta.Duration.zero ()));
  expect_fail "invalid deadline cadence" (( = ) `Invalid_interval)
    (run runtime
       (S.Time.deadline ~every:Eta.Duration.zero future_deadline));
  expect_fail "invalid interval" (( = ) `Invalid_interval)
    (run runtime (S.Time.interval Eta.Duration.zero));
  expect_fail "invalid step cadence" (( = ) `Invalid_interval)
    (run runtime
       (S.Time.step ~every:Eta.Duration.zero ~initial:0
          (fun ~missed value -> value + missed)))

let test_time_deadline_validation_errors () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let now_signal = run_ok runtime (S.Time.now ~every:(Eta.Duration.ms 1) ()) in
  let now_observer =
    run_ok runtime (S.Observer.observe now_signal (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let now = run_ok runtime (S.Observer.read now_observer) in
  run_ok runtime (S.Observer.dispose now_observer);
  expect_fail "invalid after interval" (( = ) `Invalid_interval)
    (run runtime
       (S.Time.after ~every:Eta.Duration.zero (Eta.Duration.ms 1)));
  expect_fail "past after duration" (( = ) `Past_deadline)
    (run runtime
       (S.Time.after ~every:(Eta.Duration.ms 1) Eta.Duration.zero));
  expect_fail "clamped past after duration" (( = ) `Past_deadline)
    (run runtime
       (S.Time.after ~every:(Eta.Duration.ms 1) (Eta.Duration.ms (-1))));
  expect_fail "past deadline" (( = ) `Past_deadline)
    (run runtime (S.Time.deadline ~every:(Eta.Duration.ms 1) now))

let test_time_now_uses_single_clock_snapshot_per_stabilization () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let current_now_ms = ref 0 in
  let now_ms () =
    let current = !current_now_ms in
    incr current_now_ms;
    current
  in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock) ~now_ms ()
  in
  let left =
    run_ok runtime (S.Time.now ~every:(Eta.Duration.ms 10) ())
    |> S.map S.Time.to_ms
  in
  let right =
    run_ok runtime (S.Time.now ~every:(Eta.Duration.ms 10) ())
    |> S.map S.Time.to_ms
  in
  let pair = S.map2 (fun left right -> (left, right)) left right in
  let observer =
    run_ok runtime (S.Observer.observe pair (fun _ -> E.unit))
  in
  Fun.protect
    ~finally:(fun () -> run_ok runtime (S.Observer.dispose observer))
    (fun () ->
      run_ok runtime S.stabilize;
      let left, right = run_ok runtime (S.Observer.read observer) in
      Alcotest.(check int) "same stabilization clock snapshot" left right)

let test_time_after_positive_duration_tolerates_advancing_clock () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let current_now_ms = ref 0 in
  let now_ms () =
    let current = !current_now_ms in
    incr current_now_ms;
    current
  in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~now_ms ()
  in
  ignore
    (run_ok runtime
       (S.Time.after ~every:(Eta.Duration.ms 1) (Eta.Duration.ms 1)))

let test_time_after_overflow_fails_with_deadline_overflow () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  Eta_test.Test_clock.set_time clock (max_int - 1);
  expect_fail "overflowing relative deadline" (( = ) `Deadline_overflow)
    (run runtime
       (S.Time.after ~every:(Eta.Duration.ms 1) (Eta.Duration.ms 10)))

let test_stream_bridge_is_observer_plus_queue () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer, stream =
    run_ok runtime (S.Stream.observe ~capacity:1 signal)
  in
  run_ok runtime S.stabilize;
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (S.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ S.Initialized 1 ],
      [ S.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream bridge queue behavior"

let test_stream_bridge_allows_cross_domain_consumer () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer, stream = run_ok runtime (S.Stream.observe signal) in
  run_ok runtime S.stabilize;
  (match
     run_effect_in_foreign_domain
       (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
  | Eta.Exit.Ok [ S.Initialized 1 ] -> ()
  | Eta.Exit.Ok _ ->
      Alcotest.fail "cross-domain stream bridge consumer returned wrong event"
  | Eta.Exit.Error cause ->
      Alcotest.failf "cross-domain stream bridge consumer failed: %a"
        (Eta.Cause.pp pp_hidden) cause);
  run_ok runtime (S.Observer.dispose observer)

let test_stream_observe_validates_capacity () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  expect_fail "invalid stream capacity" (( = ) `Invalid_capacity)
    (run runtime (S.Stream.observe ~capacity:0 signal))

let test_stream_dispose_closes_queue_after_buffered_updates () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let signal = S.Var.watch source in
  let observer, stream = run_ok runtime (S.Stream.observe ~capacity:4 signal) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 1);
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  run_ok runtime (S.Observer.dispose observer);
  match run_ok runtime (Eta_stream.run_collect stream) with
  | [
   S.Initialized 0;
   S.Changed { old_value = 0; new_value = 1 };
   S.Changed { old_value = 1; new_value = 2 };
  ] ->
      ()
  | _ -> Alcotest.fail "expected buffered stream updates before clean close"

let test_stream_invalid_scope_closes_queue_with_invalid_scope () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let use_branch = S.Var.create true in
  let branch_source = S.Var.create 0 in
  let captured = ref None in
  let selected =
    S.bind (S.Var.watch use_branch) (fun active ->
        if active then (
          let branch = S.Var.watch branch_source in
          captured := Some branch;
          branch)
        else S.const 42)
  in
  let selected_observer =
    run_ok runtime (S.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  let branch =
    match !captured with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch signal"
  in
  let branch_observer, stream =
    run_ok runtime (S.Stream.observe ~capacity:4 branch)
  in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set branch_source 1);
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set use_branch false);
  run_ok runtime S.stabilize;
  let before_failed_observe = run_ok runtime (S.stats ()) in
  expect_fail "invalidated branch cannot be observed again"
    (( = ) `Invalid_scope)
    (run runtime (S.Observer.observe branch (fun _ -> E.unit)));
  let after_failed_observe = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "failed stale observe does not add active observer"
    before_failed_observe.S.active_observer_count
    after_failed_observe.S.active_observer_count;
  Alcotest.(check int) "failed stale observe does not add invalid observer"
    before_failed_observe.S.invalid_observer_count
    after_failed_observe.S.invalid_observer_count;
  (match ignore (S.map Fun.id branch : int S.signal) with
  | exception S.Graph_error `Invalid_scope -> ()
  | exception exn ->
      Alcotest.failf "stale branch wrapping raised %s"
        (Printexc.to_string exn)
  | () -> Alcotest.fail "stale branch wrapping unexpectedly succeeded");
  (match
     run_ok runtime (Eta_stream.Stream.take 2 stream |> Eta_stream.run_collect)
   with
   | [
    S.Initialized 0;
    S.Changed { old_value = 0; new_value = 1 };
   ] ->
       ()
   | _ -> Alcotest.fail "expected buffered branch stream updates before error");
  expect_fail "invalidated branch stream after buffered updates"
    (( = ) `Invalid_scope)
    (run runtime (Eta_stream.run_collect stream));
  expect_fail "branch observer invalidated after stream error"
    (( = ) `Invalid_scope)
    (run runtime (S.Observer.read branch_observer));
  Alcotest.(check int) "selected switched after branch invalidation" 42
    (run_ok runtime (S.Observer.read selected_observer));
  run_ok runtime (S.Observer.dispose selected_observer)

let test_stream_with_observed_disposes_on_exit () =
  let module S = Eta_signal.Make (Observer_error) () in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let leaked_stream = ref None in
  let stream_error eff = E.map_error (fun error -> (error :> test_error)) eff in
  let before_scope = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "starts without active observers" 0
    before_scope.S.active_observer_count;
  run_ok runtime
    (S.Stream.with_observed ~capacity:4 signal (fun stream ->
         leaked_stream := Some stream;
         E.unit));
  let after_scope = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "scoped stream observer disposed" 0
    after_scope.S.active_observer_count;
  let stream =
    match !leaked_stream with
    | Some stream -> stream
    | None -> Alcotest.fail "expected stream to be passed to consumer"
  in
  Alcotest.(check (list int))
    "scoped stream closes after consumer returns"
    []
    (List.map
       (function
         | S.Initialized value -> value
         | S.Changed { new_value; _ } -> new_value)
       (run_ok runtime (Eta_stream.run_collect stream |> stream_error)));
  run_ok runtime (S.Var.set source 2);
  run_ok runtime S.stabilize;
  let after_later_stabilize = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "scoped stream stays disposed" 0
    after_later_stabilize.S.active_observer_count;
  let failed_stream = ref None in
  expect_fail "scoped stream consumer failure" (( = ) `Invalid_capacity)
    (run runtime
       (S.Stream.with_observed ~capacity:4 signal (fun stream ->
            failed_stream := Some stream;
            E.fail `Invalid_capacity)));
  let after_failed_scope = run_ok runtime (S.stats ()) in
  Alcotest.(check int) "failed scoped stream observer disposed" 0
    after_failed_scope.S.active_observer_count;
  let stream =
    match !failed_stream with
    | Some stream -> stream
    | None -> Alcotest.fail "expected stream to be passed to failed consumer"
  in
  Alcotest.(check (list int))
    "failed scoped stream closes after consumer failure"
    []
    (List.map
       (function
         | S.Initialized value -> value
         | S.Changed { new_value; _ } -> new_value)
       (run_ok runtime (Eta_stream.run_collect stream |> stream_error)));
  let manual_observer, _manual_stream =
    run_ok runtime
      (S.Stream.observe ~capacity:4 signal)
  in
  run_ok runtime S.stabilize;
  Alcotest.(check int) "manual stream can still be observed" 2
    (run_ok runtime (S.Observer.read manual_observer));
  run_ok runtime (S.Observer.dispose manual_observer)

let test_stream_bridge_full_queue_drops_newest () =
  let module S = Eta_signal.Make (Observer_error) () in
  with_logger_test_clock @@ fun sw _clock runtime logger ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let drops = ref [] in
  let drop_calls = ref 0 in
  let observer, stream =
    run_ok runtime
      (S.Stream.observe ~capacity:1
         ~on_drop:(fun update ->
           incr drop_calls;
           drops := update :: !drops;
           failwith "contract drop hook failure")
         signal)
  in
  run_ok runtime S.stabilize;
  let before_drop = run_ok runtime (S.stats ()) in
  run_ok runtime (S.Var.set source 2);
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () -> run_ok runtime S.stabilize)
  in
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool)
    "full queue stabilization does not wait for stream capacity" true
    (Eio.Promise.is_resolved stabilizer);
  Eio.Promise.await_exn stabilizer;
  let after_drop = run_ok runtime (S.stats ()) in
  Alcotest.(check int)
    "drop counted after acknowledgement"
    (before_drop.S.stream_bridge_drop_count + 1)
    after_drop.S.stream_bridge_drop_count;
  Alcotest.(check int) "failed drop hook ran once" 1 !drop_calls;
  Alcotest.(check int)
    "observer snapshot still commits"
    2
    (run_ok runtime (S.Observer.read observer));
  (match !drops with
   | [ S.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected newest stream update to be dropped");
  (match Eta.Logger.dump logger with
   | [ record ] ->
       Alcotest.(check bool) "drop hook diagnostic level" true
         (record.level = Eta.Logger.Error);
       Alcotest.(check string) "drop hook diagnostic body"
         "eta_signal.stream.on_drop_failure" record.body;
       Alcotest.(check (option string))
         "drop hook diagnostic exception"
         (Some "Failure(\"contract drop hook failure\")")
         (List.assoc_opt "exception.message" record.attrs)
   | records ->
       Alcotest.failf "expected one drop hook diagnostic, got %d"
         (List.length records));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "failed drop hook is not retried" 1 !drop_calls;
  let update_value = function
    | S.Initialized value -> value
    | S.Changed { new_value; _ } -> new_value
  in
  Alcotest.(check (list int))
    "full queue keeps original item"
    [ 1 ]
    (List.map update_value
       (run_ok runtime
          (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)));
  run_ok runtime (S.Var.set source 3);
  run_ok runtime S.stabilize;
  let after_delivery = run_ok runtime (S.stats ()) in
  Alcotest.(check int)
    "later delivery does not count as drop"
    after_drop.S.stream_bridge_drop_count
    after_delivery.S.stream_bridge_drop_count;
  (match
     run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ S.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected later stream update after draining drop");
  run_ok runtime (S.Observer.dispose observer);
  Alcotest.(check (list int))
    "disposed bridge closes after buffered items"
    []
    (List.map update_value
       (run_ok runtime (Eta_stream.run_collect stream)))

let () =
  Alcotest.run "eta_signal_contract"
    [
      ( "contract",
        [
          Alcotest.test_case "error pretty printers are clear" `Quick
            test_error_pretty_printers_are_clear;
          Alcotest.test_case "graph rejects cross-domain synchronous APIs"
            `Quick test_graph_rejects_cross_domain_synchronous_apis;
          Alcotest.test_case "graph rejects registered worker context" `Quick
            test_graph_rejects_registered_worker_context;
          Alcotest.test_case "graph rejects cross-domain effectful APIs" `Quick
            test_graph_rejects_cross_domain_effectful_apis;
          Alcotest.test_case "n-ary maps, both, and all" `Quick
            test_n_ary_maps_both_and_all;
          Alcotest.test_case "map arity matrix initializes and coalesces"
            `Quick test_map_arity_matrix_initializes_and_coalesces;
          Alcotest.test_case "map invariants repeated children and cutoff"
            `Quick test_map_invariants_repeated_children_cutoff_and_final_values;
          Alcotest.test_case "repeated dependencies deduplicate diagnostics"
            `Quick test_repeated_dependencies_are_deduplicated_in_diagnostics;
          Alcotest.test_case "explicit stabilization boundary" `Quick
            test_explicit_stabilization_boundary;
          Alcotest.test_case "functor instances stabilize independently" `Quick
            test_functor_instances_stabilize_independently;
          Alcotest.test_case "observer read does not force recompute" `Quick
            test_observer_read_does_not_force_recompute;
          Alcotest.test_case "observer graph delivery order is deterministic"
            `Quick test_observer_graph_delivery_order_is_deterministic;
          Alcotest.test_case "observer unsafe read reports invalid state"
            `Quick test_observer_unsafe_read_exn_reports_invalid_state;
          Alcotest.test_case "diagnostics track observation and disposal"
            `Quick test_diagnostics_track_observation_and_disposal;
          Alcotest.test_case "diagnostic dot options expose metadata" `Quick
            test_diagnostic_dot_options_expose_public_metadata;
          Alcotest.test_case "diagnostics retain invalidated branches" `Quick
            test_invalidated_branch_diagnostics_are_retained;
          Alcotest.test_case
            "diagnostics read-only after nested bind replacement" `Quick
            test_diagnostics_stay_read_only_after_nested_bind_replacement;
          Alcotest.test_case "diagnostics survive tombstone eviction" `Quick
            test_invalid_observer_diagnostics_survive_tombstone_eviction;
          Alcotest.test_case "default cutoff is physical equality" `Quick
            test_default_cutoff_is_physical_equality;
          Alcotest.test_case "physical cutoff suppresses in-place mutation"
            `Quick test_default_physical_cutoff_suppresses_in_place_mutation;
          Alcotest.test_case "equality defects preserve committed snapshots"
            `Quick test_equality_defects_preserve_committed_snapshots;
          Alcotest.test_case "ambiguous scope failures are typed" `Quick
            test_ambiguous_scope_failures_are_typed;
          Alcotest.test_case "bind self-cycle failure is typed" `Quick
            test_bind_self_cycle_is_typed_failure;
          Alcotest.test_case "reentrant stabilization is typed" `Quick
            test_reentrant_stabilization_is_typed_failure;
          Alcotest.test_case
            "reentrant stabilization preserves outer delivery phase" `Quick
            test_reentrant_stabilization_preserves_outer_delivery_phase;
          Alcotest.test_case "effectful update reentry is typed" `Quick
            test_effectful_update_reentry_is_typed_failure;
          Alcotest.test_case "pure failure preserves snapshot and retries"
            `Quick test_pure_failure_preserves_snapshot_and_retries;
          Alcotest.test_case "observer phase mutation is delayed" `Quick
            test_observer_phase_mutation_is_delayed;
          Alcotest.test_case "observer lifecycle changes inside callback"
            `Quick test_observer_lifecycle_changes_inside_callback;
          Alcotest.test_case "observer dispose skips collected event" `Quick
            test_observer_dispose_skips_collected_event;
          Alcotest.test_case "observer callbacks read consistent snapshot"
            `Quick test_observer_callbacks_read_consistent_published_snapshot;
          Alcotest.test_case
            "observer failure commits snapshot and retries delivery" `Quick
            test_observer_failure_commits_snapshot_and_retries_delivery;
          Alcotest.test_case "observer callback failure channels are distinct"
            `Quick test_observer_callback_failure_channels_are_distinct;
          Alcotest.test_case "derived demand reactivates fresh" `Quick
            test_derived_demand_reactivates_fresh;
          Alcotest.test_case "demand boundary for derived nodes and timers"
            `Quick test_demand_boundary_for_derived_nodes_and_timers;
          Alcotest.test_case "time invalid intervals fail cleanly" `Quick
            test_time_invalid_intervals_fail_cleanly;
          Alcotest.test_case "time deadline validation errors" `Quick
            test_time_deadline_validation_errors;
          Alcotest.test_case "time now uses one clock snapshot" `Quick
            test_time_now_uses_single_clock_snapshot_per_stabilization;
          Alcotest.test_case
            "time after positive duration tolerates advancing clock" `Quick
            test_time_after_positive_duration_tolerates_advancing_clock;
          Alcotest.test_case "time after overflow fails with Deadline_overflow"
            `Quick test_time_after_overflow_fails_with_deadline_overflow;
          Alcotest.test_case "stream bridge is observer plus queue" `Quick
            test_stream_bridge_is_observer_plus_queue;
          Alcotest.test_case "stream bridge allows cross-domain consumer"
            `Quick test_stream_bridge_allows_cross_domain_consumer;
          Alcotest.test_case "stream observe validates capacity" `Quick
            test_stream_observe_validates_capacity;
          Alcotest.test_case
            "stream dispose closes queue after buffered updates" `Quick
            test_stream_dispose_closes_queue_after_buffered_updates;
          Alcotest.test_case
            "stream invalid scope closes queue with invalid scope" `Quick
            test_stream_invalid_scope_closes_queue_with_invalid_scope;
          Alcotest.test_case "stream scoped observation disposes observer"
            `Quick test_stream_with_observed_disposes_on_exit;
          Alcotest.test_case "stream bridge full queue drops newest" `Quick
            test_stream_bridge_full_queue_drops_newest;
        ] );
    ]
