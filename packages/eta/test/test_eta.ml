open Eta
open Eta_test

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_ok test name expected = function
  | Exit.Ok actual -> Alcotest.check test name expected actual
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_error test name expected = function
  | Exit.Ok _ -> Alcotest.fail "expected Error"
  | Exit.Error cause -> Alcotest.check test name expected cause

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  f rt tracer

let with_sampled_traced_runtime sampler f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~sampler ()
  in
  f rt tracer

let with_auto_traced_runtime auto_instrument f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~auto_instrument ()
  in
  f rt tracer

let with_runtime_capture_backtrace capture_backtrace f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~capture_backtrace ()
  in
  f rt

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Runtime.run rt eff));
  promise

let dur_ms = Duration.ms
let some_dur = Alcotest.option (Alcotest.testable Duration.pp Duration.equal)
let dur = Alcotest.testable Duration.pp Duration.equal
let string_cause =
  Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)
let log_level = Alcotest.testable Log_level.pp Log_level.equal

let rec string_cause_contains expected = function
  | Cause.Fail actual -> String.equal expected actual
  | Cause.Die _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (string_cause_contains expected) causes
  | Cause.Suppressed { primary; finalizer } ->
      string_cause_contains expected primary
      || string_cause_contains expected finalizer

let check_string_cause_contains label expected cause =
  Alcotest.(check bool) label true (string_cause_contains expected cause)

let rec string_cause_has_suppressed_finalizer expected = function
  | Cause.Suppressed { primary = Cause.Interrupt _; finalizer } ->
      string_cause_contains expected finalizer
  | Cause.Suppressed { primary; finalizer } ->
      string_cause_has_suppressed_finalizer expected primary
      || string_cause_has_suppressed_finalizer expected finalizer
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (string_cause_has_suppressed_finalizer expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let check_suppressed_finalizer label expected cause =
  Alcotest.(check bool)
    label true (string_cause_has_suppressed_finalizer expected cause)

let check_concurrent_cause label cause =
  match cause with
  | Cause.Concurrent (_ :: _) -> ()
  | _ ->
      Alcotest.failf "%s: expected Concurrent cause, got %a" label
        (Cause.pp Format.pp_print_string) cause

let attr key span = List.assoc_opt key span.Tracer.attrs

let link_span_id span =
  List.map (fun link -> link.Tracer.link_span_id) span.Tracer.links

let only_span tracer =
  match Tracer.dump tracer with
  | [ span ] -> span
  | spans ->
      Alcotest.failf "expected one span, got %d" (List.length spans)

let check_status name expected actual =
  match (expected, actual) with
  | Tracer.Ok, Tracer.Ok -> ()
  | Tracer.Cancelled, Tracer.Cancelled -> ()
  | Tracer.Error _, Tracer.Error _ -> ()
  | _ -> Alcotest.failf "%s: unexpected span status" name

let check_error_message name expected actual =
  match actual with
  | Tracer.Error msg -> Alcotest.(check string) name expected msg
  | _ -> Alcotest.failf "%s: expected Error status" name

type observability_err = [ `Boom | `Db of int | `Inner | `Outer ]

let test_pure () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "pure" 42 (run_ok rt (Effect.pure 42))

let test_map () =
  with_runtime @@ fun rt ->
  let e = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
  Alcotest.(check int) "map" 2 (run_ok rt e)

let test_collect_names () =
  let e =
    Effect.concat
      [
        Effect.named "leaf-a" (Effect.sync (fun () -> ())) |> Effect.map (fun _ -> ());
        Effect.sync (fun () -> ());
        Effect.named "leaf-b" (Effect.sync (fun () -> ()));
      ]
    |> Effect.named "outer"
  in
  Alcotest.(check (list string))
    "names in pre-order"
    [ "outer"; "leaf-a"; "leaf-b" ]
    (Effect.collect_names e)

let test_tracer_manual_spans () =
  Eio_main.run @@ fun _stdenv ->
  Tracer.with_fiber_context @@ fun () ->
  let tracer = Tracer.in_memory () in
  let t = Tracer.as_capability tracer in
  t#add_attr ~key:"pending" ~value:"yes";
  let parent = t#begin_span ~name:"parent" ~started_ms:1 () in
  t#add_attr ~key:"inside" ~value:"parent";
  let child = t#begin_span ~name:"child" ~started_ms:2 () in
  t#end_span ~span_id:child ~status:Tracer.Ok ~ended_ms:3;
  t#end_span ~span_id:parent ~status:(Tracer.Error "boom") ~ended_ms:4;
  match Tracer.dump tracer with
  | [ child_span; parent_span ] ->
      Alcotest.(check int) "child parent" parent
        (Option.get child_span.Tracer.parent_id);
      Alcotest.(check (option string)) "pending attr" (Some "yes")
        (attr "pending" parent_span);
      Alcotest.(check (option string)) "inside attr" (Some "parent")
        (attr "inside" parent_span);
      check_status "child" Tracer.Ok child_span.status;
      check_status "parent" (Tracer.Error "boom") parent_span.status
  | spans -> Alcotest.failf "expected two spans, got %d" (List.length spans)

let test_observability_named_ok () =
  with_traced_runtime @@ fun rt tracer ->
  let eff = Effect.named "foo" (Effect.pure 1) in
  Alcotest.(check int) "value" 1 (run_ok rt eff);
  let span = only_span tracer in
  Alcotest.(check string) "name" "foo" span.name;
  check_status "status" Tracer.Ok span.status

let test_observability_span_kind () =
  with_traced_runtime @@ fun rt tracer ->
  run_ok rt (Effect.named_kind ~kind:Capabilities.Server "server" Effect.unit);
  let span = only_span tracer in
  Alcotest.(check bool) "server kind" true (span.kind = Tracer.Server)

let test_observability_fn_loc () =
  with_traced_runtime @@ fun rt tracer ->
  let program = Effect.fn __POS__ __FUNCTION__ (Effect.pure ()) in
  run_ok rt program;
  let span = only_span tracer in
  Alcotest.(check string) "name" __FUNCTION__ span.name;
  match attr "loc" span with
  | Some loc -> Alcotest.(check bool) "test file" true (String.contains loc '/')
  | None -> Alcotest.fail "missing loc attr"

let test_observability_annotation_order () =
  let run eff =
    with_traced_runtime @@ fun rt tracer ->
    run_ok rt eff;
    attr "k" (only_span tracer)
  in
  let inside =
    Effect.pure () |> Effect.annotate ~key:"k" ~value:"inside"
    |> Effect.named "span"
  in
  let outside =
    Effect.pure () |> Effect.named "span"
    |> Effect.annotate ~key:"k" ~value:"outside"
  in
  Alcotest.(check (option string)) "inside" (Some "inside") (run inside);
  Alcotest.(check (option string)) "outside" (Some "outside") (run outside)

let test_observability_nested_spans () =
  with_traced_runtime @@ fun rt tracer ->
  let eff =
    Effect.named "outer"
      (Effect.named "inner-a" (Effect.pure ())
      |> Effect.bind (fun () -> Effect.named "inner-b" (Effect.pure ())))
  in
  run_ok rt eff;
  match Tracer.dump tracer with
  | [ a; b; outer ] ->
      Alcotest.(check string) "outer" "outer" outer.name;
      Alcotest.(check (option int)) "a parent" (Some outer.span_id)
        a.parent_id;
      Alcotest.(check (option int)) "b parent" (Some outer.span_id)
        b.parent_id
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

let test_observability_statuses () =
  with_traced_runtime @@ fun rt tracer ->
  let fail_eff : (unit, observability_err) Effect.t =
    Effect.named "fail" (Effect.fail `Boom)
  in
  ignore (Runtime.run rt fail_eff : (unit, observability_err) Exit.t);
  let render_db : observability_err -> string = function
    | `Db code -> "db:" ^ string_of_int code
    | _ -> "<unexpected>"
  in
  let custom_eff : (unit, observability_err) Effect.t =
    Effect.named ~error_renderer:render_db "custom" (Effect.fail (`Db 42))
  in
  ignore
    (Runtime.run rt custom_eff : (unit, observability_err) Exit.t);
  let inner = Effect.named "inner" (Effect.fail `Inner) in
  let render_outer : observability_err -> string = function
    | `Outer -> "outer"
    | _ -> "<unexpected>"
  in
  let outer : (unit, observability_err) Effect.t =
    Effect.named ~error_renderer:render_outer "outer"
      (Effect.catch (function `Inner -> Effect.fail `Outer) inner)
  in
  ignore (Runtime.run rt outer : (unit, observability_err) Exit.t);
  ignore
    (Runtime.run rt
       (Effect.named "die" (Effect.sync (fun () -> failwith "boom"))) :
      (unit, _) Exit.t);
  ignore
    (Runtime.run rt
	       (Effect.named "interrupt"
	          (Effect.sync (fun () ->
	               raise (Eio.Cancel.Cancelled (Failure "cancel"))))) :
	      (unit, _) Exit.t);
  let spans = Tracer.dump tracer in
  let find name = List.find (fun span -> span.Tracer.name = name) spans in
  let fail_span = find "fail" in
  check_error_message "fail default" "<typed failure>" fail_span.status;
  (match fail_span.events with
  | [ event ] ->
      Alcotest.(check (option string))
        "fail exception message" (Some "<typed failure>")
        (List.assoc_opt "exception.message" event.Tracer.ev_attrs)
  | events ->
      Alcotest.failf "expected one fail exception event, got %d"
        (List.length events));
  let custom_span = find "custom" in
  check_error_message "custom status" "db:42" custom_span.status;
  (match custom_span.events with
  | [ event ] ->
      Alcotest.(check (option string))
        "custom exception message" (Some "db:42")
        (List.assoc_opt "exception.message" event.Tracer.ev_attrs)
  | events ->
      Alcotest.failf "expected one custom exception event, got %d"
        (List.length events));
  check_error_message "inner default" "<typed failure>" (find "inner").status;
  check_error_message "outer custom" "outer" (find "outer").status;
  check_status "die" (Tracer.Error "") (find "die").status;
  check_status "interrupt" Tracer.Cancelled (find "interrupt").status

let test_observability_concurrent_status () =
  with_traced_runtime @@ fun rt tracer ->
  let eff =
    Effect.named "concurrent" (Effect.race [ Effect.fail "a"; Effect.fail "b" ])
  in
  ignore (Runtime.run rt eff : (unit, string) Exit.t);
  let span = only_span tracer in
  check_status "concurrent" (Tracer.Error "") span.status

let test_observability_cancelled_parallel_child_status () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let slow =
    Effect.named "slow" (Effect.pure () |> Effect.delay (Duration.ms 10))
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure () ]) in
  wait_for_sleepers clock 1;
  check_exit_ok Alcotest.unit "race done" () (Eio.Promise.await promise);
  let slow_span =
    List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
  in
  check_status "slow cancelled" Tracer.Cancelled slow_span.status

let test_observability_uninterruptible_parallel_child_status () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let slow =
    Effect.named "slow"
      (Effect.pure () |> Effect.delay (Duration.ms 10) |> Effect.uninterruptible)
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure () ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "protected child still running" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.unit "race done" () (Eio.Promise.await promise);
  let slow_span =
    List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
  in
  check_status "slow ok" Tracer.Ok slow_span.status

let test_observability_par_children_inherit_parent () =
  with_traced_runtime @@ fun rt tracer ->
  let child name = Effect.named name (Effect.pure ()) in
  let eff = Effect.named "parent" (Effect.par (child "a") (child "b")) in
  ignore (run_ok rt eff);
  match Tracer.dump tracer with
  | [ a; b; parent ] ->
      Alcotest.(check (option int)) "a parent" (Some parent.span_id) a.parent_id;
      Alcotest.(check (option int)) "b parent" (Some parent.span_id) b.parent_id
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

let test_observability_par_pending_attrs_links_are_fiber_local () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let branch ~name ~delay ~attr_key ~link_span_id =
    Effect.pure ()
    |> Effect.named name
    |> Effect.delay (Duration.ms delay)
    |> Effect.link_span ~trace_id:("trace-" ^ name) ~span_id:link_span_id
    |> Effect.annotate ~key:attr_key ~value:"yes"
  in
  let promise =
    fork_run sw rt
      (Effect.par
         (branch ~name:"left" ~delay:10 ~attr_key:"left" ~link_span_id:"left-link")
         (branch ~name:"right" ~delay:5 ~attr_key:"right" ~link_span_id:"right-link"))
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok (Alcotest.pair Alcotest.unit Alcotest.unit) "par done" ((), ())
    (Eio.Promise.await promise);
  let spans = Tracer.dump tracer in
  let left = List.find (fun span -> span.Tracer.name = "left") spans in
  let right = List.find (fun span -> span.Tracer.name = "right") spans in
  Alcotest.(check (option string)) "left has left attr" (Some "yes")
    (attr "left" left);
  Alcotest.(check (option string)) "left has no right attr" None
    (attr "right" left);
  Alcotest.(check (list string)) "left links" [ "left-link" ]
    (link_span_id left);
  Alcotest.(check (option string)) "right has right attr" (Some "yes")
    (attr "right" right);
  Alcotest.(check (option string)) "right has no left attr" None
    (attr "left" right);
  Alcotest.(check (list string)) "right links" [ "right-link" ]
    (link_span_id right)

let test_observability_sampler_always_off () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt tracer ->
  run_ok rt (Effect.named "off" Effect.unit);
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_sampler_ratio () =
  with_sampled_traced_runtime (Sampler.ratio 0.5) @@ fun rt tracer ->
  let spans =
    List.init 1_000 (fun i -> Effect.named ("span-" ^ string_of_int i) Effect.unit)
  in
  run_ok rt (Effect.concat spans);
  let count = List.length (Tracer.dump tracer) in
  Alcotest.(check bool) "roughly half sampled" true (count > 350 && count < 650)

let test_observability_sampler_parent_based () =
  with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun rt tracer ->
  run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
  Alcotest.(check int) "parent and child sampled" 2
    (List.length (Tracer.dump tracer));
  with_sampled_traced_runtime
    (Sampler.parent_based ~root:Sampler.always_off ())
  @@ fun rt tracer ->
  run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
  Alcotest.(check int) "unsampled parent suppresses child" 0
    (List.length (Tracer.dump tracer))

let test_observability_sampler_unsampled_parent_suppresses_par_children () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt tracer ->
  let child name = Effect.named name Effect.unit in
  ignore (run_ok rt (Effect.named "parent" (Effect.par (child "a") (child "b"))));
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_noop_runtime_keeps_die_diagnostics () =
  with_runtime @@ fun rt ->
  let exn = Failure "noop diagnostic" in
  let eff =
    Effect.sync (fun () -> raise exn)
    |> Effect.annotate ~key:"request.id" ~value:"noop-1"
    |> Effect.named "noop.span"
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check bool) "same exception" true (die.exn == exn);
      Alcotest.(check (option string)) "span name" (Some "noop.span")
        die.span_name;
      Alcotest.(check (option string)) "annotation" (Some "noop-1")
        (List.assoc_opt "request.id" die.annotations)
  | _ -> Alcotest.fail "expected Die with noop runtime diagnostics"

let test_trace_context_extract_inject () =
  let ctx =
    Trace_context.extract
      [
        ( "TraceParent",
          "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" );
        ("tracestate", "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE");
        ("baggage", "tenant=acme,plan=pro");
      ]
  in
  match ctx with
  | None -> Alcotest.fail "expected valid trace context"
  | Some ctx ->
      Alcotest.(check string) "trace_id"
        "4bf92f3577b34da6a3ce929d0e0e4736" ctx.trace_id;
      Alcotest.(check int) "trace_flags" 1 ctx.trace_flags;
      Alcotest.(check (option string)) "tracestate" (Some "t61rcWkgMzE")
        (List.assoc_opt "congo" ctx.trace_state);
      Alcotest.(check (option string)) "baggage" (Some "acme")
        (List.assoc_opt "tenant" ctx.baggage);
      Alcotest.(check (option string)) "traceparent injected"
        (Some "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        (List.assoc_opt "traceparent" (Trace_context.inject ctx))

let test_trace_context_rejects_malformed_traceparent () =
  let bad =
    Trace_context.extract
      [
        ( "traceparent",
          "00-00000000000000000000000000000000-00f067aa0ba902b7-01" );
      ]
  in
  Alcotest.(check bool) "all-zero trace rejected" true (Option.is_none bad)

let test_trace_context_current_and_par_inherit_baggage () =
  with_traced_runtime @@ fun rt _tracer ->
  let ctx =
    Option.get
      (Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
         ~span_id:"00f067aa0ba902b7" ~trace_state:[ ("rojo", "1") ]
         ~baggage:[ ("tenant", "acme") ] ())
  in
  let left = Effect.current_context in
  let right = Effect.current_context in
  let a, b = run_ok rt (Effect.with_context ctx (Effect.par left right)) in
  let check name (ctx : Capabilities.trace_context option) =
    match ctx with
    | None -> Alcotest.fail (name ^ " missing context")
    | Some ctx ->
        Alcotest.(check (option string)) name (Some "acme")
          (List.assoc_opt "tenant" ctx.baggage)
  in
  check "left baggage" a;
  check "right baggage" b

let test_trace_context_unsampled_parent_suppresses_child () =
  with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun rt tracer ->
  let ctx =
    Option.get
      (Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
         ~span_id:"00f067aa0ba902b7" ~trace_flags:0 ())
  in
  run_ok rt (Effect.with_context ctx (Effect.named "child" Effect.unit));
  Alcotest.(check int) "unsampled parent suppresses child span" 0
    (List.length (Tracer.dump tracer))

let test_observability_auto_instrument_default_off () =
  with_traced_runtime @@ fun rt tracer ->
  run_ok rt (Effect.sync (fun () -> ()));
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_auto_instrument_eval_leaves () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.named name (Effect.sync (fun () -> ())) in
  run_ok rt (Effect.concat [ leaf "a"; Effect.sync (fun () -> ()); leaf "b"; leaf "c" ]);
  Alcotest.(check (list string)) "leaf spans" [ "a"; "b"; "c" ]
    (List.map (fun span -> span.Tracer.name) (Tracer.dump tracer))

let test_observability_auto_instrument_leaves_nest_under_named () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.named name (Effect.sync (fun () -> ())) in
  run_ok rt (Effect.named "outer" (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]));
  let spans = Tracer.dump tracer in
  let outer = List.find (fun span -> span.Tracer.name = "outer") spans in
  let children = List.filter (fun span -> span.Tracer.name <> "outer") spans in
  List.iter
    (fun span ->
      Alcotest.(check (option int)) span.Tracer.name (Some outer.span_id)
        span.parent_id)
    children

let test_observability_auto_instrument_failure_status () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  ignore (Runtime.run rt (Effect.named "boom" (Effect.sync (fun () -> failwith "boom"))) :
            (unit, _) Exit.t);
  let span = only_span tracer in
  check_status "leaf failed" (Tracer.Error "") span.status;
  match span.events with
  | [ event ] ->
      Alcotest.(check (option string)) "leaf cause path" (Some "cause")
        (List.assoc_opt "eta.cause.path" event.Tracer.ev_attrs);
      Alcotest.(check bool) "leaf stacktrace" true
        (Option.is_some
           (List.assoc_opt "exception.stacktrace" event.Tracer.ev_attrs))
  | events ->
      Alcotest.failf "expected one exception event, got %d" (List.length events)

let test_observability_all_for_each_supervisor_inherit_parent () =
  with_traced_runtime @@ fun rt tracer ->
  let child name = Effect.named name (Effect.pure ()) in
  let supervised =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift (child "supervised"))
          in
          await child;
    }
  in
  let eff =
    Effect.named "parent"
      (Effect.all [ child "all-a"; child "all-b" ]
      |> Effect.bind (fun _ ->
             Effect.for_each_par [ "each-a"; "each-b" ] child)
      |> Effect.bind (fun _ -> supervised))
  in
  run_ok rt eff;
  let spans = Tracer.dump tracer in
  let parent = List.find (fun span -> span.Tracer.name = "parent") spans in
  let children = List.filter (fun span -> span.Tracer.name <> "parent") spans in
  List.iter
    (fun span ->
      Alcotest.(check (option int)) span.Tracer.name (Some parent.span_id)
        span.parent_id)
    children

let test_duration_constructors () =
  Alcotest.(check dur) "seconds" (Duration.ms 1_000) (Duration.seconds 1);
  Alcotest.(check dur) "minutes" (Duration.seconds 60) (Duration.minutes 1);
  Alcotest.(check dur) "hours" (Duration.minutes 60) (Duration.hours 1);
  Alcotest.(check dur) "days" (Duration.hours 24) (Duration.days 1);
  Alcotest.(check dur) "weeks" (Duration.days 7) (Duration.weeks 1)

let test_duration_ordering () =
  Alcotest.(check int) "lt" (-1)
    (Duration.compare (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check int) "eq" 0
    (Duration.compare (Duration.ms 2) (Duration.ms 2));
  Alcotest.(check int) "gt" 1
    (Duration.compare (Duration.ms 2) (Duration.ms 1));
  Alcotest.(check bool) "between" true
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.hours 1))

let test_duration_algebra () =
  Alcotest.(check dur) "sum" (Duration.minutes 1)
    (Duration.add (Duration.seconds 30) (Duration.seconds 30));
  Alcotest.(check dur) "subtract clamps at zero" Duration.zero
    (Duration.subtract (Duration.seconds 30) (Duration.seconds 40));
  Alcotest.(check dur) "times" (Duration.minutes 1)
    (Duration.times (Duration.seconds 1) 60);
  Alcotest.(check some_dur) "divide" (Some (Duration.seconds 30))
    (Duration.divide (Duration.minutes 1) 2);
  Alcotest.(check some_dur) "divide by zero" None
    (Duration.divide (Duration.minutes 1) 0)

let test_duration_min_max_clamp () =
  Alcotest.(check dur) "max" (Duration.ms 2)
    (Duration.max (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "min" (Duration.ms 1)
    (Duration.min (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "clamp lower" (Duration.ms 2)
    (Duration.clamp ~min:(Duration.ms 2) ~max:(Duration.ms 3)
       (Duration.ms 1));
  Alcotest.(check dur) "clamp inside" (Duration.minutes 90)
    (Duration.clamp ~min:(Duration.minutes 60) ~max:(Duration.minutes 120)
       (Duration.minutes 90))

let test_recurs () =
  let s = Schedule.recurs 3 in
  Alcotest.(check some_dur) "0" (Some Duration.zero)
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "exhausted" None
    (Schedule.next_delay s ~step:3)

let test_exponential () =
  let s = Schedule.exponential ~factor:2.0 (dur_ms 10) in
  Alcotest.(check some_dur) "step 0" (Some (dur_ms 10))
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "step 2 = 40ms" (Some (dur_ms 40))
    (Schedule.next_delay s ~step:2)

let test_spaced_fixed_linear () =
  Alcotest.(check some_dur) "spaced" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.spaced (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "fixed" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.fixed (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "linear step 3" (Some (Duration.seconds 7))
    (Schedule.next_delay
       (Schedule.linear ~initial:(Duration.seconds 1)
          ~step:(Duration.seconds 2))
       ~step:3)

let test_schedule_composition () =
  Alcotest.(check some_dur) "both takes max" (Some (Duration.seconds 2))
    (Schedule.next_delay
       (Schedule.both (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "either takes min" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.either (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "and_then falls through" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.spaced (Duration.seconds 1)))
       ~step:1)

let test_schedule_jittered_uses_random_capability () =
  let random = Capabilities.random_of_seed 17 in
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:1.0 ~max:2.0
  in
  Alcotest.(check some_dur) "jittered factor from capability"
    (Some (Duration.ms 139))
    (Schedule.next_delay ~random schedule ~step:0);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check int) "inclusive range" 13
    (Random.int_in_range random ~min:10 ~max:20);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (float 0.0000001))
    "float range" 1.6656494140625
    (Random.float_in_range random ~min:1.0 ~max:3.0);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check bool) "bool" false (Random.bool random);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (list int)) "shuffle" [ 4; 3; 1; 2 ]
    (Random.shuffle random [ 1; 2; 3; 4 ]);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (option string))
    "weighted choice" (Some "b")
    (Random.weighted_choice random [ ("a", 1.0); ("b", 2.0); ("c", 1.0) ]);
  let random = Capabilities.random_of_seed 7 in
  Alcotest.(check (option int)) "sample" (Some 20)
    (Random.sample random [ 10; 20; 30; 40 ]);
  Alcotest.(check (option int)) "empty" None (Random.sample random [])

let test_effect_map_bind_tap_runtime () =
  with_runtime @@ fun rt ->
  let observed = ref [] in
  let eff =
    Effect.pure 1
    |> Effect.map (fun n -> n + 1)
    |> Effect.bind (fun n -> Effect.pure (n * 2))
    |> Effect.tap (fun n ->
           Effect.named "tap" (Effect.sync (fun () -> observed := n :: !observed)))
    |> Effect.map (fun n -> n + 1)
  in
  Alcotest.(check int) "value" 5 (run_ok rt eff);
  Alcotest.(check (list int)) "tap saw pre-map value" [ 4 ] !observed

let test_effect_catch_success_and_failure () =
  with_runtime @@ fun rt ->
  let success =
    Effect.pure 1
    |> Effect.catch (fun (`Unexpected : [ `Unexpected ]) ->
           Effect.fail `Handler_ran)
  in
  let failure =
    Effect.fail `First
    |> Effect.catch (fun (`First : [ `First ]) -> Effect.fail `Second)
    |> Effect.catch (fun (`Second : [ `Second ]) -> Effect.pure "recovered")
  in
  Alcotest.(check int) "success bypasses catch" 1 (run_ok rt success);
  Alcotest.(check string) "failure recovers" "recovered" (run_ok rt failure)

let test_effect_catch_handler_failure_uses_outer_key () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.fail `Inner
    |> Effect.catch (fun (`Inner : [ `Inner ]) -> Effect.fail `Outer)
  in
  Expect.expect_typed_failure_eq
    (Alcotest.testable
       (fun fmt -> function
         | `Inner -> Format.pp_print_string fmt "inner"
         | `Outer -> Format.pp_print_string fmt "outer")
       ( = ))
    (Runtime.run rt eff) `Outer

let test_effect_tap_error_observes_and_rethrows () =
  with_runtime @@ fun rt ->
  let observed = ref false in
  let eff =
    Effect.fail `Boom
    |> Effect.tap_error (fun (`Boom : [ `Boom ]) -> observed := true)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "recovered")
  in
  Alcotest.(check string) "recovered" "recovered" (run_ok rt eff);
  Alcotest.(check bool) "observed" true !observed

let test_runtime_exit_fail_die_interrupt () =
  with_runtime @@ fun rt ->
  let die = Failure "boom" in
  let fail_exit = Runtime.run rt (Effect.fail "bad") in
  let die_exit = Runtime.run rt (Effect.named "die" (Effect.sync (fun () -> raise die))) in
  let interrupt_exit =
    Runtime.run rt
      (Effect.named "interrupt" (Effect.sync (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "cancel")))))
  in
  Expect.expect_typed_failure_eq Alcotest.string fail_exit "bad";
  Expect.expect_die die_exit (fun actual -> actual.exn == die);
  Expect.expect_interrupt interrupt_exit

let test_runtime_die_captures_diagnostics () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt _tracer ->
  let exn = Failure "diagnostic boom" in
  let eff =
    Effect.named "die.leaf" (Effect.sync (fun () -> raise exn))
    |> Effect.annotate ~key:"request.id" ~value:"r-1"
    |> Effect.fn __POS__ "diagnostic.fn"
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check bool) "same exception" true (die.exn == exn);
      Alcotest.(check (option string)) "span name" (Some "die.leaf")
        die.span_name;
      Alcotest.(check (option string)) "annotation" (Some "r-1")
        (List.assoc_opt "request.id" die.annotations);
      Alcotest.(check bool) "loc annotation exists" true
        (Option.is_some (List.assoc_opt "loc" die.annotations));
      Alcotest.(check bool) "backtrace captured" true
        (Option.is_some die.backtrace)
  | _ -> Alcotest.fail "expected Die with diagnostics"

let test_cause_to_portable_materializes_diagnostics () =
  let backtrace = Printexc.get_callstack 4 in
  let raw =
    Cause.suppressed ~primary:(Cause.fail "typed")
      ~finalizer:
        (Cause.die_with_diagnostics ~backtrace ~span_name:"release"
           ~annotations:[ ("phase", "release") ] (Failure "boom"))
  in
  match Cause.to_portable Fun.id raw with
  | Cause.Portable.Suppressed
      {
        primary = Cause.Portable.Fail "typed";
        finalizer =
          Cause.Portable.Die
            {
              message = "Failure(\"boom\")";
              backtrace = Some stack;
              span_name = Some "release";
              annotations = [ ("phase", "release") ];
              _;
            };
      } ->
      Alcotest.(check bool) "stack materialized" true (String.length stack > 0)
  | portable ->
      Alcotest.failf "unexpected portable cause: %a"
        (Cause.Portable.pp Format.pp_print_string)
        portable

let test_runtime_die_capture_backtrace_can_be_disabled () =
  with_runtime_capture_backtrace false @@ fun rt ->
  match
    Runtime.run rt (Effect.named "die.no-backtrace" (Effect.sync (fun () -> failwith "boom")))
  with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check (option string)) "no backtrace" None
        (Option.map Printexc.raw_backtrace_to_string die.backtrace)
  | _ -> Alcotest.fail "expected Die"

let test_runtime_run_exn_uses_captured_backtrace () =
  with_runtime @@ fun rt ->
  let exn = Failure "run_exn defect" in
  match Runtime.run_exn rt (Effect.named "die.run_exn" (Effect.sync (fun () -> raise exn))) with
  | _ -> Alcotest.fail "expected exception"
  | exception actual ->
      Alcotest.(check bool) "same exception" true (actual == exn);
      let backtrace = Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()) in
      Alcotest.(check bool) "backtrace not empty" true (String.length backtrace > 0)

let test_runtime_concurrent_child_die_captures_diagnostics () =
  with_runtime @@ fun rt ->
  let left_ready, left_resolver = Eio.Promise.create () in
  let right_ready, right_resolver = Eio.Promise.create () in
  let child name own_ready other_ready =
    Effect.named name (Effect.sync (fun () ->
        Eio.Promise.resolve own_ready ();
        Eio.Promise.await other_ready;
        raise (Failure name)))
    |> Effect.annotate ~key:"branch" ~value:name
    |> Effect.named (name ^ ".span")
  in
  let eff =
    Effect.par
      (child "left" left_resolver right_ready)
      (child "right" right_resolver left_ready)
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Concurrent causes) ->
      let dies : Cause.die list =
        List.filter_map
          (function Cause.Die die -> Some die | _ -> None)
          causes
      in
      Alcotest.(check (list string)) "child spans"
        [ "left"; "right" ]
        (dies
        |> List.map (fun die -> Option.value die.Cause.span_name ~default:"")
        |> List.sort String.compare);
      List.iter
        (fun die ->
          let expected =
            match die.Cause.span_name with
            | Some "left" -> Some "left"
            | Some "right" -> Some "right"
            | _ -> None
          in
          Alcotest.(check (option string)) "branch annotation" expected
            (List.assoc_opt "branch" die.Cause.annotations))
        dies
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent Die causes, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "expected concurrent child defects"

let test_runtime_finalizer_die_captures_diagnostics () =
  with_runtime @@ fun rt ->
  let body_exn = Failure "body defect" in
  let release_exn = Failure "release defect" in
  let release () =
    Effect.named "release.leaf" (Effect.sync (fun () -> raise release_exn))
    |> Effect.annotate ~key:"phase" ~value:"release"
    |> Effect.named "release.span"
  in
  let body =
    Effect.named "body.leaf" (Effect.sync (fun () -> raise body_exn))
    |> Effect.named "body.span"
  in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ()) ~release
      |> Effect.bind (fun () -> body))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Die primary; finalizer = Cause.Die finalizer }) ->
      Alcotest.(check bool) "primary exn" true (primary.exn == body_exn);
      Alcotest.(check (option string)) "primary span" (Some "body.leaf")
        primary.span_name;
      Alcotest.(check bool) "finalizer exn" true (finalizer.exn == release_exn);
      Alcotest.(check (option string)) "finalizer span" (Some "release.leaf")
        finalizer.span_name;
      Alcotest.(check (option string)) "finalizer annotation" (Some "release")
        (List.assoc_opt "phase" finalizer.annotations)
  | Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a" (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.fail "expected finalizer Die"

let test_effect_catch_does_not_catch_interrupt () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.named "interrupt" (Effect.sync (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel"))))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt"

let test_effect_retry_does_not_retry_interrupt () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.named "interrupt" (Effect.sync (fun () ->
        incr attempts;
        raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  let eff = Effect.retry (Schedule.recurs 3) (fun (_ : string) -> true) attempt in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt");
  Alcotest.(check int) "not retried" 1 !attempts

let test_acquire_release () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.named name (Effect.sync (fun () -> trail := name :: !trail)) in
  let eff =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(mark "acquired" |> Effect.map (fun () -> 1))
         ~release:(fun _ -> mark "released")
      |> Effect.bind (fun _ -> mark "body"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail)

let test_acquire_release_on_failure () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.named name (Effect.sync (fun () -> trail := name :: !trail)) in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(mark "acq") ~release:(fun () ->
           mark "rel")
      |> Effect.bind (fun () -> Effect.fail `Boom)
      |> Effect.catch (fun (`Boom : [ `Boom ]) -> mark "caught"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "release after recovered body failure"
    [ "acq"; "caught"; "rel" ] (List.rev !trail)

let test_acquire_release_suppresses_release_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.fail "body"))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail "body"; finalizer = Cause.Fail "release" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed release failure, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok () -> Alcotest.fail "expected suppressed release failure"

let test_acquire_release_release_failure_after_success () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.pure "body"))
  in
  check_exit_error string_cause "release failure" (Cause.Fail "release")
    (Runtime.run rt eff)

let test_effect_timeout_uses_virtual_clock () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  check_exit_ok Alcotest.string "timed out" "timeout"
    (Eio.Promise.await promise)

let test_effect_timeout_allows_fast_success () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 2)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 2);
  check_exit_ok Alcotest.string "completed" "done"
    (Eio.Promise.await promise)

let test_effect_timeout_nested_cancel_maps_to_outer_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let inner =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 10)
  in
  let eff =
    inner
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) ->
           Effect.fail `Total_timeout)
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Total_timeout) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected mapped timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected mapped timeout"

type typed_timeout_err = [ `Slow | `Inner | `Outer ]

let test_effect_timeout_as_keeps_exact_error_row () =
  with_runtime @@ fun rt ->
  let eff : (string, [ `Slow ]) Effect.t =
    Effect.pure "ok"
    |> Effect.timeout_as (Duration.seconds 1) ~on_timeout:`Slow
  in
  Alcotest.(check string) "ok" "ok" (run_ok rt eff)

let test_effect_timeout_as_maps_delayed_effect () =
  with_test_clock @@ fun sw clock rt ->
  let eff : (string, typed_timeout_err) Effect.t =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Slow
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Slow) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected typed timeout"

let test_effect_timeout_as_nested_cancel_maps_to_outer_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let inner : (string, typed_timeout_err) Effect.t =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout_as (Duration.seconds 10) ~on_timeout:`Inner
  in
  let eff =
    inner |> Effect.timeout_as (Duration.seconds 5) ~on_timeout:`Outer
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Outer) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected outer typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected outer typed timeout"

let test_effect_race_ignores_early_failure_until_success () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_success ms value =
    Effect.pure value |> Effect.delay (Duration.ms ms)
  in
  let eff =
    Effect.race
      [
        Effect.fail `Boom |> Effect.delay Duration.zero;
        delayed_success 200 200;
        delayed_success 100 100;
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "race sleepers registered" 2
    (Test_clock.sleeper_count clock);
  Test_clock.adjust clock (Duration.ms 100);
  Alcotest.(check int)
    "first success wins" 100
    (Expect.expect_ok (Eio.Promise.await promise))

let test_effect_race_all_failures_returns_concurrent_causes () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let eff = Effect.race [ delayed_failure 0 "first"; delayed_failure 10 "second" ] in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_error string_cause "failures combined"
    (Cause.Concurrent [ Cause.Fail "first"; Cause.Fail "second" ])
    (Eio.Promise.await promise)

let test_par_simultaneous_failures_records_concurrent_baseline () =
  with_test_clock @@ fun sw _clock rt ->
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let child name =
    Effect.named name (Effect.sync (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go))
    |> Effect.bind (fun () -> Effect.fail name)
  in
  let promise = fork_run sw rt (Effect.par (child "left") (child "right")) in
  let first = Eio.Stream.take ready in
  let second = Eio.Stream.take ready in
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected simultaneous failure"
  | Exit.Error cause ->
      check_concurrent_cause "par simultaneous failure baseline" cause;
      check_string_cause_contains "first child observed" first cause;
      check_string_cause_contains "second child observed" second cause

let test_par_finalizer_failure_during_sibling_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let slow =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:
           (Effect.named "par.slow.acquire" (Effect.sync (fun () ->
                Eio.Promise.resolve acquired_u ())))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.named "par.body.wait_for_acquire" (Effect.sync (fun () ->
        Eio.Promise.await acquired))
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let promise = fork_run sw rt (Effect.par body slow) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "par cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "release" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before par returned" true !release_started

let test_all_finalizer_failure_during_sibling_cancellation_baseline () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let slow =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:
           (Effect.named "slow.acquire" (Effect.sync (fun () ->
                Eio.Promise.resolve acquired_u ())))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.named "body.wait_for_acquire" (Effect.sync (fun () -> Eio.Promise.await acquired))
    |> Effect.bind (fun () -> Effect.fail "body")
  in
  let promise = fork_run sw rt (Effect.all [ body; slow ]) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "all cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "release" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before all returned" true !release_started

let test_for_each_par_simultaneous_failures_baseline () =
  with_test_clock @@ fun sw _clock rt ->
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let worker name =
    Effect.named ("worker." ^ name) (Effect.sync (fun () ->
        if name <> "ok" then (
          Eio.Stream.add ready name;
          Eio.Promise.await go);
        name))
    |> Effect.bind (fun name ->
           if name = "ok" then Effect.pure name else Effect.fail name)
  in
  let promise =
    fork_run sw rt (Effect.for_each_par [ "left"; "right"; "ok" ] worker)
  in
  let first = Eio.Stream.take ready in
  let second = Eio.Stream.take ready in
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected for_each_par failure"
  | Exit.Error cause ->
      check_concurrent_cause "for_each_par simultaneous baseline" cause;
      check_string_cause_contains "first item observed" first cause;
      check_string_cause_contains "second item observed" second cause

let test_for_each_par_finalizer_failure_during_sibling_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let acquired, acquired_u = Eio.Promise.create () in
  let release_started = ref false in
  let worker = function
    | "slow" ->
        Effect.scoped
          (Effect.acquire_release
             ~acquire:
               (Effect.named "foreach.slow.acquire" (Effect.sync (fun () ->
                    Eio.Promise.resolve acquired_u ())))
             ~release:(fun () ->
               release_started := true;
               Effect.fail "release")
          |> Effect.bind (fun () ->
                 Effect.delay (Duration.ms 1_000) Effect.unit))
    | "body" ->
        Effect.named "foreach.body.wait_for_acquire" (Effect.sync (fun () ->
            Eio.Promise.await acquired))
        |> Effect.bind (fun () -> Effect.fail "body")
    | _ -> Effect.unit
  in
  let promise = fork_run sw rt (Effect.for_each_par [ "body"; "slow" ] worker) in
  wait_for_sleepers clock 1;
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected body/finalizer failure"
  | Exit.Error cause ->
      check_concurrent_cause "for_each_par cancellation/finalizer failure" cause;
      check_string_cause_contains "body failure observed" "body" cause;
      check_suppressed_finalizer
        "cancelled sibling release failure is suppressed under interrupt"
        "release" cause;
      Alcotest.(check bool)
        "cancelled sibling finalizer ran before for_each_par returned" true
        !release_started

let test_par_nested_race_all_failures_baseline () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let nested =
    Effect.race
      [ delayed_failure 0 "race-left"; delayed_failure 10 "race-right" ]
  in
  let promise =
    fork_run sw rt
      (Effect.par nested (Effect.pure () |> Effect.delay (Duration.ms 20)))
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 10);
  match Eio.Promise.await promise with
  | Exit.Ok _ -> Alcotest.fail "expected nested race failure"
  | Exit.Error cause ->
      check_concurrent_cause "par nested race baseline" cause;
      check_string_cause_contains "nested first failure observed" "race-left" cause;
      check_string_cause_contains "nested second failure observed" "race-right" cause

let test_effect_repeat_schedule () =
  with_runtime @@ fun rt ->
  let ticks = ref 0 in
  let tick = Effect.named "tick" (Effect.sync (fun () -> incr ticks)) in
  run_ok rt (Effect.repeat (Schedule.recurs 3) tick);
  Alcotest.(check int) "initial run plus three repeats" 4 !ticks

let test_effect_repeat_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let ticks = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
  in
  let promise =
    fork_run sw rt (Effect.named "tick" (Effect.sync (fun () -> incr ticks)) |> Effect.repeat schedule)
  in
  yield ();
  Alcotest.(check int) "initial tick" 1 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second tick" 2 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "third tick" 3 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.unit "repeat done" () (Eio.Promise.await promise);
  Alcotest.(check int) "three delayed repeats" 4 !ticks

let test_effect_retry_schedule_until_success () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  Alcotest.(check int) "succeeded" 3
    (run_ok rt (Effect.retry (Schedule.recurs 5) (fun (`Again _) -> true) attempt))

let test_effect_retry_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let attempts = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 5) (Schedule.spaced (Duration.ms 5))
  in
  let attempt =
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (fun (`Again _) -> true) attempt)
  in
  yield ();
  Alcotest.(check int) "first attempt before delay" 1 !attempts;
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.int "succeeded on delayed third attempt" 3
    (Eio.Promise.await promise)

let test_effect_retry_jittered_schedule_uses_runtime_random () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock)
      ~random:(Capabilities.random_of_seed 17)
      ()
  in
  let attempts = ref 0 in
  let schedule =
    Schedule.spaced (Duration.ms 100)
    |> Schedule.jittered ~min:1.0 ~max:2.0
  in
  let attempt =
    Effect.named "attempt" (Effect.sync (fun () ->
        incr attempts;
        !attempts))
    |> Effect.bind (fun n ->
           if n < 2 then Effect.fail (`Again n) else Effect.pure n)
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (fun (`Again _) -> true) attempt)
  in
  yield ();
  Alcotest.(check int) "first attempt" 1 !attempts;
  Test_clock.adjust clock (Duration.ms 138);
  yield ();
  Alcotest.(check int) "still sleeping" 1 !attempts;
  Test_clock.adjust clock (Duration.ms 1);
  check_exit_ok Alcotest.int "retry result" 2 (Eio.Promise.await promise)

let test_supervisor_observes_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          failures sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Ok [ Cause.Fail `Boom ] -> ()
  | _ -> Alcotest.fail "expected observed child failure"

let test_supervisor_await_rethrows_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Fail `Boom) -> ()
  | _ -> Alcotest.fail "expected await to rethrow child failure"

let test_supervisor_cancel_runs_finalizer () =
  with_test_clock @@ fun _sw clock rt ->
  let finalizer_ran = ref false in
  let child =
    Effect.acquire_release
      ~acquire:(Effect.named "supervisor.acquire" (Effect.sync (fun () -> ())))
      ~release:(fun () ->
        Effect.named "supervisor.release" (Effect.sync (fun () -> finalizer_ran := true)))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
  in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () =
            lift
              (Effect.named "supervisor.wait_for_child" (Effect.sync (fun () ->
                   wait_for_sleepers clock 1)))
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) ->
      Alcotest.(check bool) "finalizer ran" true !finalizer_ran
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_cancel_before_await_does_not_deadlock () =
  with_test_clock @@ fun _sw _clock rt ->
  let child = Effect.delay (Duration.ms 1_000) Effect.unit in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_scope_cancels_unawaited_children_on_return () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let child_started, child_started_resolver = Eio.Promise.create () in
  let released = Atomic.make false in
  let child =
    Effect.acquire_release
      ~acquire:
        (Effect.sync (fun () ->
             Eio.Promise.resolve child_started_resolver ();
             ()))
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
    |> Effect.bind (fun () -> Effect.sync Eio.Fiber.await_cancel)
  in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () =
            lift (Effect.sync (fun () -> Eio.Promise.await child_started))
          in
          pure ();
    }
  in
  let result =
    Eio.Fiber.first
      (fun () ->
        match Runtime.run rt program with
        | Exit.Ok () -> `Returned
        | Exit.Error cause -> `Failed cause)
      (fun () ->
        Eio.Time.sleep (Eio.Stdenv.clock stdenv) 0.1;
        `Timed_out)
  in
  (match result with
  | `Returned -> ()
  | `Timed_out -> Alcotest.fail "supervisor scope waited on unawaited child"
  | `Failed cause ->
      Alcotest.failf "unexpected supervisor failure: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause);
  Alcotest.(check bool) "child finalizer ran" true (Atomic.get released)

let test_supervisor_threshold_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped ~max_failures:1 {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child :
                  (s, [> `Boom | `Supervisor_failed of int ], int)
                  Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          check sup;
    }
  in
  match Runtime.run rt program with
| Exit.Error (Cause.Fail (`Supervisor_failed 1)) -> ()
| _ -> Alcotest.fail "expected supervisor threshold failure"

let test_supervisor_records_multiple_failures () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_left : (s, [> `Left | `Right ], unit) Supervisor.child) =
            start sup (fail `Left)
          in
          let* (_right : (s, [> `Left | `Right ], unit) Supervisor.child) =
            start sup (fail `Right)
          in
          let* () = yield in
          failures sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Ok failures ->
      let rendered =
        failures
        |> List.map (function
             | Cause.Fail `Left -> "left"
             | Cause.Fail `Right -> "right"
             | _ -> "other")
        |> List.sort String.compare
      in
      Alcotest.(check (list string)) "failures" [ "left"; "right" ] rendered
  | Exit.Error _ -> Alcotest.fail "expected supervisor failures snapshot"

let test_supervisor_nested_scopes_compose () =
  with_runtime @@ fun rt ->
  let inner =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Inner ], unit) Supervisor.child) =
            start sup (fail `Inner)
          in
          let* () = yield in
          failures sup;
    }
  in
  let outer =
    Supervisor.scoped {
      run =
        fun (_ : (_, _) Supervisor.t) ->
          let open Supervisor.Scope in
          let* inner_failures = lift inner in
          pure (List.length inner_failures);
    }
  in
  Alcotest.(check int) "inner failure observed" 1 (run_ok rt outer)

let test_effect_uninterruptible_defers_race_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.named "slow.done" (Effect.sync (fun () ->
        slow_completed := true;
        "slow"))
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "protected loser completed" true !slow_completed

let test_uninterruptible_nested_masks_wait_for_protected_loser () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.named "nested.done" (Effect.sync (fun () ->
        slow_completed := true;
        "slow"))
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for nested protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "nested protected loser completed" true !slow_completed

let test_uninterruptible_blocking_finalizer_delays_race_completion () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref false in
  let protected =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
           Effect.named "release.done" (Effect.sync (fun () -> released := true))
           |> Effect.delay (Duration.ms 1_000))
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) Effect.unit))
    |> Effect.map (fun () -> "protected")
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ protected; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected body" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  wait_for_sleepers clock 1;
  Alcotest.(check bool) "race still waits for protected finalizer" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 1_000);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "blocking finalizer completed" true !released

let test_uninterruptible_timeout_inside_protected_still_fires () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.delay (Duration.ms 100) Effect.unit
    |> Effect.timeout (Duration.ms 50)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 50);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected typed timeout failure, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "Timeout"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Timeout"

let test_uninterruptible_race_loser_without_checkpoints_returns () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let domain_mgr = Eio.Stdenv.domain_mgr stdenv in
  let completed = ref false in
  let loser =
    Effect.sync (fun () ->
        let total =
          Eio.Domain_manager.run domain_mgr (fun () ->
              let acc = ref 0 in
              for i = 1 to 200_000 do
                acc := !acc + i
              done;
              !acc)
        in
        completed := total > 0;
        "slow")
    |> Effect.uninterruptible
  in
  let result = Runtime.run rt (Effect.race [ Effect.pure "fast"; loser ]) in
  check_exit_ok Alcotest.string "winner preserved" "fast" result;
  Alcotest.(check bool)
    "loser returned without cancellation checkpoint" true !completed

let test_clock_sleep_without_wall_time () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 11);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_delays_until_adjusted () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 9);
  yield ();
  Alcotest.(check bool) "not elapsed after 9h" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.hours 1);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_handles_multiple_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let append message acc = acc ^ message in
  let slow =
    Effect.pure (append "World!")
    |> Effect.delay (Duration.hours 3)
  in
  let fast =
    Effect.pure (append "Hello, ")
    |> Effect.delay (Duration.hours 1)
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.hours 1);
  let f =
    match Eio.Promise.await promise with
    | Exit.Ok f -> f
    | Exit.Error _ -> Alcotest.fail "expected Ok"
  in
  Alcotest.(check string) "first sleeper wins" "Hello, " (f "")

let test_clock_set_time_wakes_due_sleepers () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.set_time clock (Duration.to_ms (Duration.hours 11));
  check_exit_ok Alcotest.string "elapsed after set_time" "elapsed"
    (Eio.Promise.await promise)

let test_scope_finalizers_run_in_parallel () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let resource =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.named "release" (Effect.sync (fun () -> incr released))
        |> Effect.delay (Duration.seconds 1))
  in
  let promise =
    fork_run sw rt (Effect.scoped (Effect.concat [ resource; resource; resource ]))
  in
  yield ();
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 1);
  check_exit_ok Alcotest.unit "scope done" () (Eio.Promise.await promise);
  Alcotest.(check int) "all finalizers released" 3 !released

let test_resource_manual_refresh () =
  with_runtime @@ fun rt ->
  let source = ref 0 in
  let load = Effect.named "resource.load" (Effect.sync (fun () -> !source)) in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Resource.get resource
           |> Effect.bind (fun initial ->
                  Effect.named "source.set" (Effect.sync (fun () -> source := 1))
                  |> Effect.bind (fun () -> Resource.refresh resource)
                  |> Effect.bind (fun () -> Resource.get resource)
                  |> Effect.map (fun refreshed -> (initial, refreshed))))
  in
  Alcotest.(check (pair int int)) "initial then refreshed" (0, 1)
    (run_ok rt eff)

let test_resource_failed_refresh_keeps_cached_value () =
  with_runtime @@ fun rt ->
  let source = ref (Ok 0) in
  let load =
    Effect.named "resource.load" (Effect.sync (fun () -> !source))
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Effect.named "source.fail" (Effect.sync (fun () -> source := Error "Uh oh!"))
           |> Effect.bind (fun () -> Resource.refresh resource)
           |> Effect.catch (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                  Effect.unit)
           |> Effect.bind (fun () -> Resource.get resource))
  in
  Alcotest.(check int) "cached value survived failed refresh" 0 (run_ok rt eff)

let test_resource_auto_refreshes_on_schedule () =
  with_test_clock @@ fun _sw clock rt ->
  let source = ref 0 in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
        incr source;
        !source))
  in
  let resource =
    run_ok rt (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "first refresh" 2 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second refresh" 3 (run_ok rt (Resource.get resource))

let test_resource_auto_failed_refresh_keeps_cached_value () =
  with_test_clock @@ fun _sw clock rt ->
  let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
  let load =
    Effect.named "resource.auto.load" (Effect.sync (fun () ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result))
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let errors = ref [] in
  let resource =
    run_ok rt
      (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5))
         ~on_error:(fun err -> errors := err :: !errors) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "failed refresh keeps old value" 1
    (run_ok rt (Resource.get resource));
  Alcotest.(check (list string)) "observed refresh error" [ "boom" ]
    (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
  (match run_ok rt (Resource.failures resource) with
  | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
  | _ -> Alcotest.fail "expected resource failure sink to record refresh error");
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "subsequent refresh updates" 2
    (run_ok rt (Resource.get resource))

type law_deps = {
  add : int -> int;
  mul : int -> int;
}

type law_err = [ `E0 | `E1 | `Neg | `Retry | `Release | `Timeout ]

let pp_law_err fmt = function
  | `E0 -> Format.pp_print_string fmt "E0"
  | `E1 -> Format.pp_print_string fmt "E1"
  | `Neg -> Format.pp_print_string fmt "Neg"
  | `Retry -> Format.pp_print_string fmt "Retry"
  | `Release -> Format.pp_print_string fmt "Release"
  | `Timeout -> Format.pp_print_string fmt "Timeout"

let equal_law_err (a : law_err) (b : law_err) = a = b

let with_law_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let deps = { add = (fun n -> n + 1); mul = (fun n -> n * 2) } in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  f rt deps

let check_law rt name left right =
  let left_exit = Runtime.run rt left in
  let right_exit = Runtime.run rt right in
  if not (Exit.equal Int.equal equal_law_err left_exit right_exit) then
    Alcotest.failf "%s failed:@.left:  %a@.right: %a" name
      (Exit.pp Format.pp_print_int pp_law_err)
      left_exit
      (Exit.pp Format.pp_print_int pp_law_err)
      right_exit

let law_effects deps : (int, law_err) Effect.t list =
  [
    Effect.pure (-2);
    Effect.pure 0;
    Effect.pure 3;
    Effect.fail `E0;
    Effect.fail `E1;
    Effect.named "law.add" (Effect.sync (fun () -> deps.add 1));
    Effect.named "law.mul" (Effect.sync (fun () -> deps.mul 2));
    Effect.pure 2 |> Effect.map (fun n -> n + 4);
    Effect.pure 3 |> Effect.bind (fun n -> Effect.pure (n * 3));
    Effect.fail `E0 |> Effect.catch (fun `E0 -> Effect.pure 7);
  ]

let law_functions deps : (string * (int -> (int, law_err) Effect.t)) list =
  [
    ("inc", fun x -> Effect.pure (x + 1));
    ( "fail-negative",
      fun x -> if x < 0 then Effect.fail `Neg else Effect.pure (x * 2) );
    ("deps-add", fun x -> Effect.named "law.f.add" (Effect.sync (fun () -> deps.add x)));
    ("mapped", fun x -> Effect.pure x |> Effect.map (fun n -> n + 3));
    ( "catch-local",
      fun x -> Effect.fail `E0 |> Effect.catch (fun `E0 -> Effect.pure (x + 5)) );
  ]

let test_properties_monad_laws () =
  with_law_runtime @@ fun rt deps ->
  let values = [ -2; 0; 3 ] in
  let effects = law_effects deps in
  let functions = law_functions deps in
  List.iter
    (fun x ->
      List.iter
        (fun (fname, f) ->
          check_law rt
            (Printf.sprintf "left identity x=%d f=%s" x fname)
            (Effect.bind f (Effect.pure x))
            (f x))
        functions)
    values;
  List.iteri
    (fun i m ->
      check_law rt
        (Printf.sprintf "right identity m=%d" i)
        (Effect.bind Effect.pure m) m)
    effects;
  List.iteri
    (fun i m ->
      List.iter
        (fun (fname, f) ->
          List.iter
            (fun (gname, g) ->
              check_law rt
                (Printf.sprintf "associativity m=%d f=%s g=%s" i fname gname)
                (Effect.bind g (Effect.bind f m))
                (Effect.bind (fun x -> Effect.bind g (f x)) m))
            functions)
        functions)
    effects

let catch_handler : law_err -> (int, law_err) Effect.t = function
  | `E0 -> Effect.pure 10
  | `E1 -> Effect.pure 20
  | `Neg -> Effect.pure 30
  | `Retry -> Effect.pure 40
  | `Release -> Effect.pure 50
  | `Timeout -> Effect.pure 60

let test_properties_catch_laws () =
  with_law_runtime @@ fun rt deps ->
  List.iter
    (fun x ->
      check_law rt
        (Printf.sprintf "catch pure identity x=%d" x)
        (Effect.catch catch_handler (Effect.pure x))
        (Effect.pure x))
    [ -2; 0; 3 ];
  List.iter
    (fun err ->
      check_law rt "catch fail identity"
        (Effect.catch catch_handler (Effect.fail err))
        (catch_handler err))
    ([ `E0; `E1; `Neg; `Retry; `Release; `Timeout ] : law_err list);
  List.iter
    (fun err ->
      List.iter
        (fun (_fname, f) ->
          check_law rt "catch handles bind source failure"
            (Effect.catch catch_handler (Effect.bind f (Effect.fail err)))
            (catch_handler err))
        (law_functions deps))
    ([ `E0; `E1; `Neg ] : law_err list);
  List.iter
    (fun x ->
      check_law rt "catch handles continuation failure"
        (Effect.catch catch_handler
           (Effect.bind (fun _ -> Effect.fail `E1) (Effect.pure x)))
        (catch_handler `E1))
    [ -2; 0; 3 ]

let test_properties_race_success_invariant () =
  with_law_runtime @@ fun rt _deps ->
  let cases =
    [
      ("ok1", Effect.pure 1);
      ("ok2", Effect.pure 2);
      ("fail0", Effect.fail `E0);
      ("fail1", Effect.fail `E1);
    ]
  in
  let succeeds = function Exit.Ok _ -> true | Exit.Error _ -> false in
  List.iter
    (fun (an, a) ->
      List.iter
        (fun (bn, b) ->
          let actual = Runtime.run rt (Effect.race [ a; b ]) |> succeeds in
          let expected =
            Runtime.run rt a |> succeeds || (Runtime.run rt b |> succeeds)
          in
          Alcotest.(check bool)
            (Printf.sprintf "race success iff any succeeds %s/%s" an bn)
            expected actual)
        cases)
    cases

let test_properties_retry_and_repeat_laws () =
  with_law_runtime @@ fun rt _deps ->
  let schedules =
    [
      Schedule.recurs 0;
      Schedule.recurs 3;
      Schedule.both (Schedule.recurs 3) (Schedule.spaced Duration.zero);
      Schedule.either (Schedule.recurs 2) (Schedule.recurs 4);
    ]
  in
  List.iteri
    (fun i schedule ->
      let attempts = ref 0 in
      let attempt =
        Effect.named "retry.always-succeed" (Effect.sync (fun () ->
            incr attempts;
            i))
      in
      Alcotest.(check int)
        (Printf.sprintf "retry success result %d" i)
        i
        (run_ok rt (Effect.retry schedule (fun (_ : law_err) -> true) attempt));
      Alcotest.(check int)
        (Printf.sprintf "retry success attempts %d" i)
        1 !attempts)
    schedules;
  List.iter
    (fun n ->
      let ticks = ref 0 in
      run_ok rt
        (Effect.repeat (Schedule.recurs n)
           (Effect.named "repeat.tick" (Effect.sync (fun () -> incr ticks))));
      Alcotest.(check int)
        (Printf.sprintf "repeat recurs %d runs initial+n" n)
        (n + 1) !ticks)
    [ 0; 1; 2; 5 ]

let test_properties_scope_finalizers_once () =
  with_runtime @@ fun rt ->
  let run_case body =
    let releases = ref [] in
    let resource name =
      Effect.acquire_release
        ~acquire:(Effect.named ("acquire." ^ name) (Effect.sync (fun () -> ())))
        ~release:(fun () ->
          Effect.named ("release." ^ name) (Effect.sync (fun () ->
              releases := name :: !releases)))
    in
    ignore
      (Runtime.run rt
         (Effect.scoped
            (Effect.concat [ resource "a"; resource "b"; body ])));
    List.sort String.compare !releases
  in
  Alcotest.(check (list string))
    "success releases once" [ "a"; "b" ] (run_case Effect.unit);
  Alcotest.(check (list string))
    "typed failure releases once" [ "a"; "b" ] (run_case (Effect.fail `E0));
  with_test_clock @@ fun sw _clock rt ->
  let releases = ref 0 in
  let acquired, acquired_u = Eio.Promise.create () in
  let resource =
    Effect.acquire_release
      ~acquire:(Effect.named "acquire.cancelled" (Effect.sync (fun () ->
          Eio.Promise.resolve acquired_u ())))
      ~release:(fun () ->
        Effect.named "release.cancelled" (Effect.sync (fun () -> incr releases)))
  in
  let slow =
    Effect.scoped
      (resource
      |> Effect.bind (fun () ->
             Effect.pure "slow" |> Effect.delay (Duration.seconds 10)))
  in
  let fast =
    Effect.named "wait-acquired" (Effect.sync (fun () -> Eio.Promise.await acquired))
    |> Effect.map (fun () -> "fast")
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  check_exit_ok Alcotest.string "fast wins" "fast" (Eio.Promise.await promise);
  Alcotest.(check int) "cancelled release once" 1 !releases

(* Dependencies are ordinary OCaml values. A composes B and C by closing over
   the explicit dependency record, without an ambient Eta env channel. *)
let test_explicit_dependency_passing () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let log_calls = ref [] in
  let deps =
    {
      add = (fun n -> n + 1);
      mul = (fun n -> n * 2);
    }
  in
  let db_query s = "row:" ^ s in
  let log_info m = log_calls := m :: !log_calls in
  let services =
    object
      method query = db_query
      method info = log_info
    end
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let b msg = Effect.named "log" (Effect.sync (fun () -> services#info msg)) in
  let c id =
    Effect.named "db" (Effect.sync (fun () -> services#query (string_of_int (deps.add id))))
  in
  let a id =
    let open Effect in
    let user_id = deps.add id in
    bind (fun () -> c id) (b ("fetching " ^ string_of_int user_id))
  in
  match Runtime.run rt (a 41) with
  | Exit.Error _ -> Alcotest.fail "expected Ok"
  | Exit.Ok value ->
      Alcotest.(check string) "db result" "row:42" value;
      Alcotest.(check (list string))
        "log calls" [ "fetching 42" ] (List.rev !log_calls)

(* V-F1 (F-A): par / all / for_each_par. Fail-fast semantics. *)
let test_par_returns_both_successes () =
  with_runtime @@ fun rt ->
  let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure 2)) in
  Alcotest.(check (pair int int)) "par returns pair" (1, 2) result

let test_par_keeps_heterogeneous_successes_private () =
  with_runtime @@ fun rt ->
  let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure "two")) in
  Alcotest.(check (pair int string)) "par returns typed pair" (1, "two") result

let test_par_fail_fast_cancels_sibling () =
  with_runtime @@ fun rt ->
  let other_done = ref false in
  let slow_other =
    Effect.named "slow" (Effect.sync (fun () ->
        Eio.Fiber.yield ();
        other_done := true;
        99))
  in
  let cause =
    match Runtime.run rt (Effect.par (Effect.fail "boom") slow_other) with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "par cause" (Cause.Fail "boom") cause;
  Alcotest.(check bool) "sibling cancelled before completion" false !other_done

let test_all_collects_in_input_order () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt (Effect.all [ Effect.pure 1; Effect.pure 2; Effect.pure 3 ])
  in
  Alcotest.(check (list int)) "all order" [ 1; 2; 3 ] result

let test_all_fail_fast () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.all [ Effect.pure 1; Effect.fail "boom"; Effect.pure 3 ])
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "all cause" (Cause.Fail "boom") cause

let test_all_settled_collects_successes_and_failures () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.all_settled
         [ Effect.pure 1; Effect.fail `Boom; Effect.pure 3 ])
  in
  match result with
  | [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
  | _ -> Alcotest.fail "unexpected all_settled result"

let test_all_settled_runs_all_children () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref 0 in
  let slow name =
    Effect.named name (Effect.sync (fun () -> incr slow_done))
    |> Effect.delay (Duration.ms 50)
  in
  let promise =
    fork_run sw rt (Effect.all_settled [ Effect.fail `Boom; slow "a"; slow "b" ])
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 50);
  ignore
    (Eio.Promise.await promise :
      ((unit, [> `Boom ] Cause.t) result list, _) Exit.t);
  Alcotest.(check int) "slow children completed" 2 !slow_done

let test_all_settled_timeout_scoped_resource_is_typed () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let body =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () ->
           Effect.named "release" (Effect.sync (fun () -> incr released)))
      |> Effect.bind (fun () ->
             Effect.delay (Duration.seconds 10) Effect.unit))
    |> Effect.timeout (Duration.seconds 5)
  in
  let promise = fork_run sw rt (Effect.all_settled [ body ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  match Eio.Promise.await promise with
  | Exit.Ok [ Error (Cause.Fail `Timeout) ] ->
      Alcotest.(check int) "released" 1 !released
  | Exit.Ok [ Error cause ] ->
      Alcotest.failf "expected typed timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected one settled timeout"
  | Exit.Error cause ->
      Alcotest.failf "expected all_settled success, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause

let test_all_settled_empty () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "empty" 0 (List.length (run_ok rt (Effect.all_settled [])))

let test_for_each_par_success () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.for_each_par [ 10; 20; 30 ] (fun x -> Effect.pure (x + 1)))
  in
  Alcotest.(check (list int)) "for_each_par results" [ 11; 21; 31 ] result

let test_for_each_par_one_fails () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.for_each_par [ 1; 2; 3 ] (fun x ->
             if x = 2 then Effect.fail "bad" else Effect.pure x))
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "for_each_par cause" (Cause.Fail "bad") cause

let test_for_each_par_bounded_caps_concurrency () =
  with_test_clock @@ fun sw clock rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.named "enter" (Effect.sync (fun () ->
        incr active;
        max_seen := max !max_seen !active))
    |> Effect.bind (fun () ->
           Effect.pure x
           |> Effect.delay (Duration.ms 10)
           |> Effect.tap (fun _ ->
                  Effect.named "leave" (Effect.sync (fun () -> decr active))))
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3; 4; 5 ] worker)
  in
  for _ = 1 to 3 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 10);
    yield ()
  done;
  check_exit_ok (Alcotest.list Alcotest.int) "results" [ 1; 2; 3; 4; 5 ]
    (Eio.Promise.await promise);
  Alcotest.(check int) "max concurrency" 2 !max_seen

let test_for_each_par_bounded_max_one_is_sequential () =
  with_runtime @@ fun rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.named "worker" (Effect.sync (fun () ->
        incr active;
        max_seen := max !max_seen !active;
        decr active;
        x))
  in
  Alcotest.(check (list int)) "results" [ 1; 2; 3 ]
    (run_ok rt (Effect.for_each_par_bounded ~max:1 [ 1; 2; 3 ] worker));
  Alcotest.(check int) "max concurrency" 1 !max_seen

let test_for_each_par_bounded_fail_fast () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref false in
  let worker = function
    | 1 -> Effect.fail "boom"
    | _ ->
        Effect.named "slow" (Effect.sync (fun () -> slow_done := true))
        |> Effect.delay (Duration.ms 10)
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3 ] worker)
  in
  yield ();
  check_exit_error string_cause "cause" (Cause.Fail "boom")
    (Eio.Promise.await promise);
  Test_clock.adjust clock (Duration.ms 10);
  yield ();
  Alcotest.(check bool) "slow cancelled" false !slow_done

let check_push label expected actual =
  match (expected, actual) with
  | Portable_queue.Pushed, Portable_queue.Pushed
  | Portable_queue.Full, Portable_queue.Full
  | Portable_queue.Closed, Portable_queue.Closed ->
      ()
  | _ -> Alcotest.failf "%s: unexpected push result" label

let check_take_int label expected actual =
  match (expected, actual) with
  | Some expected, Portable_queue.Value actual ->
      Alcotest.(check int) label expected actual
  | None, Portable_queue.Empty | None, Portable_queue.Closed_empty -> ()
  | _ -> Alcotest.failf "%s: unexpected take result" label

let test_portable_queue_backpressure_and_close () =
  let queue = Portable_queue.create ~capacity:2 in
  check_push "push 1" Portable_queue.Pushed (Portable_queue.try_push queue 1);
  check_push "push 2" Portable_queue.Pushed (Portable_queue.try_push queue 2);
  check_push "full" Portable_queue.Full (Portable_queue.try_push queue 3);
  check_take_int "take 1" (Some 1) (Portable_queue.try_take queue);
  check_push "push after take" Portable_queue.Pushed
    (Portable_queue.try_push queue 3);
  check_take_int "take 2" (Some 2) (Portable_queue.try_take queue);
  Portable_queue.close queue;
  check_push "push after close" Portable_queue.Closed
    (Portable_queue.try_push queue 4);
  check_take_int "take 3" (Some 3) (Portable_queue.try_take queue);
  match Portable_queue.try_take queue with
  | Portable_queue.Closed_empty -> ()
  | _ -> Alcotest.fail "expected closed empty queue"

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec search pos =
    if n_len = 0 then true
    else if pos + n_len > h_len then false
    else at pos 0 || search (pos + 1)
  in
  search 0

let rec cause_has_die_message expected = function
  | Cause.Die die -> contains_substring (Printexc.to_string die.exn) expected
  | Cause.Fail _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_die_message expected) causes
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_die_message expected primary
      || cause_has_die_message expected finalizer

let check_die_message label expected cause =
  Alcotest.(check bool) label true (cause_has_die_message expected cause)

let with_island_runtime ?domains f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Effect.Island.Pool.create ?domains () in
  Fun.protect
    ~finally:(fun () -> Effect.Island.Pool.shutdown pool)
    (fun () ->
      let rt =
        Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~island_pool:pool
          ()
      in
      f rt pool)

type island_error : immutable_data =
  | Odd of int
  | Invalid_payload of string

type parse_input : immutable_data = {
  parse_id : int;
  payload : string;
}

type schema_input : immutable_data = {
  schema_version : int;
  required : int;
  values : int list;
}

type hash_input : immutable_data = {
  hash_seed : int;
  rounds : int;
  bytes : string;
}

let (island_square @ portable) n = n * n

let (island_order_work @ portable) n =
  let rec burn acc i =
    if i = 0 then acc
    else burn (((acc lxor (i * 33)) + n) land 0x3fffffff) (i - 1)
  in
  ignore (burn 0 (((n mod 3) + 1) * 250));
  n * 10

let (island_even_result @ portable) n =
  if n mod 2 = 0 then Ok (n / 2) else Error (Odd n)

let (island_settled_work @ portable) n =
  if n = 0 then failwith "worker died"
  else if n mod 2 = 0 then Ok (n * 2)
  else Error (Odd n)

let (island_parse_work @ portable) input =
  let len = String.length input.payload in
  let rec count_colons i acc =
    if i = len then acc
    else
      let acc = if Char.equal input.payload.[i] ':' then acc + 1 else acc in
      count_colons (i + 1) acc
  in
  input.parse_id + len + count_colons 0 0

let (island_schema_work @ portable) input =
  let rec sum acc = function
    | [] -> acc
    | x :: xs -> sum (acc + x) xs
  in
  input.schema_version + input.required + sum 0 input.values

let (island_hash_work @ portable) input =
  let len = String.length input.bytes in
  let rec loop i acc =
    if i = input.rounds then acc
    else
      let byte = Char.code input.bytes.[i mod len] in
      loop (i + 1) (((acc lxor byte) * 16_777_619) land 0x3fffffff)
  in
  loop 0 input.hash_seed

let test_island_single_uses_runtime_pool () =
  with_island_runtime @@ fun rt _pool ->
  Alcotest.(check int)
    "single island" 49
    (run_ok rt (Effect.island ~name:"square" island_square 7))

let test_island_requires_pool () =
  with_runtime @@ fun rt ->
  match Runtime.run rt (Effect.island ~name:"missing" island_square 3) with
  | Exit.Ok _ -> Alcotest.fail "expected missing island pool to fail"
  | Exit.Error cause ->
      check_die_message "missing pool" "island executor not configured" cause

let test_island_run_pool_override () =
  with_runtime @@ fun rt ->
  let pool = Effect.Island.Pool.create () in
  Fun.protect
    ~finally:(fun () -> Effect.Island.Pool.shutdown pool)
    (fun () ->
      check_exit_ok Alcotest.int "override pool" 36
        (Runtime.run ~island_pool:pool rt
           (Effect.island ~name:"override" island_square 6)))

let test_island_map_preserves_order () =
  with_island_runtime @@ fun rt _pool ->
  let inputs = [ 5; 1; 4; 2; 3 ] in
  Alcotest.(check (list int))
    "input order" [ 50; 10; 40; 20; 30 ]
    (run_ok rt (Effect.Island.map ~f:island_order_work inputs))

let test_island_map_result_returns_item_results () =
  with_island_runtime @@ fun rt _pool ->
  match run_ok rt (Effect.Island.map_result ~f:island_even_result [ 2; 3; 4 ])
  with
  | [ Ok 1; Error (Odd 3); Ok 2 ] -> ()
  | _ -> Alcotest.fail "unexpected map_result output"

let test_island_all_settled_returns_worker_died () =
  with_island_runtime @@ fun rt _pool ->
  match
    run_ok rt
      (Effect.Island.all_settled ~f:island_settled_work [ 2; 3; 0; 4 ])
  with
  | [
   Effect.Island.Ok 4;
   Effect.Island.Error (Odd 3);
   Effect.Island.Worker_died die;
   Effect.Island.Ok 8;
  ] ->
      Alcotest.(check string) "worker die kind" "worker_died" die.kind
  | _ -> Alcotest.fail "unexpected all_settled output"

let test_island_map_worker_crash_fails_outer_effect () =
  with_island_runtime @@ fun rt _pool ->
  match Runtime.run rt (Effect.Island.map ~f:island_settled_work [ 1; 0 ]) with
  | Exit.Ok _ -> Alcotest.fail "expected worker crash to fail map"
  | Exit.Error cause -> check_die_message "worker crash" "worker died" cause

let test_island_workloads () =
  with_island_runtime @@ fun rt _pool ->
  let parse_inputs =
    [
      { parse_id = 1; payload = "a:b:c" };
      { parse_id = 2; payload = "abc" };
      { parse_id = 3; payload = "x:y" };
    ]
  in
  let schema_inputs =
    [
      { schema_version = 1; required = 10; values = [ 1; 2; 3 ] };
      { schema_version = 2; required = 0; values = [ 5; 5 ] };
    ]
  in
  let hash_inputs =
    [
      { hash_seed = 17; rounds = 24; bytes = "abcdef" };
      { hash_seed = 23; rounds = 32; bytes = "schema" };
      { hash_seed = 31; rounds = 16; bytes = "payload" };
    ]
  in
  Alcotest.(check (list int))
    "parse workload" [ 8; 5; 7 ]
    (run_ok rt (Effect.Island.map ~name:"parse" ~f:island_parse_work parse_inputs));
  Alcotest.(check (list int))
    "schema workload" [ 17; 12 ]
    (run_ok rt
       (Effect.Island.map ~name:"schema" ~f:island_schema_work schema_inputs));
  Alcotest.(check int)
    "hash workload count" 3
    (List.length
       (run_ok rt
          (Effect.Island.map ~name:"hash" ~f:island_hash_work hash_inputs)))

external hold_lock_sleep : float -> unit = "eta_test_hold_lock_sleep"

module BP = Effect.Blocking.Pool

let blocking_config ?(max_threads = 4) ?(max_queued = 64)
    ?(queue_policy = BP.Wait) ?(shutdown_policy = BP.Drain) () : BP.config =
  { max_threads; max_queued; queue_policy; shutdown_policy }

let wait_until ?(attempts = 200) pred =
  let rec loop n =
    if pred () then ()
    else if n = 0 then Alcotest.fail "condition did not become true"
    else (
      Eio_unix.sleep 0.001;
      loop (n - 1))
  in
  loop attempts

let test_channel_try_send_try_recv () =
  with_runtime @@ fun rt ->
  let ch = Channel.create ~capacity:1 () in
  (match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "expected empty");
  (match run_ok rt (Channel.try_send ch 1) with
  | `Sent -> ()
  | _ -> Alcotest.fail "expected sent");
  (match run_ok rt (Channel.try_send ch 2) with
  | `Full -> ()
  | _ -> Alcotest.fail "expected full");
  (match run_ok rt (Channel.try_recv ch) with
  | `Item 1 -> ()
  | _ -> Alcotest.fail "expected item");
  let stats = Channel.stats ch in
  Alcotest.(check int) "sent" 1 stats.Channel.sent;
  Alcotest.(check int) "received" 1 stats.Channel.received

let test_channel_blocking_send_backpressure () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let sender = fork_run sw rt (Channel.send ch 2) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "depth while blocked" 1 (Channel.stats ch).depth;
  Alcotest.(check int) "first recv" 1 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "sender completed" () (Eio.Promise.await sender);
  Alcotest.(check int) "second recv" 2 (run_ok rt (Channel.recv ch))

let test_channel_blocked_sender_is_not_passed_by_later_sender () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let first_sender = fork_run sw rt (Channel.send ch 2) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "initial value" 1 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "first sender admitted" ()
    (Eio.Promise.await first_sender);
  let later_sender = fork_run sw rt (Channel.send ch 3) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Alcotest.(check int) "blocked sender value" 2 (run_ok rt (Channel.recv ch));
  check_exit_ok Alcotest.unit "later sender admitted" ()
    (Eio.Promise.await later_sender);
  Alcotest.(check int) "later value" 3 (run_ok rt (Channel.recv ch))

let test_channel_blocking_recv () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let receiver = fork_run sw rt (Channel.recv ch) in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  run_ok rt (Channel.send ch 7);
  check_exit_ok Alcotest.int "received" 7 (Eio.Promise.await receiver)

let test_channel_close_wakes_blocked_senders_and_receivers () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let sender_ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send sender_ch 1);
  let sender = fork_run sw rt (Channel.send sender_ch 2) in
  wait_until (fun () -> (Channel.stats sender_ch).Channel.waiting_senders = 1);
  Channel.close sender_ch;
  (match Eio.Promise.await sender with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | _ -> Alcotest.fail "expected blocked sender closed");
  let receiver_ch = Channel.create ~capacity:1 () in
  let receiver = fork_run sw rt (Channel.recv receiver_ch) in
  wait_until (fun () -> (Channel.stats receiver_ch).Channel.waiting_receivers = 1);
  Channel.close receiver_ch;
  match Eio.Promise.await receiver with
  | Exit.Error (Cause.Fail `Closed) -> ()
  | _ -> Alcotest.fail "expected blocked receiver closed"

let test_channel_cancel_blocked_send_cleans_waiter () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let cancel_ctx = ref None in
  let sender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Channel.send ch 2))
  in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn sender with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  let stats = Channel.stats ch in
  Alcotest.(check int) "waiting senders" 0 stats.Channel.waiting_senders;
  Alcotest.(check int) "cancelled senders" 1 stats.Channel.cancelled_senders;
  Alcotest.(check int) "depth unchanged" 1 stats.Channel.depth;
  Alcotest.(check int) "original value" 1 (run_ok rt (Channel.recv ch));
  match run_ok rt (Channel.try_recv ch) with
  | `Empty -> ()
  | _ -> Alcotest.fail "cancelled sender enqueued a value"

let test_channel_cancel_blocked_recv_cleans_waiter () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  let cancel_ctx = ref None in
  let receiver =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (Channel.recv ch))
  in
  wait_until (fun () -> (Channel.stats ch).Channel.waiting_receivers = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn receiver with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  Alcotest.(check int)
    "waiting receivers" 0 (Channel.stats ch).Channel.waiting_receivers

let test_channel_parent_switch_teardown_does_not_hang () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:1 () in
  run_ok rt (Channel.send ch 1);
  let outcome =
    try
      Eio.Switch.run @@ fun child_sw ->
      ignore
        (Eio.Fiber.fork_promise ~sw:child_sw (fun () ->
             Runtime.run rt (Channel.send ch 2)));
      wait_until (fun () -> (Channel.stats ch).Channel.waiting_senders = 1);
      Eio.Switch.fail child_sw Exit;
      `Returned
    with Exit -> `Cancelled
  in
  (match outcome with `Returned | `Cancelled -> ());
  Alcotest.(check int)
    "waiting senders" 0 (Channel.stats ch).Channel.waiting_senders

type pool_test_error =
  [ `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Timeout
  | `Open_failed
  | `Close_failed
  | `Health_failed
  ]

type pool_test_conn = {
  id : int;
  closed : bool ref;
  unhealthy : bool ref;
  uses : int ref;
}

type pool_test_factory = {
  next_id : int ref;
  opened : int ref;
  closed : int ref;
  live : int ref;
  max_live : int ref;
  unhealthy_ids : int list;
}

let make_pool_factory ?(unhealthy_ids = []) () =
  {
    next_id = ref 0;
    opened = ref 0;
    closed = ref 0;
    live = ref 0;
    max_live = ref 0;
    unhealthy_ids;
  }

let pool_open (factory : pool_test_factory) : (pool_test_conn, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  incr factory.next_id;
  incr factory.opened;
  incr factory.live;
  factory.max_live := max !(factory.max_live) !(factory.live);
  {
    id = !(factory.next_id);
    closed = ref false;
    unhealthy = ref (List.mem !(factory.next_id) factory.unhealthy_ids);
    uses = ref 0;
  }

let pool_close (factory : pool_test_factory) (conn : pool_test_conn) :
    (unit, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  if not !(conn.closed) then (
    conn.closed := true;
    incr factory.closed;
    decr factory.live)

let pool_health (conn : pool_test_conn) : (unit, pool_test_error) Effect.t =
  if !(conn.unhealthy) then Effect.fail `Health_failed else Effect.unit

let pool_use (conn : pool_test_conn) : (int, pool_test_error) Effect.t =
  Effect.sync @@ fun () ->
  if !(conn.closed) then Alcotest.fail "used closed connection";
  incr conn.uses;
  conn.id

let create_test_pool ?max_idle ?idle_lifetime ?max_lifetime ?health_check
    ?(idle_check_interval = Duration.ms 5) ~max_size factory =
  let health_check = Option.value health_check ~default:pool_health in
  Pool.create ~name:"test.pool" ~kind:"test" ~max_size ?max_idle
    ?idle_lifetime ?max_lifetime ~idle_check_interval
    ~acquire:(pool_open factory) ~release:(pool_close factory)
    ~health_check ()

let test_pool_reuses_idle_lifo () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:2 factory) in
  let use_once = Pool.with_resource pool pool_use in
  let first = run_ok rt use_once in
  let second = run_ok rt use_once in
  Alcotest.(check int) "reused id" first second;
  let stats = Pool.stats pool in
  Alcotest.(check int) "one opened" 1 stats.Pool.opened;
  Alcotest.(check int) "idle" 1 stats.Pool.idle;
  Alcotest.(check int) "active" 0 stats.Pool.active;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool);
  Alcotest.(check int) "closed on shutdown" 1 !(factory.closed)

let test_pool_timeout_cleans_waiter_and_preserves_timeout_cause () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    Pool.with_resource pool (fun _ ->
        Effect.delay (Duration.ms 20) Effect.unit)
  in
  let waiter =
    Effect.delay (Duration.ms 1)
      (Pool.with_resource pool (fun _ -> Effect.unit)
      |> Effect.timeout (Duration.ms 2))
  in
  let outcomes = run_ok rt (Effect.all_settled [ holder; waiter ]) in
  let saw_timeout =
    List.exists
      (function Error (Cause.Fail `Timeout) -> true | _ -> false)
      outcomes
  in
  Alcotest.(check bool) "timeout cause" true saw_timeout;
  let stats = Pool.stats pool in
  Alcotest.(check int) "waiting cleaned" 0 stats.Pool.waiting;
  Alcotest.(check int) "cancelled waiter" 1 stats.Pool.cancelled_waiters;
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_health_rejection_reopens () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory ~unhealthy_ids:[ 1 ] () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let id = run_ok rt (Pool.with_resource pool pool_use) in
  Alcotest.(check int) "healthy replacement" 2 id;
  let stats = Pool.stats pool in
  Alcotest.(check int) "opened" 2 stats.Pool.opened;
  Alcotest.(check int) "rejected" 1 stats.Pool.health_rejected;
  Alcotest.(check int) "closed rejected" 1 stats.Pool.closed;
  Alcotest.(check int) "max live bounded" 1 !(factory.max_live);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_cancel_during_health_check_closes_reserved () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let slow_health _ = Effect.delay (Duration.ms 20) Effect.unit in
  let pool =
    run_ok rt (create_test_pool ~max_size:1 ~health_check:slow_health factory)
  in
  (match
     Runtime.run rt
       (Pool.with_resource pool (fun _ -> Effect.unit)
       |> Effect.timeout (Duration.ms 2))
   with
  | Exit.Error (Cause.Fail `Timeout) -> ()
  | _ -> Alcotest.fail "expected timeout during health check");
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.active = 0 && stats.Pool.closed = 1);
  Alcotest.(check int) "live closed" 0 !(factory.live);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_idle_eviction () =
  with_runtime @@ fun rt ->
  let factory = make_pool_factory () in
  let pool =
    run_ok rt
      (create_test_pool ~max_size:1 ~idle_lifetime:(Duration.ms 2)
         ~idle_check_interval:(Duration.ms 1) factory)
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  wait_until (fun () -> (Pool.stats pool).Pool.idle = 1);
  Eio_unix.sleep 0.02;
  wait_until (fun () ->
      let stats = Pool.stats pool in
      stats.Pool.idle = 0 && stats.Pool.closed = 1);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool)

let test_pool_shutdown_wakes_waiters_and_drains () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 20) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  let waiter = fork_run sw rt (Pool.with_resource pool (fun _ -> Effect.unit)) in
  wait_until (fun () -> (Pool.stats pool).Pool.waiting = 1);
  let shutdown = fork_run sw rt (Pool.shutdown ~deadline:(Duration.ms 100) pool) in
  (match Eio.Promise.await waiter with
  | Exit.Error (Cause.Fail `Pool_shutdown) -> ()
  | _ -> Alcotest.fail "expected waiter Pool_shutdown");
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  check_exit_ok Alcotest.unit "shutdown done" () (Eio.Promise.await shutdown);
  let stats = Pool.stats pool in
  Alcotest.(check int) "active" 0 stats.Pool.active;
  Alcotest.(check int) "idle" 0 stats.Pool.idle;
  Alcotest.(check bool) "shutting down" true stats.Pool.shutting_down;
  Alcotest.(check int) "closed" 1 stats.Pool.closed

let test_pool_shutdown_deadline_timeout () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let factory = make_pool_factory () in
  let pool = run_ok rt (create_test_pool ~max_size:1 factory) in
  let holder =
    fork_run sw rt
      (Pool.with_resource pool (fun _ ->
           Effect.delay (Duration.ms 30) Effect.unit))
  in
  wait_until (fun () -> (Pool.stats pool).Pool.active = 1);
  (match Runtime.run rt (Pool.shutdown ~deadline:(Duration.ms 2) pool) with
  | Exit.Error (Cause.Fail `Pool_shutdown_timeout) -> ()
  | _ -> Alcotest.fail "expected shutdown timeout");
  check_exit_ok Alcotest.unit "holder done" () (Eio.Promise.await holder);
  wait_until (fun () -> (Pool.stats pool).Pool.closed = 1)

let test_pool_observability_signals () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let logger = Logger.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ~meter:(Meter.as_capability meter)
      ~logger:(Logger.as_capability logger) ()
  in
  let factory = make_pool_factory ~unhealthy_ids:[ 1 ] () in
  let pool =
    run_ok rt
      (Pool.create ~name:"obs.pool" ~kind:"sql.client" ~max_size:1
         ~acquire:(pool_open factory) ~release:(pool_close factory)
         ~health_check:pool_health ())
  in
  ignore (run_ok rt (Pool.with_resource pool pool_use) : int);
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 100) pool);
  let metric_names = List.map (fun p -> p.Meter.name) (Meter.dump meter) in
  let has_metric name = List.exists (String.equal name) metric_names in
  Alcotest.(check bool) "active metric" true (has_metric "eta.pool.active");
  Alcotest.(check bool) "opened metric" true (has_metric "eta.pool.opened");
  Alcotest.(check bool) "closed metric" true (has_metric "eta.pool.closed");
  Alcotest.(check bool)
    "health metric" true (has_metric "eta.pool.health_rejected");
  let span_names = List.map (fun s -> s.Tracer.name) (Tracer.dump tracer) in
  let has_span name = List.exists (String.equal name) span_names in
  Alcotest.(check bool) "acquire span" true (has_span "eta.pool.acquire");
  Alcotest.(check bool) "health span" true (has_span "eta.pool.health_check");
  Alcotest.(check bool) "close span" true (has_span "eta.pool.close");
  Alcotest.(check bool) "shutdown span" true (has_span "eta.pool.shutdown");
  let log_bodies = List.map (fun r -> r.Logger.body) (Logger.dump logger) in
  Alcotest.(check bool) "health log" true
    (List.exists (String.equal "eta.pool.health_rejected") log_bodies);
  Alcotest.(check bool) "shutdown log" true
    (List.exists (String.equal "eta.pool.shutdown_started") log_bodies)

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let percentile sorted pct =
  match sorted with
  | [] -> 0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let heartbeat_p99_us body =
  let running = ref true in
  let samples = ref [] in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
      let target = ref (now_us () + 1_000) in
      while !running do
        Eio_unix.sleep 0.001;
        let actual = now_us () in
        samples := max 0 (actual - !target) :: !samples;
        target := actual + 1_000
      done);
  Eio.Fiber.yield ();
  let result = body () in
  running := false;
  Eio.Fiber.yield ();
  let sorted = List.sort compare !samples in
  (percentile sorted 0.99, result)

let elapsed_us f =
  let started = now_us () in
  let value = f () in
  (now_us () - started, value)

let rec cpu_burn_until deadline acc =
  if now_us () >= deadline then acc
  else
    let acc = ((acc lxor (acc lsl 5)) + 0x9e3779b9) land 0x3fffffff in
    cpu_burn_until deadline acc

let cpu_burn_ms ms =
  ignore (cpu_burn_until (now_us () + (ms * 1000)) 0x12345)

let check_pool_shutdown label cause =
  check_die_message label "Pool_shutting_down" cause

let test_blocking_submit_alias_and_stats () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"basic" (blocking_config ~max_threads:2 ()) in
  Alcotest.(check int) "blocking" 42
    (run_ok rt (Effect.blocking ~pool ~name:"basic.answer" (fun () -> 42)));
  Alcotest.(check int) "submit" 43
    (run_ok rt (Effect.Blocking.submit ~pool ~name:"basic.submit" (fun () -> 43)));
  let stats = BP.stats pool in
  Alcotest.(check int) "completed" 2 stats.completed;
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "queued" 0 stats.queued

let test_blocking_direct_control_and_blocking_heartbeat () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let direct_p99, () = heartbeat_p99_us (fun () -> Unix.sleepf 0.030) in
  let pool = BP.create ~name:"heartbeat" (blocking_config ~max_threads:4 ()) in
  let blocking_p99, () =
    heartbeat_p99_us (fun () ->
        run_ok rt (Effect.blocking ~pool ~name:"heartbeat.sleep" (fun () -> Unix.sleepf 0.030)))
  in
  Alcotest.(check bool) "direct freezes heartbeat" true (direct_p99 > 20_000);
  Alcotest.(check bool) "blocking preserves heartbeat" true (blocking_p99 < 10_000)

let test_blocking_wait_policy_caps_active_and_queue () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"wait-cap"
      (blocking_config ~max_threads:4 ~max_queued:8 ~queue_policy:BP.Wait ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let max_active = ref 0 in
  let max_queued = ref 0 in
  let sampling = ref true in
  Eio.Fiber.fork ~sw (fun () ->
      while !sampling do
        let stats = BP.stats pool in
        max_active := max !max_active stats.active;
        max_queued := max !max_queued stats.queued;
        Eio_unix.sleep 0.001
      done);
  let p99, values =
    heartbeat_p99_us (fun () ->
        run_ok rt
          (Effect.for_each_par (List.init 30 Fun.id) (fun _ ->
               Effect.blocking ~pool ~name:"wait-cap.job" (fun () ->
                   Unix.sleepf 0.010;
                   1))))
  in
  sampling := false;
  Alcotest.(check int) "completed list" 30 (List.length values);
  Alcotest.(check bool) "active cap" true (!max_active <= 4);
  Alcotest.(check bool) "queued cap" true (!max_queued <= 8);
  Alcotest.(check bool) "heartbeat" true (p99 < 10_000);
  let stats = BP.stats pool in
  Alcotest.(check int) "completed" 30 stats.completed;
  Alcotest.(check int) "rejected" 0 stats.rejected;
  Alcotest.(check int) "cancelled" 0 stats.cancelled_before_start;
  Alcotest.(check int) "detached" 0 stats.detached

let test_blocking_reject_policy_deterministic () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"reject"
      (blocking_config ~max_threads:1 ~max_queued:0 ~queue_policy:BP.Reject ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let first_started, first_resolver = Eio.Promise.create () in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"reject.first" (fun () ->
               Eio.Promise.resolve first_resolver ();
               Unix.sleepf 0.060)))
  in
  Eio.Promise.await first_started;
  wait_until (fun () -> (BP.stats pool).active = 1);
  let rejected =
    List.init 4 (fun _ ->
        match Runtime.run rt (Effect.blocking ~pool ~name:"reject.extra" (fun () -> ())) with
        | Exit.Ok _ -> false
        | Exit.Error _ -> true)
  in
  Alcotest.(check int) "rejected count observed" 4
    (List.length (List.filter Fun.id rejected));
  Alcotest.(check int) "rejected stats" 4 (BP.stats pool).rejected;
  ignore (Eio.Promise.await_exn first : (unit, _) Exit.t)

let test_blocking_pending_cancellation_removes_queued_job () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"cancel-pending"
      (blocking_config ~max_threads:1 ~max_queued:1 ~queue_policy:BP.Wait ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let blocker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-pending.blocker" (fun () ->
               Unix.sleepf 0.050)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let cancel_ctx = ref None in
  let queued =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-pending.queued" (fun () -> ())))
  in
  wait_until (fun () -> (BP.stats pool).queued = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn queued with
  | Exit.Ok _ -> Alcotest.fail "expected cancellation"
  | Exit.Error _ -> ());
  ignore (Eio.Promise.await_exn blocker : (unit, _) Exit.t);
  Alcotest.(check int)
    "cancelled before start" 1 (BP.stats pool).cancelled_before_start

let test_blocking_started_cancellation_is_nonpreemptive () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"cancel-started" (blocking_config ~max_threads:1 ()) in
  let completed = Atomic.make false in
  let elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cancel-started.job"
             (fun () ->
               Unix.sleepf 0.030;
               Atomic.set completed true)
          |> Effect.timeout (Duration.ms 5)))
  in
  (match result with Exit.Ok _ | Exit.Error _ -> ());
  Alcotest.(check bool) "worker completed" true (Atomic.get completed);
  Alcotest.(check bool) "waited for started job" true (elapsed >= 25_000)

let test_blocking_shutdown_rejects_new_jobs () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"shutdown" (blocking_config ()) in
  run_ok rt (BP.shutdown pool);
  match Runtime.run rt (Effect.blocking ~pool ~name:"after-shutdown" (fun () -> ())) with
  | Exit.Ok _ -> Alcotest.fail "expected shutdown rejection"
  | Exit.Error cause -> check_pool_shutdown "shutdown" cause

let test_blocking_shutdown_drain_waits_for_started () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    BP.create ~name:"drain" (blocking_config ~max_threads:1 ~shutdown_policy:BP.Drain ())
  in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let worker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"drain.job" (fun () -> Unix.sleepf 0.030)))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let elapsed, () = elapsed_us (fun () -> run_ok rt (BP.shutdown pool)) in
  Alcotest.(check bool) "drain waited" true (elapsed >= 20_000);
  ignore (Eio.Promise.await_exn worker : (unit, _) Exit.t)

let test_blocking_shutdown_detach_started_returns_promptly () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Meter.in_memory () in
  let pool =
    BP.create ~name:"detach"
      (blocking_config ~max_threads:1 ~shutdown_policy:BP.Detach_started ())
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Meter.as_capability meter) ()
  in
  let worker =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"detach.job" (fun () ->
               Unix.sleepf 0.050;
               failwith "detached failure")))
  in
  wait_until (fun () -> (BP.stats pool).active = 1);
  let elapsed, () = elapsed_us (fun () -> run_ok rt (BP.shutdown pool)) in
  Alcotest.(check bool) "detach returned promptly" true (elapsed < 20_000);
  Alcotest.(check bool) "detached counter" true ((BP.stats pool).detached >= 1);
  Eio_unix.sleep 0.060;
  ignore (Eio.Promise.await_exn worker : (unit, _) Exit.t);
  Alcotest.(check bool) "detached metric" true
    (Meter.dump meter
     |> List.exists (fun point ->
            String.equal point.Meter.name "eta.blocking.run_ms"
            && List.mem ("eta.blocking.pool", "detach") point.attrs
            && List.exists
                 (fun (k, v) ->
                   String.equal k "eta.blocking.outcome"
                   && contains_substring v "error")
                 point.attrs))

let test_blocking_named_pools_prevent_starvation () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let fs_pool = BP.create ~name:"fs" (blocking_config ~max_threads:4 ~max_queued:64 ()) in
  let db_pool = BP.create ~name:"db" (blocking_config ~max_threads:2 ~max_queued:8 ()) in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let fs =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Runtime.run rt
          (Effect.for_each_par (List.init 40 Fun.id) (fun _ ->
               Effect.blocking ~pool:fs_pool ~name:"fs.scan" (fun () ->
                   Unix.sleepf 0.050))))
  in
  Eio_unix.sleep 0.010;
  let elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt (Effect.blocking ~pool:db_pool ~name:"db.query" (fun () -> 1)))
  in
  check_exit_ok Alcotest.int "db result" 1 result;
  Alcotest.(check bool) "db not starved" true (elapsed < 10_000);
  ignore (Eio.Promise.await_exn fs : (unit list, _) Exit.t)

let test_blocking_domain_isolated_preserves_hold_lock_heartbeat () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let normal_pool =
    BP.create ~name:"hold-lock-normal" (blocking_config ~max_threads:1 ())
  in
  let domain_pool =
    BP.create_domain_isolated ~name:"hold-lock-domain"
      (blocking_config ~max_threads:1 ())
  in
  let normal_p99, () =
    heartbeat_p99_us (fun () ->
        ignore
          (Runtime.run rt
             (Effect.blocking ~pool:normal_pool ~name:"hold-lock.normal"
                (fun () -> hold_lock_sleep 0.030))))
  in
  let domain_p99, () =
    heartbeat_p99_us (fun () ->
        ignore
          (Runtime.run rt
             (Effect.blocking ~pool:domain_pool ~name:"hold-lock.domain"
                (fun () -> hold_lock_sleep 0.030))))
  in
  Alcotest.(check bool) "normal hold-lock degrades" true (normal_p99 > 20_000);
  (* The absolute p99 is scheduler-noise sensitive in the full suite; the
     regression is domain isolation becoming materially worse than systhread. *)
  if domain_p99 > normal_p99 + 5_000 then
    Alcotest.failf "domain p99=%dus normal p99=%dus" domain_p99 normal_p99

let test_blocking_worker_rejects_nested_submit () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"worker-nested-submit" (blocking_config ()) in
  match
    Runtime.run rt
      (Effect.blocking ~pool ~name:"outer" (fun () ->
           ignore (Effect.Blocking.submit ~pool ~name:"inner" (fun () -> ()))))
  with
  | Exit.Ok _ -> Alcotest.fail "expected nested submit failure"
  | Exit.Error cause ->
      check_die_message "nested submit" "Effect.Blocking.submit" cause

let test_blocking_worker_rejects_runtime_run () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"worker-runtime" (blocking_config ()) in
  match
    Runtime.run rt
      (Effect.blocking ~pool ~name:"outer" (fun () ->
           ignore (Runtime.run rt (Effect.pure ()))))
  with
  | Exit.Ok _ -> Alcotest.fail "expected nested runtime failure"
  | Exit.Error cause -> check_die_message "nested runtime" "Runtime.run" cause

let test_blocking_cpu_antipattern_has_no_speedup () =
  with_runtime @@ fun rt ->
  let pool = BP.create ~name:"cpu-antipattern" (blocking_config ~max_threads:4 ()) in
  let same_elapsed, () = elapsed_us (fun () -> cpu_burn_ms 20) in
  let blocking_elapsed, result =
    elapsed_us (fun () ->
        Runtime.run rt
          (Effect.blocking ~pool ~name:"cpu.antipattern" (fun () -> cpu_burn_ms 20)))
  in
  check_exit_ok Alcotest.unit "cpu blocking result" () result;
  Alcotest.(check bool) "no meaningful speedup" true
    (blocking_elapsed >= same_elapsed / 2)

let test_blocking_observability_labels_and_timings () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let meter = Meter.in_memory () in
  let pool = BP.create ~name:"observed" (blocking_config ~max_threads:2 ()) in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~meter:(Meter.as_capability meter)
      ~auto_instrument:true ()
  in
  run_ok rt
    (Effect.blocking ~pool ~name:"test.label" (fun () ->
         Unix.sleepf 0.020;
         1))
  |> ignore;
  let spans = Tracer.dump tracer in
  Alcotest.(check bool) "span label" true
    (List.exists (fun span -> String.equal span.Tracer.name "test.label") spans);
  Alcotest.(check bool) "trace event" true
    (List.exists
       (fun span ->
         List.exists
           (fun event ->
             String.equal event.Tracer.ev_name "eta.blocking"
             && List.mem ("eta.blocking.name", "test.label") event.ev_attrs
             && List.mem ("eta.blocking.pool", "observed") event.ev_attrs)
           span.Tracer.events)
       spans);
  Alcotest.(check bool) "run timing metric" true
    (Meter.dump meter
     |> List.exists (fun point ->
            String.equal point.Meter.name "eta.blocking.run_ms"
            && List.mem ("eta.blocking.name", "test.label") point.attrs
            &&
            match point.value with Meter.Int ms -> ms >= 15 | Meter.Float _ -> false))

let test_redacted_pp_unlabelled () =
  let r = Redacted.make "secret" in
  Alcotest.(check string) "unlabelled pp" "<redacted>"
    (Format.asprintf "%a" Redacted.pp r)

let test_redacted_pp_labelled () =
  let r = Redacted.make ~label:"api_key" "secret" in
  Alcotest.(check string) "labelled pp" "<redacted:api_key>"
    (Format.asprintf "%a" Redacted.pp r)

let test_redacted_equal () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  let c = Redacted.make "y" in
  Alcotest.(check bool) "equal same" true (Redacted.equal String.equal a b);
  Alcotest.(check bool) "equal different" false (Redacted.equal String.equal a c)

let test_redacted_hash () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  Alcotest.(check int) "hash stable"
    (Redacted.hash String.hash a)
    (Redacted.hash String.hash b)

let test_redacted_wipe_unsafe () =
  let r = Redacted.make "secret" in
  Alcotest.(check bool) "wipe returns true" true (Redacted.wipe_unsafe r);
  Alcotest.check_raises "value after wipe" (Failure "Redacted.value: wiped")
    (fun () -> ignore (Redacted.value r))

let test_redacted_label () =
  let a = Redacted.make "secret" in
  let b = Redacted.make ~label:"token" "secret" in
  Alcotest.(check (option string)) "no label" None (Redacted.label a);
  Alcotest.(check (option string)) "with label" (Some "token") (Redacted.label b)

let test_log_level_compare_ordering () =
  let open Log_level in
  let expected = [ All; Trace; Debug; Info; Warn; Error; Fatal; None ] in
  let rec check_pairs = function
    | [] | [_] -> ()
    | a :: (b :: _ as rest) ->
        Alcotest.(check int)
          (to_string a ^ " < " ^ to_string b)
          (-1)
          (compare a b);
        check_pairs rest
  in
  check_pairs expected;
  Alcotest.(check int) "Fatal < None" (-1) (compare Fatal None);
  Alcotest.(check int) "All < Trace" (-1) (compare All Trace)

let test_log_level_equal () =
  let open Log_level in
  List.iter
    (fun level ->
      Alcotest.(check bool) "reflexive" true (equal level level))
    all;
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          Alcotest.(check bool)
            ("symmetric " ^ to_string a ^ " " ^ to_string b)
            (equal a b)
            (equal b a))
        all)
    all;
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          List.iter
            (fun c ->
              if equal a b && equal b c then
                Alcotest.(check bool)
                  ("transitive " ^ to_string a ^ " " ^ to_string b ^ " " ^ to_string c)
                  true
                  (equal a c))
            all)
        all)
    all

let test_log_level_is_enabled () =
  let open Log_level in
  Alcotest.(check bool)
    "at threshold" true
    (is_enabled ~at:Info ~threshold:Info);
  Alcotest.(check bool)
    "above threshold" true
    (is_enabled ~at:Warn ~threshold:Info);
  Alcotest.(check bool)
    "below threshold" false
    (is_enabled ~at:Debug ~threshold:Info);
  List.iter
    (fun level ->
      Alcotest.(check bool)
        ("none threshold at " ^ to_string level)
        false
        (is_enabled ~at:level ~threshold:None))
    all;
  List.iter
    (fun level ->
      Alcotest.(check bool)
        ("all threshold at " ^ to_string level)
        true
        (is_enabled ~at:level ~threshold:All))
    all

let test_log_level_otel_severity () =
  let open Log_level in
  Alcotest.(check int) "info severity" 9 (to_otel_severity Info);
  Alcotest.(check bool)
    "round-trip 9" true
    (equal Info (of_otel_severity 9))

let test_log_level_of_otel_severity_boundaries () =
  let open Log_level in
  let cases =
    [
      (1, Trace);
      (4, Trace);
      (5, Debug);
      (8, Debug);
      (9, Info);
      (12, Info);
      (13, Warn);
      (16, Warn);
      (17, Error);
      (20, Error);
      (21, Fatal);
      (24, Fatal);
    ]
  in
  List.iter
    (fun (n, expected) ->
      Alcotest.(check bool)
        (Printf.sprintf "of_otel_severity %d" n)
        true
        (equal expected (of_otel_severity n)))
    cases

let test_log_level_of_otel_severity_out_of_range () =
  let open Log_level in
  Alcotest.(check bool)
    "0 -> All" true
    (equal All (of_otel_severity 0));
  Alcotest.(check bool)
    "100 -> Fatal" true
    (equal Fatal (of_otel_severity 100))

let test_log_level_string_roundtrip () =
  let open Log_level in
  List.iter
    (fun level ->
      match of_string (to_string level) with
      | Some actual ->
          Alcotest.(check bool)
            ("round-trip " ^ to_string level)
            true
            (equal level actual)
      | None -> Alcotest.fail ("round-trip failed for " ^ to_string level))
    all;
  Alcotest.(check (option log_level))
    "case insensitive" (Some Info) (of_string "info");
  Alcotest.(check (option log_level))
    "unknown returns None" None (of_string "unknown")

let test_mutable_ref_make_get () =
  let r = Mutable_ref.make 42 in
  Alcotest.(check int) "make then get" 42 (Mutable_ref.get r)

let test_mutable_ref_set () =
  let r = Mutable_ref.make 0 in
  Mutable_ref.set r 7;
  Alcotest.(check int) "set overwrites" 7 (Mutable_ref.get r)

let test_mutable_ref_update () =
  let r = Mutable_ref.make 1 in
  Mutable_ref.update r (fun x -> x + 2);
  Alcotest.(check int) "update applies function" 3 (Mutable_ref.get r)

let test_mutable_ref_update_and_get () =
  let r = Mutable_ref.make 5 in
  let v = Mutable_ref.update_and_get r (fun x -> x * 2) in
  Alcotest.(check int) "update_and_get returns new" 10 v;
  Alcotest.(check int) "update_and_get stores new" 10 (Mutable_ref.get r)

let test_mutable_ref_get_and_set () =
  let r = Mutable_ref.make 3 in
  let old = Mutable_ref.get_and_set r 9 in
  Alcotest.(check int) "get_and_set returns old" 3 old;
  Alcotest.(check int) "get_and_set stores new" 9 (Mutable_ref.get r)

let test_mutable_ref_compare_and_set () =
  let r = Mutable_ref.make "a" in
  let expected = Mutable_ref.get r in
  let ok = Mutable_ref.compare_and_set r expected "b" in
  Alcotest.(check bool) "cas succeeds when expected matches" true ok;
  Alcotest.(check string) "cas stores desired" "b" (Mutable_ref.get r);
  let failed = Mutable_ref.compare_and_set r "a" "c" in
  Alcotest.(check bool) "cas fails when expected mismatches" false failed;
  Alcotest.(check string) "cas leaves value on failure" "b" (Mutable_ref.get r)

let test_mutable_ref_concurrent_update () =
  Eio_main.run @@ fun _stdenv ->
  Eio.Switch.run @@ fun sw ->
  let r = Mutable_ref.make 0 in
  let updates = 10_000 in
  let worker () =
    for _ = 1 to updates do
      Mutable_ref.update r (fun x -> x + 1)
    done
  in
  let left = Eio.Fiber.fork_promise ~sw worker in
  let right = Eio.Fiber.fork_promise ~sw worker in
  Eio.Promise.await_exn left;
  Eio.Promise.await_exn right;
  Alcotest.(check int) "concurrent updates converge" (2 * updates)
    (Mutable_ref.get r)

let test_mutable_ref_incr_decr () =
  let r = Mutable_ref.make 0 in
  Mutable_ref.incr r;
  Alcotest.(check int) "incr" 1 (Mutable_ref.get r);
  Mutable_ref.decr r;
  Alcotest.(check int) "decr" 0 (Mutable_ref.get r);
  Mutable_ref.decr r;
  Alcotest.(check int) "decr again" (-1) (Mutable_ref.get r)

let test_semaphore_make_available () =
  let sem = Semaphore.make ~permits:8 in
  Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

let test_semaphore_acquire_reduces_available () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:8 in
  run_ok rt (Semaphore.acquire sem 1);
  Alcotest.(check int) "available 7" 7 (Semaphore.available sem)

let test_semaphore_release_increases_available () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:8 in
  run_ok rt (Semaphore.acquire sem 1);
  Semaphore.release sem 1;
  Alcotest.(check int) "available 8" 8 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_success () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:5 in
  let result =
    run_ok rt
      (Semaphore.with_permits sem 3 (fun () -> Effect.pure "done"))
  in
  Alcotest.(check string) "result" "done" result;
  Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_failure () =
  with_runtime @@ fun rt ->
  let sem = Semaphore.make ~permits:5 in
  let eff =
    Semaphore.with_permits sem 3 (fun () -> Effect.fail `Boom)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "caught")
  in
  let result = run_ok rt eff in
  Alcotest.(check string) "caught" "caught" result;
  Alcotest.(check int) "available 5" 5 (Semaphore.available sem)

let test_semaphore_with_permits_releases_on_timeout () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:3 in
  let timed_out = ref false in
  let eff =
    Semaphore.with_permits sem 2 (fun () ->
        Effect.delay (Duration.ms 100) Effect.unit)
    |> Effect.timeout (Duration.ms 10)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) ->
         Effect.sync (fun () -> timed_out := true))
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.unit "timed out" () (Eio.Promise.await promise);
  Alcotest.(check bool) "timed_out" true !timed_out;
  Alcotest.(check int) "released" 3 (Semaphore.available sem)

let test_semaphore_cancellation_stress () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:8 in
  let holder =
    Semaphore.with_permits sem 1 (fun () ->
        Effect.delay (Duration.ms 10_000) Effect.unit)
  in
  let holders = List.init 8 (fun _ -> fork_run sw rt holder) in
  wait_for_sleepers clock 8;
  Alcotest.(check int) "available 0" 0 (Semaphore.available sem);
  let waiters =
    List.init 50 (fun _ ->
      fork_run sw rt
        (Semaphore.acquire sem 1
         |> Effect.timeout (Duration.ms 5)
         |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure ())))
  in
  wait_for_sleepers clock 58;
  Test_clock.adjust clock (Duration.ms 5);
  List.iter (fun p -> ignore (Eio.Promise.await p : (unit, _) Exit.t)) waiters;
  Alcotest.(check int) "cancelled waiters" 50
    (Semaphore.cancelled_waiters sem);
  Alcotest.(check int) "waiting 0" 0 (Semaphore.waiting sem);
  Test_clock.adjust clock (Duration.ms 10_000);
  List.iter (fun p -> ignore (Eio.Promise.await p : (unit, _) Exit.t)) holders;
  Alcotest.(check int) "final available" 8 (Semaphore.available sem)

let test_semaphore_multi_permit_contention () =
  with_test_clock @@ fun sw clock rt ->
  let sem = Semaphore.make ~permits:5 in
  let h1 =
    fork_run sw rt
      (Semaphore.acquire sem 2
       |> Effect.bind (fun () ->
            Effect.delay (Duration.ms 50) Effect.unit
            |> Effect.bind (fun () ->
                   Effect.sync (fun () -> Semaphore.release sem 2))))
  in
  let h2 =
    fork_run sw rt
      (Semaphore.acquire sem 2
       |> Effect.bind (fun () ->
            Effect.delay (Duration.ms 100) Effect.unit
            |> Effect.bind (fun () ->
                   Effect.sync (fun () -> Semaphore.release sem 2))))
  in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "available 1" 1 (Semaphore.available sem);
  let waiter =
    fork_run sw rt
      (Semaphore.acquire sem 3
       |> Effect.bind (fun () ->
            Effect.sync (fun () -> Semaphore.release sem 3)
            |> Effect.map (fun () -> "got3")))
  in
  Eio.Fiber.yield ();
  Alcotest.(check int) "waiting 1" 1 (Semaphore.waiting sem);
  Test_clock.adjust clock (Duration.ms 50);
  ignore (Eio.Promise.await h1 : (unit, _) Exit.t);
  check_exit_ok Alcotest.string "waiter got 3" "got3"
    (Eio.Promise.await waiter);
  Alcotest.(check int) "available 3 after waiter" 3
    (Semaphore.available sem);
  Test_clock.adjust clock (Duration.ms 50);
  ignore (Eio.Promise.await h2 : (unit, _) Exit.t);
  Alcotest.(check int) "final available" 5 (Semaphore.available sem)

let () =
  Alcotest.run "eta"
    [
      ( "Log_level",
        [
          Alcotest.test_case "compare ordering" `Quick
            test_log_level_compare_ordering;
          Alcotest.test_case "equal reflexivity symmetry transitivity" `Quick
            test_log_level_equal;
          Alcotest.test_case "is_enabled" `Quick
            test_log_level_is_enabled;
          Alcotest.test_case "otel severity roundtrip" `Quick
            test_log_level_otel_severity;
          Alcotest.test_case "otel severity boundaries" `Quick
            test_log_level_of_otel_severity_boundaries;
          Alcotest.test_case "otel severity out of range" `Quick
            test_log_level_of_otel_severity_out_of_range;
          Alcotest.test_case "string roundtrip" `Quick
            test_log_level_string_roundtrip;
        ] );
      ( "MutableRef",
        [
          Alcotest.test_case "make get" `Quick test_mutable_ref_make_get;
          Alcotest.test_case "set" `Quick test_mutable_ref_set;
          Alcotest.test_case "update" `Quick test_mutable_ref_update;
          Alcotest.test_case "update_and_get" `Quick
            test_mutable_ref_update_and_get;
          Alcotest.test_case "get_and_set" `Quick test_mutable_ref_get_and_set;
          Alcotest.test_case "compare_and_set" `Quick
            test_mutable_ref_compare_and_set;
          Alcotest.test_case "concurrent update" `Quick
            test_mutable_ref_concurrent_update;
          Alcotest.test_case "incr decr" `Quick test_mutable_ref_incr_decr;
        ] );
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "explicit dependency passing" `Quick
            test_explicit_dependency_passing;
          Alcotest.test_case "par returns pair" `Quick
            test_par_returns_both_successes;
          Alcotest.test_case "par keeps heterogeneous successes private" `Quick
            test_par_keeps_heterogeneous_successes_private;
          Alcotest.test_case "par fail-fast cancels sibling" `Quick
            test_par_fail_fast_cancels_sibling;
          Alcotest.test_case "all collects in input order" `Quick
            test_all_collects_in_input_order;
          Alcotest.test_case "all fail-fast" `Quick test_all_fail_fast;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_successes_and_failures;
          Alcotest.test_case "all_settled runs all children" `Quick
            test_all_settled_runs_all_children;
          Alcotest.test_case "all_settled timeout scoped resource typed" `Quick
            test_all_settled_timeout_scoped_resource_is_typed;
          Alcotest.test_case "all_settled empty" `Quick test_all_settled_empty;
          Alcotest.test_case "for_each_par success" `Quick
            test_for_each_par_success;
          Alcotest.test_case "for_each_par one fails" `Quick
            test_for_each_par_one_fails;
          Alcotest.test_case "for_each_par_bounded caps concurrency" `Quick
            test_for_each_par_bounded_caps_concurrency;
          Alcotest.test_case "for_each_par_bounded max one is sequential" `Quick
            test_for_each_par_bounded_max_one_is_sequential;
          Alcotest.test_case "for_each_par_bounded fail-fast" `Quick
            test_for_each_par_bounded_fail_fast;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "catch handler failure uses outer key" `Quick
            test_effect_catch_handler_failure_uses_outer_key;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "runtime exit fail die interrupt" `Quick
            test_runtime_exit_fail_die_interrupt;
          Alcotest.test_case "die captures diagnostics" `Quick
            test_runtime_die_captures_diagnostics;
          Alcotest.test_case "portable cause materializes diagnostics" `Quick
            test_cause_to_portable_materializes_diagnostics;
          Alcotest.test_case "die backtrace capture flag" `Quick
            test_runtime_die_capture_backtrace_can_be_disabled;
          Alcotest.test_case "run_exn preserves backtrace" `Quick
            test_runtime_run_exn_uses_captured_backtrace;
          Alcotest.test_case "concurrent child die captures diagnostics" `Quick
            test_runtime_concurrent_child_die_captures_diagnostics;
          Alcotest.test_case "finalizer die captures diagnostics" `Quick
            test_runtime_finalizer_die_captures_diagnostics;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release on failure" `Quick
            test_acquire_release_on_failure;
          Alcotest.test_case "acquire release suppresses release failure" `Quick
            test_acquire_release_suppresses_release_failure;
          Alcotest.test_case "acquire release release failure after success"
            `Quick test_acquire_release_release_failure_after_success;
          Alcotest.test_case "timeout uses virtual clock" `Quick
            test_effect_timeout_uses_virtual_clock;
          Alcotest.test_case "timeout allows fast success" `Quick
            test_effect_timeout_allows_fast_success;
          Alcotest.test_case "nested timeout maps outer timeout" `Quick
            test_effect_timeout_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "timeout_as exact error row" `Quick
            test_effect_timeout_as_keeps_exact_error_row;
          Alcotest.test_case "timeout_as maps delayed effect" `Quick
            test_effect_timeout_as_maps_delayed_effect;
          Alcotest.test_case "timeout_as nested maps outer timeout" `Quick
            test_effect_timeout_as_nested_cancel_maps_to_outer_timeout;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
          Alcotest.test_case "race all failures returns concurrent causes" `Quick
            test_effect_race_all_failures_returns_concurrent_causes;
          Alcotest.test_case "par simultaneous failures baseline" `Quick
            test_par_simultaneous_failures_records_concurrent_baseline;
          Alcotest.test_case "par finalizer cancellation baseline" `Quick
            test_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "all finalizer cancellation baseline" `Quick
            test_all_finalizer_failure_during_sibling_cancellation_baseline;
          Alcotest.test_case "for_each_par simultaneous failures baseline" `Quick
            test_for_each_par_simultaneous_failures_baseline;
          Alcotest.test_case "for_each_par finalizer cancellation baseline"
            `Quick test_for_each_par_finalizer_failure_during_sibling_cancellation;
          Alcotest.test_case "par nested race failures baseline" `Quick
            test_par_nested_race_all_failures_baseline;
          Alcotest.test_case "repeat schedule" `Quick test_effect_repeat_schedule;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "retry jittered schedule uses runtime random" `Quick
            test_effect_retry_jittered_schedule_uses_runtime_random;
          Alcotest.test_case "retry does not retry interrupt" `Quick
            test_effect_retry_does_not_retry_interrupt;
          Alcotest.test_case "uninterruptible defers race cancellation" `Quick
            test_effect_uninterruptible_defers_race_cancellation;
          Alcotest.test_case "uninterruptible nested masks" `Quick
            test_uninterruptible_nested_masks_wait_for_protected_loser;
          Alcotest.test_case "uninterruptible blocking finalizer" `Quick
            test_uninterruptible_blocking_finalizer_delays_race_completion;
          Alcotest.test_case "uninterruptible timeout inside protected" `Quick
            test_uninterruptible_timeout_inside_protected_still_fires;
          Alcotest.test_case "uninterruptible no-checkpoint loser" `Quick
            test_uninterruptible_race_loser_without_checkpoints_returns;
        ] );
      ( "Island",
        [
          Alcotest.test_case "single uses runtime pool" `Quick
            test_island_single_uses_runtime_pool;
          Alcotest.test_case "requires pool" `Quick test_island_requires_pool;
          Alcotest.test_case "run pool override" `Quick
            test_island_run_pool_override;
          Alcotest.test_case "map preserves order" `Quick
            test_island_map_preserves_order;
          Alcotest.test_case "map_result returns item results" `Quick
            test_island_map_result_returns_item_results;
          Alcotest.test_case "all_settled returns worker_died" `Quick
            test_island_all_settled_returns_worker_died;
          Alcotest.test_case "map worker crash fails outer effect" `Quick
            test_island_map_worker_crash_fails_outer_effect;
          Alcotest.test_case "workloads" `Quick test_island_workloads;
        ] );
      ( "Blocking",
        [
          Alcotest.test_case "submit alias and stats" `Quick
            test_blocking_submit_alias_and_stats;
          Alcotest.test_case "direct control and heartbeat" `Quick
            test_blocking_direct_control_and_blocking_heartbeat;
          Alcotest.test_case "wait caps active and queue" `Quick
            test_blocking_wait_policy_caps_active_and_queue;
          Alcotest.test_case "reject deterministic" `Quick
            test_blocking_reject_policy_deterministic;
          Alcotest.test_case "pending cancellation" `Quick
            test_blocking_pending_cancellation_removes_queued_job;
          Alcotest.test_case "started cancellation nonpreemptive" `Quick
            test_blocking_started_cancellation_is_nonpreemptive;
          Alcotest.test_case "shutdown rejects new jobs" `Quick
            test_blocking_shutdown_rejects_new_jobs;
          Alcotest.test_case "shutdown drain waits" `Quick
            test_blocking_shutdown_drain_waits_for_started;
          Alcotest.test_case "shutdown detach records" `Quick
            test_blocking_shutdown_detach_started_returns_promptly;
          Alcotest.test_case "named pools isolate" `Quick
            test_blocking_named_pools_prevent_starvation;
          Alcotest.test_case "domain isolated hold-lock" `Quick
            test_blocking_domain_isolated_preserves_hold_lock_heartbeat;
          Alcotest.test_case "worker rejects nested submit" `Quick
            test_blocking_worker_rejects_nested_submit;
          Alcotest.test_case "worker rejects runtime run" `Quick
            test_blocking_worker_rejects_runtime_run;
          Alcotest.test_case "cpu antipattern" `Quick
            test_blocking_cpu_antipattern_has_no_speedup;
          Alcotest.test_case "observability labels timings" `Quick
            test_blocking_observability_labels_and_timings;
        ] );
      ( "Supervisor",
        [
          Alcotest.test_case "observes child failure" `Quick
            test_supervisor_observes_child_failure;
          Alcotest.test_case "await rethrows child failure" `Quick
            test_supervisor_await_rethrows_child_failure;
          Alcotest.test_case "cancel runs finalizer" `Quick
            test_supervisor_cancel_runs_finalizer;
          Alcotest.test_case "cancel before await does not deadlock" `Quick
            test_supervisor_cancel_before_await_does_not_deadlock;
          Alcotest.test_case "scope cancels unawaited children" `Quick
            test_supervisor_scope_cancels_unawaited_children_on_return;
          Alcotest.test_case "threshold failure" `Quick
            test_supervisor_threshold_failure;
          Alcotest.test_case "records multiple failures" `Quick
            test_supervisor_records_multiple_failures;
          Alcotest.test_case "nested scopes compose" `Quick
            test_supervisor_nested_scopes_compose;
        ] );
      ( "Clock",
        [
          Alcotest.test_case "sleep without wall time" `Quick
            test_clock_sleep_without_wall_time;
          Alcotest.test_case "sleep delays until adjusted" `Quick
            test_clock_sleep_delays_until_adjusted;
          Alcotest.test_case "multiple sleeps" `Quick
            test_clock_sleep_handles_multiple_sleeps;
          Alcotest.test_case "set_time wakes due sleepers" `Quick
            test_clock_set_time_wakes_due_sleepers;
        ] );
      ( "Duration",
        [
          Alcotest.test_case "constructors" `Quick test_duration_constructors;
          Alcotest.test_case "ordering" `Quick test_duration_ordering;
          Alcotest.test_case "algebra" `Quick test_duration_algebra;
          Alcotest.test_case "min max clamp" `Quick test_duration_min_max_clamp;
        ] );
      ( "Schedule",
        [
          Alcotest.test_case "recurs" `Quick test_recurs;
          Alcotest.test_case "exponential" `Quick test_exponential;
          Alcotest.test_case "spaced fixed linear" `Quick
            test_spaced_fixed_linear;
          Alcotest.test_case "composition" `Quick test_schedule_composition;
          Alcotest.test_case "jittered uses random capability" `Quick
            test_schedule_jittered_uses_random_capability;
        ] );
      ( "Scope",
        [
          Alcotest.test_case "finalizers run in parallel" `Quick
            test_scope_finalizers_run_in_parallel;
        ] );
      ( "Resource",
        [
          Alcotest.test_case "manual refresh" `Quick test_resource_manual_refresh;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_resource_failed_refresh_keeps_cached_value;
          Alcotest.test_case "auto refreshes on schedule" `Quick
            test_resource_auto_refreshes_on_schedule;
          Alcotest.test_case "auto failed refresh keeps cached value" `Quick
            test_resource_auto_failed_refresh_keeps_cached_value;
        ] );
      ( "Portable_queue",
        [
          Alcotest.test_case "backpressure and close" `Quick
            test_portable_queue_backpressure_and_close;
        ] );
      ( "Channel",
        [
          Alcotest.test_case "try send recv" `Quick test_channel_try_send_try_recv;
          Alcotest.test_case "blocking send backpressure" `Quick
            test_channel_blocking_send_backpressure;
          Alcotest.test_case "blocked sender not passed" `Quick
            test_channel_blocked_sender_is_not_passed_by_later_sender;
          Alcotest.test_case "blocking recv" `Quick test_channel_blocking_recv;
          Alcotest.test_case "close wakes blocked users" `Quick
            test_channel_close_wakes_blocked_senders_and_receivers;
          Alcotest.test_case "cancel blocked send" `Quick
            test_channel_cancel_blocked_send_cleans_waiter;
          Alcotest.test_case "cancel blocked recv" `Quick
            test_channel_cancel_blocked_recv_cleans_waiter;
          Alcotest.test_case "parent switch teardown" `Quick
            test_channel_parent_switch_teardown_does_not_hang;
        ] );
      ( "Pool",
        [
          Alcotest.test_case "reuses idle LIFO" `Quick
            test_pool_reuses_idle_lifo;
          Alcotest.test_case "timeout cleans waiter" `Quick
            test_pool_timeout_cleans_waiter_and_preserves_timeout_cause;
          Alcotest.test_case "health rejection reopens" `Quick
            test_pool_health_rejection_reopens;
          Alcotest.test_case "cancel during health check" `Quick
            test_pool_cancel_during_health_check_closes_reserved;
          Alcotest.test_case "idle eviction" `Quick test_pool_idle_eviction;
          Alcotest.test_case "shutdown wakes and drains" `Quick
            test_pool_shutdown_wakes_waiters_and_drains;
          Alcotest.test_case "shutdown deadline" `Quick
            test_pool_shutdown_deadline_timeout;
          Alcotest.test_case "observability signals" `Quick
            test_pool_observability_signals;
        ] );
      ( "Semaphore",
        [
          Alcotest.test_case "make and available" `Quick
            test_semaphore_make_available;
          Alcotest.test_case "acquire reduces available" `Quick
            test_semaphore_acquire_reduces_available;
          Alcotest.test_case "release increases available" `Quick
            test_semaphore_release_increases_available;
          Alcotest.test_case "with_permits releases on success" `Quick
            test_semaphore_with_permits_releases_on_success;
          Alcotest.test_case "with_permits releases on failure" `Quick
            test_semaphore_with_permits_releases_on_failure;
          Alcotest.test_case "with_permits releases on timeout" `Quick
            test_semaphore_with_permits_releases_on_timeout;
          Alcotest.test_case "cancellation stress" `Quick
            test_semaphore_cancellation_stress;
          Alcotest.test_case "multi-permit contention" `Quick
            test_semaphore_multi_permit_contention;
        ] );
      ( "Properties",
        [
          Alcotest.test_case "monad laws" `Quick test_properties_monad_laws;
          Alcotest.test_case "catch laws" `Quick test_properties_catch_laws;
          Alcotest.test_case "race success invariant" `Quick
            test_properties_race_success_invariant;
          Alcotest.test_case "retry and repeat laws" `Quick
            test_properties_retry_and_repeat_laws;
          Alcotest.test_case "scope finalizers exactly once" `Quick
            test_properties_scope_finalizers_once;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "manual tracer spans" `Quick
            test_tracer_manual_spans;
          Alcotest.test_case "named span status ok" `Quick
            test_observability_named_ok;
          Alcotest.test_case "span kind" `Quick test_observability_span_kind;
          Alcotest.test_case "fn records location" `Quick test_observability_fn_loc;
          Alcotest.test_case "annotation order" `Quick
            test_observability_annotation_order;
          Alcotest.test_case "nested spans" `Quick test_observability_nested_spans;
          Alcotest.test_case "statuses" `Quick test_observability_statuses;
          Alcotest.test_case "concurrent status" `Quick
            test_observability_concurrent_status;
          Alcotest.test_case "cancelled child status" `Quick
            test_observability_cancelled_parallel_child_status;
          Alcotest.test_case "uninterruptible child status" `Quick
            test_observability_uninterruptible_parallel_child_status;
          Alcotest.test_case "par children inherit parent" `Quick
            test_observability_par_children_inherit_parent;
          Alcotest.test_case "par pending attrs links are fiber-local" `Quick
            test_observability_par_pending_attrs_links_are_fiber_local;
          Alcotest.test_case "sampler always off" `Quick
            test_observability_sampler_always_off;
          Alcotest.test_case "sampler ratio" `Quick
            test_observability_sampler_ratio;
          Alcotest.test_case "sampler parent based" `Quick
            test_observability_sampler_parent_based;
          Alcotest.test_case "sampler suppresses par children" `Quick
            test_observability_sampler_unsampled_parent_suppresses_par_children;
          Alcotest.test_case "noop runtime keeps die diagnostics" `Quick
            test_observability_noop_runtime_keeps_die_diagnostics;
          Alcotest.test_case "trace context extract inject" `Quick
            test_trace_context_extract_inject;
          Alcotest.test_case "trace context rejects malformed traceparent" `Quick
            test_trace_context_rejects_malformed_traceparent;
          Alcotest.test_case "trace context par inherits baggage" `Quick
            test_trace_context_current_and_par_inherit_baggage;
          Alcotest.test_case "trace context unsampled parent suppresses child"
            `Quick
            test_trace_context_unsampled_parent_suppresses_child;
          Alcotest.test_case "auto instrument default off" `Quick
            test_observability_auto_instrument_default_off;
          Alcotest.test_case "auto instrument sync leaves" `Quick
            test_observability_auto_instrument_eval_leaves;
          Alcotest.test_case "auto instrument leaves nest" `Quick
            test_observability_auto_instrument_leaves_nest_under_named;
          Alcotest.test_case "auto instrument failure status" `Quick
            test_observability_auto_instrument_failure_status;
          Alcotest.test_case "all for_each_par supervisor inherit parent" `Quick
            test_observability_all_for_each_supervisor_inherit_parent;
        ] );
      ( "Redacted",
        [
          Alcotest.test_case "pp unlabelled" `Quick test_redacted_pp_unlabelled;
          Alcotest.test_case "pp labelled" `Quick test_redacted_pp_labelled;
          Alcotest.test_case "equal" `Quick test_redacted_equal;
          Alcotest.test_case "hash" `Quick test_redacted_hash;
          Alcotest.test_case "wipe_unsafe" `Quick test_redacted_wipe_unsafe;
          Alcotest.test_case "label" `Quick test_redacted_label;
        ] );
    ]
