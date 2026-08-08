include Eta_signal_test_helpers

open Eta

exception Cleanup_interrupt =
  Eta_signal_test_interrupt_runtime.Cleanup_interrupt

module Cleanup_interrupt_runtime = Eta_signal_test_interrupt_runtime
module Signal_stream = Eta_signal_stream.Make (Signal)

let record updates update =
  updates := update :: !updates;
  Ok ()

let test_stream_bridge_emits_and_closes () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok runtime (Signal_stream.observe signal) in
  expect_result_ok (Signal.stabilize ());
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  expect_result_ok (Signal.Var.set source 2);
  expect_result_ok (Signal.stabilize ());
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  expect_result_ok (Signal.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ Signal.Initialized 1 ],
      [ Signal.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream updates"


let test_stream_overflow_does_not_block_graph_progress () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun sw _clock runtime ->
  let source = S.Var.create 0 in
  let signal = S.Var.watch source in
  let drops = ref 0 in
  let stream_observer, stream =
    run_ok runtime (SS.observe ~capacity:1 ~on_drop:(fun _ -> incr drops) signal)
  in
  let observer_updates = ref [] in
  let ordinary_observer =
    expect_result_ok
      (S.Observer.observe signal ~on_update:(record observer_updates))
  in
  expect_result_ok (S.stabilize ());
  let progress =
    Eio.Fiber.fork_promise ~sw (fun () ->
        expect_result_ok (S.Var.set source 1);
        expect_result_ok (S.stabilize ());
        let after_first_updates = List.length !observer_updates in
        expect_result_ok (S.Var.set source 2);
        expect_result_ok (S.stabilize ());
        after_first_updates)
  in
  wait_until "full stream bridge stabilization" (fun () ->
      Eio.Promise.is_resolved progress);
  let after_first_updates = Eio.Promise.await_exn progress in
  Alcotest.(check int) "ordinary observer progressed" 2
    after_first_updates;
  Alcotest.(check int) "full bridge dropped each overflowing update" 2 !drops;
  Alcotest.(check int) "ordinary observer still progresses" 3
    (List.length !observer_updates);
  (match
     run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ S.Initialized 0 ] -> ()
   | _ -> Alcotest.fail "expected buffered initialized stream update");
  expect_result_ok (S.Observer.dispose ordinary_observer);
  expect_result_ok (S.Observer.dispose stream_observer)


let test_stream_observe_failure_during_timer_start_does_not_leak () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
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
  let signal = run_ok rt (Signal.Time.now ~every:(Duration.ms 10)) in
  let before = expect_result_ok (Signal.stats ()) in
  (* Registering the observer starts the timer synchronously; the defect
     surfaces out of the effectful bridge [observe]. *)
  expect_die "stream observe timer start failure"
    (Eta_eio.Runtime.run rt
       (widen (Signal_stream.observe ~capacity:1 signal)));
  let after = expect_result_ok (Signal.stats ()) in
  Alcotest.(check int)
    "failed stream observe does not leak observer"
    before.Signal.active_observer_count after.Signal.active_observer_count;
  expect_result_ok (Signal.stabilize ())


let test_time_timer_start_failure_runs_invalidated_stream_cleanup () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
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
  let use_old = Signal.Var.create true in
  let old_source = Signal.Var.create 0 in
  let timer = run_ok rt (Signal.Time.interval (Duration.ms 10)) in
  let captured_old = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_old) ~f:(fun old ->
        if old then (
          let branch = Signal.Var.watch old_source |> Signal.map Fun.id in
          captured_old := Some branch;
          branch)
        else timer)
  in
  let selected_observer =
    expect_result_ok
      (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  let old_branch =
    match !captured_old with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured old branch"
  in
  let _branch_observer, stream =
    run_ok rt (Signal_stream.observe ~capacity:4 old_branch)
  in
  expect_result_ok (Signal.stabilize ());
  let drained =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eta_eio.Runtime.run rt (widen (Eta_stream.run_collect stream)))
  in
  fail_next_now := true;
  expect_result_ok (Signal.Var.set use_old false);
  (match Signal.stabilize () with
   | _ -> Alcotest.fail "expected timer branch start defect"
   | exception Failure _ -> ());
  wait_until "invalidated stream cleanup after timer start failure" (fun () ->
      Eio.Promise.is_resolved drained);
  expect_fail "invalidated stream closes after timer start failure"
    (( = ) `Invalid_scope) (Eio.Promise.await_exn drained);
  expect_result_ok (Signal.Observer.dispose selected_observer)


let test_stream_bridge_waiting_consumer_gets_reserved_sent_update_once () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
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
      (Runtime.run rt (widen (Signal_stream.observe signal)))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Signal.Observer.dispose observer))
    (fun () ->
      let consumer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt
              (widen
                 (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
      in
      Eio.Promise.await waiting;
      expect_result_ok (Signal.stabilize ());
      (match
         expect_exit_ok "waiting stream consumer"
           (Eio.Promise.await_exn consumer)
       with
       | [ Signal.Initialized 1 ] -> ()
       | _ -> Alcotest.fail "expected one initialized stream update");
      expect_result_ok (Signal.stabilize ());
      expect_result_ok (Signal.Observer.dispose observer);
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
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
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
    let fresh = Base.fresh
    let sleep duration = Eta_test.Test_clock.sleep clock duration
    let protect = Base.protect
    let with_cancel_mask = Base.with_cancel_mask
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
      (Runtime.run rt (widen (Signal_stream.observe ~capacity:16 signal)))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Signal.Observer.dispose observer))
    (fun () ->
      let consumer =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt
              (widen
                 (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)))
      in
      Eio.Promise.await waiting;
      fail_next_resolve := true;
      (* The bridge contains the publication defect: the send is committed
         before the wake, so stabilization succeeds and the buffered update
         stays available. *)
      expect_result_ok (Signal.stabilize ());
      Alcotest.(check int) "consumer wakeup failure injected" 1
        !resolve_failures;
      expect_result_ok (Signal.Observer.dispose observer);
      (match
         expect_exit_ok "stream consumer received committed update at close"
           (Eio.Promise.await_exn consumer)
       with
       | [ Signal.Initialized 0 ] -> ()
       | _ -> Alcotest.fail "expected initialized stream update"))


let test_stream_bridge_full_queue_failure_releases_phase () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let bridge_observer, stream =
    run_ok rt (Signal_stream.observe ~capacity:1 signal)
  in
  let fail_next = ref false in
  let failing_observer =
    expect_result_ok
      (Signal.Observer.observe signal ~on_update:(function
        | Signal.Changed _ when !fail_next -> Error `Observer_failed
        | _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  fail_next := true;
  expect_result_ok (Signal.Var.set source 2);
  expect_result_fail "full bridge then observer failure"
    (function `Observer_error `Observer_failed -> true | _ -> false)
    (Signal.stabilize ());
  Alcotest.(check int) "bridge snapshot published before failure" 2
    (expect_result_ok (Signal.Observer.read bridge_observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update after dropped change");
  fail_next := false;
  expect_result_ok (Signal.Var.set source 3);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "graph phase released after observer failure" 3
    (expect_result_ok (Signal.Observer.read bridge_observer));
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected later stream update after failure");
  expect_result_ok (Signal.Observer.dispose bridge_observer);
  expect_result_ok (Signal.Observer.dispose failing_observer)


let test_stream_bridge_dispose_during_observer_phase_is_deterministic () =
  let module Signal = Eta_signal.Make (Observer_error) () in
  let module Signal_stream = Eta_signal_stream.Make (Signal) in
  with_runtime @@ fun rt ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let bridge_observer, stream = run_ok rt (Signal_stream.observe signal) in
  let dispose_bridge = ref false in
  let disposer =
    expect_result_ok
      (Signal.Observer.observe signal ~on_update:(function
        | Signal.Changed _ when !dispose_bridge ->
            (match Signal.Observer.dispose bridge_observer with
            | Ok () -> Ok ()
            | Error err -> raise (Signal.Graph_error err))
        | _ -> Ok ()))
  in
  expect_result_ok (Signal.stabilize ());
  (match
     run_ok rt (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ Signal.Initialized 1 ] -> ()
   | _ -> Alcotest.fail "expected initial stream update");
  dispose_bridge := true;
  expect_result_ok (Signal.Var.set source 2);
  expect_result_ok (Signal.stabilize ());
  expect_result_fail "bridge disposed during observer phase"
    (( = ) `Disposed_observer)
    (Signal.Observer.read bridge_observer);
  (match run_ok rt (Eta_stream.run_collect stream) with
   | [ Signal.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ ->
       Alcotest.fail
         "expected changed stream update to drain before deterministic close");
  expect_result_ok (Signal.Var.set source 3);
  expect_result_ok (Signal.stabilize ());
  Alcotest.(check int) "disposer observer remains alive after bridge disposal" 3
    (expect_result_ok (Signal.Observer.read disposer));
  expect_result_ok (Signal.Observer.dispose disposer)



module E = Eta.Effect

let run runtime eff = Eta.Runtime.run runtime (widen eff)

let run_effect_in_foreign_domain eff =
  run_in_domain @@ fun () ->
  Eta_test.with_test_clock @@ fun _sw _clock runtime -> run runtime eff

let test_stream_bridge_is_observer_plus_queue () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer, stream =
    run_ok runtime (SS.observe ~capacity:1 signal)
  in
  expect_result_ok (S.stabilize ());
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  expect_result_ok (S.Var.set source 2);
  expect_result_ok (S.stabilize ());
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  expect_result_ok (S.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ S.Initialized 1 ],
      [ S.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream bridge queue behavior"


let test_stream_bridge_allows_cross_domain_consumer () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let observer, stream = run_ok runtime (SS.observe signal) in
  expect_result_ok (S.stabilize ());
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
  expect_result_ok (S.Observer.dispose observer)


let test_stream_observe_validates_capacity () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  expect_fail "invalid stream capacity" (( = ) `Invalid_capacity)
    (run runtime (SS.observe ~capacity:0 signal))


let test_stream_dispose_closes_queue_after_buffered_updates () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 0 in
  let signal = S.Var.watch source in
  let observer, stream = run_ok runtime (SS.observe ~capacity:4 signal) in
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Var.set source 1);
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Var.set source 2);
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Observer.dispose observer);
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
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let use_branch = S.Var.create true in
  let branch_source = S.Var.create 0 in
  let captured = ref None in
  let selected =
    S.bind (S.Var.watch use_branch) ~f:(fun active ->
        if active then (
          let branch = S.Var.watch branch_source in
          captured := Some branch;
          branch)
        else S.const 42)
  in
  let selected_observer =
    expect_result_ok
      (S.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  expect_result_ok (S.stabilize ());
  let branch =
    match !captured with
    | Some branch -> branch
    | None -> Alcotest.fail "expected captured branch signal"
  in
  let branch_observer, stream =
    run_ok runtime (SS.observe ~capacity:4 branch)
  in
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Var.set branch_source 1);
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Var.set use_branch false);
  expect_result_ok (S.stabilize ());
  let before_failed_observe = expect_result_ok (S.stats ()) in
  expect_result_fail "invalidated branch cannot be observed again"
    (( = ) `Invalid_scope)
    (S.Observer.observe branch ~on_update:(fun _ -> Ok ()));
  let after_failed_observe = expect_result_ok (S.stats ()) in
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
  expect_result_fail "branch observer invalidated after stream error"
    (( = ) `Invalid_scope)
    (S.Observer.read branch_observer);
  Alcotest.(check int) "selected switched after branch invalidation" 42
    (expect_result_ok (S.Observer.read selected_observer));
  expect_result_ok (S.Observer.dispose selected_observer)


let test_stream_bridge_full_queue_drops_newest () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  with_logger_test_clock @@ fun sw _clock runtime logger ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let drops = ref [] in
  let drop_calls = ref 0 in
  let observer, stream =
    run_ok runtime
      (SS.observe ~capacity:1
         ~on_drop:(fun update ->
           incr drop_calls;
           drops := update :: !drops;
           failwith "contract drop hook failure")
         signal)
  in
  expect_result_ok (S.stabilize ());
  expect_result_ok (S.Var.set source 2);
  let stabilizer =
    Eio.Fiber.fork_promise ~sw (fun () -> expect_result_ok (S.stabilize ()))
  in
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool)
    "full queue stabilization does not wait for stream capacity" true
    (Eio.Promise.is_resolved stabilizer);
  Eio.Promise.await_exn stabilizer;
  Alcotest.(check int) "failed drop hook ran once" 1 !drop_calls;
  Alcotest.(check int)
    "observer snapshot still commits"
    2
    (expect_result_ok (S.Observer.read observer));
  (match !drops with
   | [ S.Changed { old_value = 1; new_value = 2 } ] -> ()
   | _ -> Alcotest.fail "expected newest stream update to be dropped");
  (match Eta_observability.Logger.dump logger with
   | [] -> ()
   | records ->
       Alcotest.failf "defect report must be buffered until the next bridge call, got %d"
         (List.length records));
  (* A later effectful bridge call flushes the buffered defect report. *)
  let flushing_observer, _flushing_stream =
    run_ok runtime (SS.observe ~capacity:1 signal)
  in
  (match Eta_observability.Logger.dump logger with
   | [ record ] ->
       Alcotest.(check bool) "drop hook diagnostic level" true
         (record.level = Eta_observability.Logger.Error);
       Alcotest.(check string) "drop hook diagnostic body"
         "eta_signal.stream.on_drop_failure" record.body;
       Alcotest.(check (option string))
         "drop hook diagnostic exception"
         (Some "Failure(\"contract drop hook failure\")")
         (List.assoc_opt "exception.message" record.attrs)
   | records ->
       Alcotest.failf "expected one drop hook diagnostic, got %d"
         (List.length records));
  expect_result_ok (S.Observer.dispose flushing_observer);
  expect_result_ok (S.stabilize ());
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
  expect_result_ok (S.Var.set source 3);
  expect_result_ok (S.stabilize ());
  (match
     run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
   with
   | [ S.Changed { old_value = 2; new_value = 3 } ] -> ()
   | _ -> Alcotest.fail "expected later stream update after draining drop");
  expect_result_ok (S.Observer.dispose observer);
  Alcotest.(check (list int))
    "disposed bridge closes after buffered items"
    []
    (List.map update_value
       (run_ok runtime (Eta_stream.run_collect stream)))


let test_stream_with_observed_disposes_on_exit () =
  let module S = Eta_signal.Make (Observer_error) () in
  let module SS = Eta_signal_stream.Make (S) in
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = S.Var.create 1 in
  let signal = S.Var.watch source in
  let leaked_stream = ref None in
  let stream_error eff = E.map_error (fun error -> (error :> test_error)) eff in
  let before_scope = expect_result_ok (S.stats ()) in
  Alcotest.(check int) "starts without active observers" 0
    before_scope.S.active_observer_count;
  run_ok runtime
    (SS.with_observed ~capacity:4 signal (fun stream ->
         leaked_stream := Some stream;
         E.unit));
  let after_scope = expect_result_ok (S.stats ()) in
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
  expect_result_ok (S.Var.set source 2);
  expect_result_ok (S.stabilize ());
  let after_later_stabilize = expect_result_ok (S.stats ()) in
  Alcotest.(check int) "scoped stream stays disposed" 0
    after_later_stabilize.S.active_observer_count;
  let failed_stream = ref None in
  expect_fail "scoped stream consumer failure" (( = ) `Invalid_capacity)
    (run runtime
       (SS.with_observed ~capacity:4 signal (fun stream ->
            failed_stream := Some stream;
            E.fail `Invalid_capacity)));
  let after_failed_scope = expect_result_ok (S.stats ()) in
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
      (SS.observe ~capacity:4 signal)
  in
  expect_result_ok (S.stabilize ());
  Alcotest.(check int) "manual stream can still be observed" 2
    (expect_result_ok (S.Observer.read manual_observer));
  expect_result_ok (S.Observer.dispose manual_observer)


let () =
  Alcotest.run "eta_signal_stream"
    [
      ( "stream",
        [
          Alcotest.test_case "stream bridge emits and closes" `Quick
            test_stream_bridge_emits_and_closes;
          Alcotest.test_case "stream overflow does not block graph progress"
            `Quick test_stream_overflow_does_not_block_graph_progress;
          Alcotest.test_case "stream observe failure during timer start"
            `Quick test_stream_observe_failure_during_timer_start_does_not_leak;
          Alcotest.test_case
            "timer start failure runs invalidated stream cleanup" `Quick
            test_time_timer_start_failure_runs_invalidated_stream_cleanup;
          Alcotest.test_case
            "stream bridge waiting consumer gets reserved sent update once"
            `Quick
            test_stream_bridge_waiting_consumer_gets_reserved_sent_update_once;
          Alcotest.test_case
            "stream bridge consumer wakeup failure does not fail stabilize"
            `Quick
            test_stream_bridge_consumer_wakeup_failure_does_not_fail_stabilize;
          Alcotest.test_case "stream bridge full queue failure releases phase"
            `Quick test_stream_bridge_full_queue_failure_releases_phase;
          Alcotest.test_case
            "stream bridge dispose during observer phase is deterministic"
            `Quick test_stream_bridge_dispose_during_observer_phase_is_deterministic;
        ] );
      ( "stream contract",
        [
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
