open Eta_test

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done;
  Alcotest.(check bool) "expected sleepers" true
    (Test_clock.sleeper_count clock >= expected)

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Eta.Runtime.run rt eff));
  promise

type recording_clock = {
  mutable now_ms : int;
  mutable sleeps_ms : int list;
}

let recording_clock now_ms = { now_ms; sleeps_ms = [] }

let recording_clock_capability clock : Eta.Capabilities.clock =
  object
    method now_ms () = clock.now_ms

    method sleep duration =
      let ms = Eta.Duration.to_ms duration in
      clock.sleeps_ms <- ms :: clock.sleeps_ms;
      clock.now_ms <- clock.now_ms + ms
  end

let pp_hidden fmt _ = Format.pp_print_string fmt "<err>"

let check_outcome kind =
  match kind with
  | `Success, Eta.Exit.Ok () -> ()
  | `Typed_failure, Eta.Exit.Error (Eta.Cause.Fail `Expected) -> ()
  | `Defect, Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | `Interruption, Eta.Exit.Error (Eta.Cause.Interrupt _) -> ()
  | _, Eta.Exit.Ok () -> Alcotest.fail "unexpected successful scoped outcome"
  | _, Eta.Exit.Error cause ->
      Alcotest.failf "unexpected scoped outcome: %a"
        (Eta.Cause.pp pp_hidden) cause

let terminal :
    [ `Success | `Typed_failure | `Defect | `Interruption ] ->
    (unit, [ `Expected ]) Eta.Effect.t = function
  | `Success -> Eta.Effect.unit
  | `Typed_failure -> Eta.Effect.fail `Expected
  | `Defect -> Eta.Effect.die_message "expected scoped defect"
  | `Interruption ->
      Eta.Effect.Expert.make ~capabilities:[] (fun _ ->
          Eta.Exit.Error Eta.Cause.interrupt)

let test_scoped_capabilities_restore_on_all_exit_kinds () =
  with_logger_and_tracer @@ fun _sw rt base_logger base_tracer ->
  let trace_ids = ref [] in
  let kinds = [ `Success; `Typed_failure; `Defect; `Interruption ] in
  List.iteri
    (fun index kind ->
      let label = Printf.sprintf "inside-%d" index in
      let after_label = Printf.sprintf "after-%d" index in
      let inside_now = ref None in
      let clock = recording_clock 100 in
      let logger = Eta.Logger.in_memory () in
      let tracer = Eta.Tracer.in_memory () in
      let random = Eta.Capabilities.random_of_seed 4242 in
      let open Eta.Syntax in
      let inside =
        let* now = Eta.Effect.now_ms in
        let* () = Eta.Effect.sync (fun () -> inside_now := Some now) in
        let* () = Eta.Effect.log label in
        let* () = Eta.Effect.named label Eta.Effect.unit in
        terminal kind
      in
      let scoped =
        inside
        |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
        |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
        |> Eta.Effect.with_random random
        |> Eta.Effect.with_clock (recording_clock_capability clock)
      in
      let program =
        let* outcome = Eta.Effect.to_exit scoped in
        let* after_now = Eta.Effect.now_ms in
        let* () = Eta.Effect.log after_label in
        let+ () = Eta.Effect.named after_label Eta.Effect.unit in
        (outcome, after_now)
      in
      let outcome, after_now =
        Eta.Runtime.run rt program |> Expect.expect_ok
      in
      check_outcome (kind, outcome);
      Alcotest.(check (option int)) "override active" (Some 100) !inside_now;
      Alcotest.(check int) "clock restored" 0 after_now;
      (match Eta.Logger.dump logger with
      | [ record ] -> Alcotest.(check string) "override logger" label record.body
      | records ->
          Alcotest.failf "expected one override log, got %d"
            (List.length records));
      (match Eta.Tracer.dump tracer with
      | [ span ] ->
          Alcotest.(check string) "override tracer" label span.name;
          trace_ids := span.trace_id :: !trace_ids
      | spans ->
          Alcotest.failf "expected one override span, got %d" (List.length spans)))
    kinds;
  (match !trace_ids with
  | first :: rest ->
      List.iter (Alcotest.(check string) "random override replay" first) rest
  | [] -> Alcotest.fail "missing override trace IDs");
  let base_logs = Eta.Logger.dump base_logger in
  let base_spans = Eta.Tracer.dump base_tracer in
  Alcotest.(check int) "base logger restored" 4 (List.length base_logs);
  Alcotest.(check int) "base tracer restored" 4 (List.length base_spans);
  Alcotest.(check int) "base random restored" 4
    (base_spans |> List.map (fun span -> span.Eta.Tracer.trace_id)
    |> List.sort_uniq String.compare |> List.length)

let test_scoped_capabilities_fork_inherit () =
  with_test_clock @@ fun _sw _base_clock rt ->
  let clock = recording_clock 77 in
  let logger = Eta.Logger.in_memory () in
  let tracer = Eta.Tracer.in_memory () in
  let random = Eta.Capabilities.random_of_seed 7 in
  let open Eta.Syntax in
  let child name =
    let* now = Eta.Effect.now_ms in
    let* () = Eta.Effect.log name in
    let+ () = Eta.Effect.named name Eta.Effect.unit in
    now
  in
  let program =
    Eta.Effect.par (child "left") (child "right")
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
    |> Eta.Effect.with_random random
    |> Eta.Effect.with_clock (recording_clock_capability clock)
  in
  Alcotest.(check (pair int int)) "fork inherits clock" (77, 77)
    (Eta.Runtime.run rt program |> Expect.expect_ok);
  Alcotest.(check int) "fork inherits logger" 2
    (List.length (Eta.Logger.dump logger));
  Alcotest.(check int) "fork inherits tracer" 2
    (List.length (Eta.Tracer.dump tracer))

let branch_probe name =
  let open Eta.Syntax in
  let* now = Eta.Effect.now_ms in
  let* () = Eta.Effect.log name in
  let+ () = Eta.Effect.named name Eta.Effect.unit in
  now

let test_scoped_capabilities_par_sibling_isolation_both_directions () =
  with_logger_and_tracer @@ fun _sw rt base_logger base_tracer ->
  let run_override name now branch =
    let clock = recording_clock now in
    let logger = Eta.Logger.in_memory () in
    let tracer = Eta.Tracer.in_memory () in
    let random = Eta.Capabilities.random_of_seed now in
    let overridden =
      branch_probe name
      |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
      |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
      |> Eta.Effect.with_random random
      |> Eta.Effect.with_clock (recording_clock_capability clock)
    in
    let program =
      match branch with
      | `Left -> Eta.Effect.par overridden (branch_probe "base-right")
      | `Right -> Eta.Effect.par (branch_probe "base-left") overridden
    in
    let result = Eta.Runtime.run rt program |> Expect.expect_ok in
    Alcotest.(check int) "isolated logger" 1
      (List.length (Eta.Logger.dump logger));
    Alcotest.(check int) "isolated tracer" 1
      (List.length (Eta.Tracer.dump tracer));
    result
  in
  Alcotest.(check (pair int int)) "left override isolated" (11, 0)
    (run_override "override-left" 11 `Left);
  Alcotest.(check (pair int int)) "right override isolated" (0, 22)
    (run_override "override-right" 22 `Right);
  Alcotest.(check int) "base logger sees only base siblings" 2
    (List.length (Eta.Logger.dump base_logger));
  Alcotest.(check int) "base tracer sees only base siblings" 2
    (List.length (Eta.Tracer.dump base_tracer))

let test_scoped_capabilities_nested_innermost_wins_and_restores_outer () =
  with_test_clock @@ fun _sw _clock rt ->
  let outer_clock = recording_clock 10 in
  let inner_clock = recording_clock 20 in
  let outer_logger = Eta.Logger.in_memory () in
  let inner_logger = Eta.Logger.in_memory () in
  let outer_tracer = Eta.Tracer.in_memory () in
  let inner_tracer = Eta.Tracer.in_memory () in
  let outer_random = Eta.Capabilities.random_of_seed 10 in
  let inner_random = Eta.Capabilities.random_of_seed 20 in
  let outer_probe name = branch_probe name in
  let inner_probe =
    branch_probe "inner"
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability inner_tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability inner_logger)
    |> Eta.Effect.with_random inner_random
    |> Eta.Effect.with_clock (recording_clock_capability inner_clock)
  in
  let open Eta.Syntax in
  let program =
    let* before = outer_probe "outer-before" in
    let* inner = inner_probe in
    let+ after = outer_probe "outer-after" in
    [ before; inner; after ]
  in
  let program =
    program
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability outer_tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability outer_logger)
    |> Eta.Effect.with_random outer_random
    |> Eta.Effect.with_clock (recording_clock_capability outer_clock)
  in
  Alcotest.(check (list int)) "innermost clock and outer restore" [ 10; 20; 10 ]
    (Eta.Runtime.run rt program |> Expect.expect_ok);
  Alcotest.(check int) "outer logger restored" 2
    (List.length (Eta.Logger.dump outer_logger));
  Alcotest.(check int) "inner logger wins" 1
    (List.length (Eta.Logger.dump inner_logger));
  Alcotest.(check int) "outer tracer restored" 2
    (List.length (Eta.Tracer.dump outer_tracer));
  Alcotest.(check int) "inner tracer wins" 1
    (List.length (Eta.Tracer.dump inner_tracer))

let test_with_clock_controls_sleep_and_timeout_without_wall_time () =
  with_test_clock @@ fun sw base_clock rt ->
  let clock = Test_clock.create () in
  Test_clock.set_time clock 5;
  let sleep_run =
    Eta.Effect.with_clock (Test_clock.as_capability clock)
      (Eta.Effect.sleep (Eta.Duration.ms 25))
    |> fork_run sw rt
  in
  wait_for_sleepers clock 1;
  Alcotest.(check int) "base clock untouched" 0
    (Test_clock.sleeper_count base_clock);
  Test_clock.adjust clock (Eta.Duration.ms 25);
  Expect.expect_ok (Eio.Promise.await sleep_run);
  let timeout_run =
    Eta.Effect.with_clock (Test_clock.as_capability clock)
      (Eta.Effect.timeout_as (Eta.Duration.ms 10) ~on_timeout:`Expected
         Eta.Effect.never)
    |> fork_run sw rt
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Eta.Duration.ms 10);
  Eio.Promise.await timeout_run
  |> fun exit -> Expect.expect_typed_failure exit (( = ) `Expected)

let test_with_random_controls_retry_jitter () =
  with_test_clock @@ fun _sw _clock rt ->
  let run seed =
    let clock = recording_clock 0 in
    let attempts = ref 0 in
    let attempt =
      let open Eta.Syntax in
      let* () = Eta.Effect.sync (fun () -> incr attempts) in
      if !attempts < 3 then Eta.Effect.fail `Retry else Eta.Effect.unit
    in
    let program =
      Eta.Effect.retry
        ~schedule:
          (Eta.Schedule.spaced (Eta.Duration.ms 100)
          |> Eta.Schedule.jittered ~min:0.5 ~max:1.5)
        ~while_:(fun `Retry -> true) attempt
      |> Eta.Effect.with_random (Eta.Capabilities.random_of_seed seed)
      |> Eta.Effect.with_clock (recording_clock_capability clock)
    in
    Expect.expect_ok (Eta.Runtime.run rt program);
    List.rev clock.sleeps_ms
  in
  let first = run 1234 in
  let replay = run 1234 in
  let other = run 5678 in
  Alcotest.(check int) "two retry sleeps" 2 (List.length first);
  Alcotest.(check (list int)) "seed replay" first replay;
  Alcotest.(check bool) "different seed" true (first <> other)

let test_with_logger_replaces_sink_and_composes_before_it () =
  with_logger @@ fun _sw rt base_logger ->
  let replacement = Eta.Logger.in_memory () in
  let open Eta.Syntax in
  let body =
    let* () = Eta.Effect.log_info "dropped" in
    Eta.Effect.log_error ~attrs:[ ("call", "yes") ] "kept"
  in
  let scoped =
    body
    |> Eta.Effect.with_minimum_log_level Eta.Capabilities.Warn
    |> Eta.Effect.annotate_logs [ ("scope", "yes") ]
    |> Eta.Effect.with_logger (Eta.Logger.as_capability replacement)
  in
  let program =
    let* () = scoped in
    Eta.Effect.log_info "base"
  in
  Expect.expect_ok (Eta.Runtime.run rt program);
  (match Eta.Logger.dump replacement with
  | [ record ] ->
      Alcotest.(check string) "replacement body" "kept" record.body;
      Alcotest.(check (list (pair string string))) "attrs before sink"
        [ ("scope", "yes"); ("call", "yes") ] record.attrs
  | records ->
      Alcotest.failf "expected one replacement log, got %d"
        (List.length records));
  match Eta.Logger.dump base_logger with
  | [ record ] -> Alcotest.(check string) "base restored" "base" record.body
  | records -> Alcotest.failf "expected one base log, got %d" (List.length records)

let test_daemon_retains_fork_time_capabilities_after_scope_exit () =
  with_logger_and_tracer @@ fun _sw rt base_logger base_tracer ->
  let gate, release = Eio.Promise.create () in
  let started, mark_started = Eio.Promise.create () in
  let clock = recording_clock 88 in
  let logger = Eta.Logger.in_memory () in
  let tracer = Eta.Tracer.in_memory () in
  let observed_now = ref None in
  let open Eta.Syntax in
  let daemon_body =
    let* () = Eta.Effect.sync (fun () -> Eio.Promise.resolve mark_started ()) in
    let* () = Eta.Effect.sync (fun () -> Eio.Promise.await gate) in
    let* now = Eta.Effect.now_ms in
    let* () = Eta.Effect.sync (fun () -> observed_now := Some now) in
    let* () = Eta.Effect.log "daemon" in
    Eta.Effect.named "daemon" Eta.Effect.unit
  in
  let start =
    Eta.Effect.daemon daemon_body
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
    |> Eta.Effect.with_random (Eta.Capabilities.random_of_seed 88)
    |> Eta.Effect.with_clock (recording_clock_capability clock)
  in
  Expect.expect_ok (Eta.Runtime.run rt start);
  let attempts = ref 0 in
  while not (Eio.Promise.is_resolved started) && !attempts < 200 do
    incr attempts;
    yield ()
  done;
  if not (Eio.Promise.is_resolved started) then
    Alcotest.failf "daemon did not start; override diagnostics=%d"
      (List.length (Eta.Logger.dump logger));
  Eio.Promise.await started;
  Eio.Promise.resolve release ();
  Eta.Runtime.drain rt;
  Alcotest.(check (option int)) "daemon clock retained" (Some 88) !observed_now;
  Alcotest.(check int) "daemon logger retained" 1
    (List.length (Eta.Logger.dump logger));
  Alcotest.(check int) "daemon tracer retained" 1
    (List.length (Eta.Tracer.dump tracer));
  Alcotest.(check int) "base logger isolated" 0
    (List.length (Eta.Logger.dump base_logger));
  Alcotest.(check int) "base tracer isolated" 0
    (List.length (Eta.Tracer.dump base_tracer))

let test_scoped_capabilities_restore_after_runtime_cancellation () =
  with_test_clock @@ fun sw base_clock rt ->
  let base_logger = Eta.Logger.in_memory () in
  let base_tracer = Eta.Tracer.in_memory () in
  let inner_logger = Eta.Logger.in_memory () in
  let inner_tracer = Eta.Tracer.in_memory () in
  let inner_clock = recording_clock 99 in
  let cleanup_now = ref None in
  let started = ref false in
  let open Eta.Syntax in
  let inner_body =
    let* () = Eta.Effect.log "inner" in
    let* () = Eta.Effect.named "inner" Eta.Effect.unit in
    let* () = Eta.Effect.sync (fun () -> started := true) in
    Eta.Effect.never
  in
  let inner =
    inner_body
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability inner_tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability inner_logger)
    |> Eta.Effect.with_random (Eta.Capabilities.random_of_seed 99)
    |> Eta.Effect.with_clock (recording_clock_capability inner_clock)
  in
  let cleanup _interrupt_id =
    let* now = Eta.Effect.now_ms in
    let* () = Eta.Effect.sync (fun () -> cleanup_now := Some now) in
    let* () = Eta.Effect.log "cleanup" in
    Eta.Effect.named "cleanup" Eta.Effect.unit
  in
  let program =
    inner
    |> Eta.Effect.on_interrupt cleanup
    |> Eta.Effect.timeout_as (Eta.Duration.ms 10) ~on_timeout:`Timeout
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability base_tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability base_logger)
    |> Eta.Effect.with_random (Eta.Capabilities.random_of_seed 10)
    |> Eta.Effect.with_clock (Test_clock.as_capability base_clock)
  in
  let running = fork_run sw rt program in
  while not !started do
    yield ()
  done;
  wait_for_sleepers base_clock 1;
  Test_clock.adjust base_clock (Eta.Duration.ms 10);
  Eio.Promise.await running
  |> fun exit -> Expect.expect_typed_failure exit (( = ) `Timeout);
  Alcotest.(check (option int)) "cleanup uses restored outer clock" (Some 10)
    !cleanup_now;
  Alcotest.(check int) "inner logger before cancellation" 1
    (List.length (Eta.Logger.dump inner_logger));
  Alcotest.(check int) "outer logger after cancellation" 1
    (List.length (Eta.Logger.dump base_logger));
  Alcotest.(check int) "inner tracer closed by cancellation" 1
    (List.length (Eta.Tracer.dump inner_tracer));
  Alcotest.(check int) "outer tracer after cancellation" 1
    (List.length (Eta.Tracer.dump base_tracer))

let find_span name spans =
  match List.find_opt (fun span -> span.Eta.Tracer.name = name) spans with
  | Some span -> span
  | None -> Alcotest.failf "missing span %S" name

let test_tracer_override_preserves_open_span_and_captured_tracer () =
  with_logger @@ fun _sw rt logger ->
  let outer = Eta.Tracer.in_memory () in
  let inner = Eta.Tracer.in_memory () in
  let open Eta.Syntax in
  let body =
    let* () = Eta.Effect.annotate ~key:"before" ~value:"outer" Eta.Effect.unit in
    let* () =
      Eta.Effect.with_tracer (Eta.Tracer.as_capability inner)
        (let* () =
           Eta.Effect.annotate ~key:"during" ~value:"outer" Eta.Effect.unit
         in
         let* () = Eta.Effect.log "outer-correlated" in
         Eta.Effect.named "inner" Eta.Effect.unit)
    in
    Eta.Effect.annotate ~key:"after" ~value:"outer" Eta.Effect.unit
  in
  let program =
    Eta.Effect.named "outer" body
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability outer)
  in
  Expect.expect_ok (Eta.Runtime.run rt program);
  let outer_span = find_span "outer" (Eta.Tracer.dump outer) in
  let inner_span = find_span "inner" (Eta.Tracer.dump inner) in
  Alcotest.(check (list (pair string string))) "outer attrs survive override"
    [ ("before", "outer"); ("during", "outer"); ("after", "outer") ]
    outer_span.attrs;
  Alcotest.(check string) "cross-tracer parent trace" outer_span.trace_id
    inner_span.trace_id;
  (match Eta.Logger.dump logger with
  | [ record ] ->
      Alcotest.(check string) "log keeps captured outer trace" outer_span.trace_id
        record.trace_id;
      Alcotest.(check bool) "log keeps captured outer span" true
        (record.span_id <> "");
      (match inner_span.external_parent with
      | Some parent ->
          Alcotest.(check string) "cross-tracer external parent span"
            record.span_id parent.span_id
      | None -> Alcotest.fail "inner tracer did not record an external parent")
  | records ->
      Alcotest.failf "expected one correlated log, got %d" (List.length records))

let test_same_tracer_nested_override_keeps_parent_context () =
  with_test_clock @@ fun _sw _clock rt ->
  let tracer = Eta.Tracer.in_memory () in
  let capability = Eta.Tracer.as_capability tracer in
  let program =
    Eta.Effect.named "outer"
      (Eta.Effect.with_tracer capability
         (Eta.Effect.named "inner" Eta.Effect.unit))
    |> Eta.Effect.with_tracer capability
  in
  Expect.expect_ok (Eta.Runtime.run rt program);
  let spans = Eta.Tracer.dump tracer in
  let outer = find_span "outer" spans in
  let inner = find_span "inner" spans in
  Alcotest.(check (option int)) "same tracer parent" (Some outer.span_id)
    inner.parent_id;
  Alcotest.(check string) "same tracer trace" outer.trace_id inner.trace_id

let test_in_flight_real_sleep_ignores_later_override () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let eio_clock = Eio.Stdenv.clock stdenv in
  let sleep_started, mark_sleep_started = Eio.Promise.create () in
  let marked = ref false in
  let sleep duration =
    if not !marked then (
      marked := true;
      Eio.Promise.resolve mark_sleep_started ());
    Eio.Time.sleep eio_clock (Eta.Duration.to_seconds_float duration)
  in
  let now_ms () = int_of_float (Eio.Time.now eio_clock *. 1_000.0) in
  let rt = Eta_eio.Runtime.create ~sw ~clock:eio_clock ~sleep ~now_ms () in
  let started_at = Unix.gettimeofday () in
  let sleeping = fork_run sw rt (Eta.Effect.sleep (Eta.Duration.ms 30)) in
  Eio.Promise.await sleep_started;
  let override = recording_clock 999 in
  Alcotest.(check int) "later override is active only in its scope" 999
    (Eta.Runtime.run rt
       (Eta.Effect.with_clock (recording_clock_capability override)
          Eta.Effect.now_ms)
    |> Expect.expect_ok);
  Expect.expect_ok (Eio.Promise.await sleeping);
  let elapsed_ms = (Unix.gettimeofday () -. started_at) *. 1_000.0 in
  Alcotest.(check bool) "real sleep was not accelerated" true (elapsed_ms >= 20.0)

let test_daemon_failure_uses_inherited_override_diagnostics () =
  with_test_clock @@ fun _sw _base_clock rt ->
  let clock = recording_clock 123 in
  let logger = Eta.Logger.in_memory () in
  let tracer = Eta.Tracer.in_memory () in
  let start =
    Eta.Effect.daemon (Eta.Effect.die_message "daemon boom")
    |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
    |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
    |> Eta.Effect.with_random (Eta.Capabilities.random_of_seed 123)
    |> Eta.Effect.with_clock (recording_clock_capability clock)
  in
  Expect.expect_ok (Eta.Runtime.run rt start);
  Eta.Runtime.drain rt;
  (match Eta.Logger.dump logger with
  | [ record ] ->
      Alcotest.(check string) "daemon diagnostic sink" "eta.daemon.failure"
        record.body;
      Alcotest.(check int) "daemon diagnostic clock" 123 record.ts_ms
  | records ->
      Alcotest.failf "expected one daemon diagnostic, got %d"
        (List.length records));
  match Eta.Tracer.dump tracer with
  | [ span ] ->
      Alcotest.(check string) "daemon diagnostic tracer" "eta.daemon" span.name
  | spans ->
      Alcotest.failf "expected one daemon diagnostic span, got %d"
        (List.length spans)

let test_clock_adjust_wakes_in_deadline_order () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let sleeper ms =
    Eta.Effect.delay (Eta.Duration.ms ms) (Eta.Effect.named "record" (Eta.Effect.sync (fun () ->
        observed := ms :: !observed)))
  in
  let promise =
    fork_run sw rt (Eta.Effect.all [ sleeper 30; sleeper 10; sleeper 20 ])
  in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Eta.Duration.ms 30);
  ignore (Expect.expect_ok (Eio.Promise.await promise) : unit list);
  Alcotest.(check (list int)) "deadline order" [ 10; 20; 30 ]
    (List.rev !observed)

let test_clock_adjust_drains_cascading_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let observed = ref [] in
  let eff =
    Eta.Effect.delay (Eta.Duration.ms 10) (Eta.Effect.named "first" (Eta.Effect.sync (fun () ->
        observed := "first" :: !observed)))
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.delay (Eta.Duration.ms 10) (Eta.Effect.named "second" (Eta.Effect.sync (fun () ->
               observed := "second" :: !observed))))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Eta.Duration.ms 20);
  Expect.expect_ok (Eio.Promise.await promise);
  Alcotest.(check (list string)) "cascading sleeps" [ "first"; "second" ]
    (List.rev !observed)

let test_with_logger_captures_logs () =
  with_logger @@ fun _sw rt logger ->
  Expect.expect_ok (Eta.Runtime.run rt (Eta.Effect.log "hello"));
  match Eta.Logger.dump logger with
  | [ record ] -> Alcotest.(check string) "body" "hello" record.Eta.Logger.body
  | records -> Alcotest.failf "expected one log, got %d" (List.length records)

let test_with_tracer_captures_spans () =
  with_tracer @@ fun _sw rt tracer ->
  Expect.expect_ok
    (Eta.Runtime.run rt (Eta.Effect.named "span" (Eta.Effect.pure ())));
  match Eta.Tracer.dump tracer with
  | [ span ] -> Alcotest.(check string) "span" "span" span.Eta.Tracer.name
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

let test_with_logger_and_tracer_wires_both () =
  with_logger_and_tracer @@ fun _sw rt logger tracer ->
  Expect.expect_ok
    (Eta.Runtime.run rt (Eta.Effect.named "parent" (Eta.Effect.log "inside")));
  Alcotest.(check int) "logs" 1 (List.length (Eta.Logger.dump logger));
  Alcotest.(check int) "spans" 1 (List.length (Eta.Tracer.dump tracer))

let test_run_collects_one_execution_record () =
  let open Eta.Syntax in
  let program =
    Eta.Effect.named "workflow"
      (let* () = Eta.Effect.log_info "starting" in
       let* () =
         Eta.Effect.metric_counter ~name:"requests"
           (Eta.Capabilities.Int 1)
       in
       let* () = Eta.Effect.sleep (Eta.Duration.ms 10) in
       Eta.Effect.pure 42)
  in
  let outcome = Run.run ~seed:17 program in
  Alcotest.(check int) "exit" 42 (Expect.expect_ok outcome.exit);
  (match outcome.logs with
  | [ record ] ->
      Alcotest.(check string) "log" "starting" record.body;
      Alcotest.(check int) "log timestamp" 0 record.ts_ms
  | records -> Alcotest.failf "expected one log, got %d" (List.length records));
  (match outcome.spans with
  | [ span ] ->
      Alcotest.(check string) "span" "workflow" span.name;
      Alcotest.(check int) "span start" 0 span.started_ms;
      Alcotest.(check int) "span end" 10 span.ended_ms
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans));
  (match outcome.metrics with
  | [ point ] ->
      Alcotest.(check string) "metric" "requests" point.name;
      Alcotest.(check int) "metric timestamp" 0 point.ts_ms
  | points ->
      Alcotest.failf "expected one metric point, got %d" (List.length points));
  Run.expect_sleeps [ Eta.Duration.ms 10 ] outcome;
  Run.expect_no_pending_fibers outcome

let test_run_replays_with_same_construction () =
  let program =
    Eta.Effect.named "replay"
      (Eta.Effect.delay (Eta.Duration.ms 5) (Eta.Effect.pure "done"))
  in
  let first = Run.run ~seed:23 program in
  let second = Run.run ~seed:23 program in
  Alcotest.(check string) "first exit" "done" (Expect.expect_ok first.exit);
  Alcotest.(check string) "second exit" "done" (Expect.expect_ok second.exit);
  Alcotest.(check (list int)) "sleep replay"
    (List.map Eta.Duration.to_ms first.sleeps)
    (List.map Eta.Duration.to_ms second.sleeps);
  Alcotest.(check (list string)) "trace replay"
    (List.map (fun span -> span.Eta.Tracer.trace_id) first.spans)
    (List.map (fun span -> span.Eta.Tracer.trace_id) second.spans)

let fresh_sequence_in_new_test_runtime () =
  with_test_clock @@ fun _sw _clock rt ->
  let open Eta.Syntax in
  let program =
    let* first = Eta.Effect.fresh () in
    let* second = Eta.Effect.fresh () in
    let+ third = Eta.Effect.fresh () in
    [ first; second; third ]
  in
  Expect.expect_ok (Eta.Runtime.run rt program)

let test_fresh_replays_across_test_runtimes () =
  let first = fresh_sequence_in_new_test_runtime () in
  let second = fresh_sequence_in_new_test_runtime () in
  Alcotest.(check (list int)) "first runtime sequence" [ 1; 2; 3 ] first;
  Alcotest.(check (list int)) "fresh test runtime replay" first second

let test_fresh_map_par_contention () =
  with_test_clock @@ fun _sw _clock rt ->
  let count = 10_000 in
  let started = Unix.gettimeofday () in
  let values =
    List.init count Fun.id
    |> Eta.Effect.map_par ~max_concurrent:64 (fun _ -> Eta.Effect.fresh ())
    |> Eta.Runtime.run rt |> Expect.expect_ok
  in
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1_000.0 in
  let unique = List.sort_uniq Int.compare values in
  Alcotest.(check int) "map_par pulls" count (List.length values);
  Alcotest.(check int) "map_par unique values" count (List.length unique);
  Format.printf "fresh map_par: n=%d max_concurrent=64 unique=%d elapsed_ms=%.3f@."
    count (List.length unique) elapsed_ms

let test_audit_assertions_accept_matching_blueprints () =
  assert_pure_eff (Eta.Effect.pure 1 |> Eta.Effect.map (( + ) 1));
  assert_no_clock (Eta.Effect.sync (fun () -> ()));
  assert_no_logs (Eta.Effect.sleep Eta.Duration.zero);
  assert_no_metrics (Eta.Effect.log "hello");
  assert_no_concurrency (Eta.Effect.with_scope Eta.Effect.unit);
  assert_no_resources
    (Eta.Effect.par Eta.Effect.unit Eta.Effect.unit |> Eta.Effect.discard);
  assert_no_background
    (Eta.Effect.with_background Eta.Effect.unit (fun () -> Eta.Effect.unit))

let () =
  Alcotest.run "eta-test"
    [
      ( "Test_clock",
        [
          Alcotest.test_case "adjust wakes in deadline order" `Quick
            test_clock_adjust_wakes_in_deadline_order;
          Alcotest.test_case "adjust drains cascading sleeps" `Quick
            test_clock_adjust_drains_cascading_sleeps;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "with_logger" `Quick test_with_logger_captures_logs;
          Alcotest.test_case "with_tracer" `Quick test_with_tracer_captures_spans;
          Alcotest.test_case "with_logger_and_tracer" `Quick
            test_with_logger_and_tracer_wires_both;
        ] );
      ( "Run",
        [
          Alcotest.test_case "collects one execution record" `Quick
            test_run_collects_one_execution_record;
          Alcotest.test_case "replays with same construction" `Quick
            test_run_replays_with_same_construction;
        ] );
      ( "Scoped capabilities",
        [
          Alcotest.test_case "restore on all exit kinds" `Quick
            test_scoped_capabilities_restore_on_all_exit_kinds;
          Alcotest.test_case "fork inheritance" `Quick
            test_scoped_capabilities_fork_inherit;
          Alcotest.test_case "par sibling isolation both directions" `Quick
            test_scoped_capabilities_par_sibling_isolation_both_directions;
          Alcotest.test_case "nested innermost wins and restores outer" `Quick
            test_scoped_capabilities_nested_innermost_wins_and_restores_outer;
          Alcotest.test_case "clock controls sleep and timeout" `Quick
            test_with_clock_controls_sleep_and_timeout_without_wall_time;
          Alcotest.test_case "random controls retry jitter" `Quick
            test_with_random_controls_retry_jitter;
          Alcotest.test_case "logger sink composition" `Quick
            test_with_logger_replaces_sink_and_composes_before_it;
          Alcotest.test_case "daemon retains fork-time capabilities" `Quick
            test_daemon_retains_fork_time_capabilities_after_scope_exit;
          Alcotest.test_case "restore after runtime cancellation" `Quick
            test_scoped_capabilities_restore_after_runtime_cancellation;
          Alcotest.test_case "tracer override preserves open span" `Quick
            test_tracer_override_preserves_open_span_and_captured_tracer;
          Alcotest.test_case "same tracer nested override" `Quick
            test_same_tracer_nested_override_keeps_parent_context;
          Alcotest.test_case "in-flight real sleep ignores later override" `Quick
            test_in_flight_real_sleep_ignores_later_override;
          Alcotest.test_case "daemon failure uses inherited diagnostics" `Quick
            test_daemon_failure_uses_inherited_override_diagnostics;
        ] );
      ( "Fresh",
        [
          Alcotest.test_case "replays across test runtimes" `Quick
            test_fresh_replays_across_test_runtimes;
          Alcotest.test_case "map_par contention" `Quick
            test_fresh_map_par_contention;
        ] );
      ( "Audit assertions",
        [
          Alcotest.test_case "accept matching blueprints" `Quick
            test_audit_assertions_accept_matching_blueprints;
        ] );
    ]
