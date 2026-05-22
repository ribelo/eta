open Effet

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

module Test_clock = struct
  type sleeper = { deadline_ms : int; resolver : unit Eio.Promise.u }
  type t = { mutable now_ms : int; mutable sleepers : sleeper list }

  let create () = { now_ms = 0; sleepers = [] }

  let wake_due t =
    let due, pending =
      List.partition (fun sleeper -> sleeper.deadline_ms <= t.now_ms) t.sleepers
    in
    t.sleepers <- pending;
    List.iter
      (fun sleeper -> Eio.Promise.resolve sleeper.resolver ())
      due

  let sleep t duration =
    let deadline_ms = t.now_ms + Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      t.sleepers <- { deadline_ms; resolver } :: t.sleepers;
      Eio.Promise.await promise

  let adjust t duration =
    t.now_ms <- t.now_ms + Duration.to_ms duration;
    wake_due t

  let set_time t time_ms =
    t.now_ms <- max 0 time_ms;
    wake_due t

  let sleeper_count t = List.length t.sleepers
end

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~tracer:(Tracer.as_capability tracer) ()
  in
  f sw clock rt tracer

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
        Effect.thunk "leaf-a" (fun () -> ()) |> Effect.map (fun _ -> ());
        Effect.thunk "leaf-b" (fun () -> ());
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
       (Effect.named "die" (Effect.thunk "die" (fun () -> failwith "boom"))) :
      (unit, _) Exit.t);
  ignore
    (Runtime.run rt
	       (Effect.named "interrupt"
	          (Effect.thunk "interrupt" (fun () ->
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
  run_ok rt (Effect.thunk "leaf" (fun () -> ()));
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_auto_instrument_eval_leaves () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.thunk name (fun () -> ()) in
  run_ok rt (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]);
  Alcotest.(check (list string)) "leaf spans" [ "a"; "b"; "c" ]
    (List.map (fun span -> span.Tracer.name) (Tracer.dump tracer))

let test_observability_auto_instrument_leaves_nest_under_named () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.thunk name (fun () -> ()) in
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
  ignore (Runtime.run rt (Effect.thunk "boom" (fun () -> failwith "boom")) :
            (unit, _) Exit.t);
  let span = only_span tracer in
  check_status "leaf failed" (Tracer.Error "") span.status;
  match span.events with
  | [ event ] ->
      Alcotest.(check (option string)) "leaf cause path" (Some "cause")
        (List.assoc_opt "effet.cause.path" event.Tracer.ev_attrs);
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
    (Schedule.next_delay ~random schedule ~step:0)

let test_effect_map_bind_tap_runtime () =
  with_runtime @@ fun rt ->
  let observed = ref [] in
  let eff =
    Effect.pure 1
    |> Effect.map (fun n -> n + 1)
    |> Effect.bind (fun n -> Effect.pure (n * 2))
    |> Effect.tap (fun n ->
           Effect.thunk "tap" (fun () -> observed := n :: !observed))
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
  check_exit_error
    (Alcotest.testable
       (Cause.pp (fun fmt -> function
         | `Inner -> Format.pp_print_string fmt "inner"
         | `Outer -> Format.pp_print_string fmt "outer"))
       ( = ))
    "handler failure is not recaught" (Cause.Fail `Outer) (Runtime.run rt eff)

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
  let die_exit = Runtime.run rt (Effect.thunk "die" (fun () -> raise die)) in
  let interrupt_exit =
    Runtime.run rt
      (Effect.thunk "interrupt" (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  check_exit_error string_cause "typed failure" (Cause.Fail "bad") fail_exit;
  (match die_exit with
  | Exit.Error (Cause.Die actual) ->
      Alcotest.(check bool) "same exception" true (actual.exn == die)
  | _ -> Alcotest.fail "expected Die");
  (match interrupt_exit with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt")

let test_runtime_die_captures_diagnostics () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt _tracer ->
  let exn = Failure "diagnostic boom" in
  let eff =
    Effect.thunk "die.leaf" (fun () -> raise exn)
    |> Effect.annotate ~key:"request.id" ~value:"r-1"
    |> Effect.fn __POS__ "diagnostic.fn"
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check bool) "same exception" true (die.exn == exn);
      Alcotest.(check (option string)) "span name" (Some "diagnostic.fn")
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
    Runtime.run rt (Effect.thunk "die.no-backtrace" (fun () -> failwith "boom"))
  with
  | Exit.Error (Cause.Die die) ->
      Alcotest.(check (option string)) "no backtrace" None
        (Option.map Printexc.raw_backtrace_to_string die.backtrace)
  | _ -> Alcotest.fail "expected Die"

let test_runtime_run_exn_uses_captured_backtrace () =
  with_runtime @@ fun rt ->
  let exn = Failure "run_exn defect" in
  match Runtime.run_exn rt (Effect.thunk "die.run_exn" (fun () -> raise exn)) with
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
    Effect.thunk name (fun () ->
        Eio.Promise.resolve own_ready ();
        Eio.Promise.await other_ready;
        raise (Failure name))
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
        [ "left.span"; "right.span" ]
        (dies
        |> List.map (fun die -> Option.value die.Cause.span_name ~default:"")
        |> List.sort String.compare);
      List.iter
        (fun die ->
          let expected =
            match die.Cause.span_name with
            | Some "left.span" -> Some "left"
            | Some "right.span" -> Some "right"
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
    Effect.thunk "release.leaf" (fun () -> raise release_exn)
    |> Effect.annotate ~key:"phase" ~value:"release"
    |> Effect.named "release.span"
  in
  let body =
    Effect.thunk "body.leaf" (fun () -> raise body_exn)
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
      Alcotest.(check (option string)) "primary span" (Some "body.span")
        primary.span_name;
      Alcotest.(check bool) "finalizer exn" true (finalizer.exn == release_exn);
      Alcotest.(check (option string)) "finalizer span" (Some "release.span")
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
    Effect.thunk "interrupt" (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt"

let test_effect_retry_does_not_retry_interrupt () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.thunk "interrupt" (fun () ->
        incr attempts;
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
  in
  let eff = Effect.retry (Schedule.recurs 3) (fun (_ : string) -> true) attempt in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt");
  Alcotest.(check int) "not retried" 1 !attempts

let test_acquire_release () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.thunk name (fun () -> trail := name :: !trail) in
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
  let mark name = Effect.thunk name (fun () -> trail := name :: !trail) in
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
  check_exit_ok Alcotest.int "first success wins" 100
    (Eio.Promise.await promise)

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
    Effect.thunk name (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go)
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
           (Effect.thunk "par.slow.acquire" (fun () ->
                Eio.Promise.resolve acquired_u ()))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.thunk "par.body.wait_for_acquire" (fun () ->
        Eio.Promise.await acquired)
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
           (Effect.thunk "slow.acquire" (fun () ->
                Eio.Promise.resolve acquired_u ()))
         ~release:(fun () ->
           release_started := true;
           Effect.fail "release")
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit))
  in
  let body =
    Effect.thunk "body.wait_for_acquire" (fun () -> Eio.Promise.await acquired)
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
    Effect.thunk ("worker." ^ name) (fun () ->
        if name <> "ok" then (
          Eio.Stream.add ready name;
          Eio.Promise.await go);
        name)
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
               (Effect.thunk "foreach.slow.acquire" (fun () ->
                    Eio.Promise.resolve acquired_u ()))
             ~release:(fun () ->
               release_started := true;
               Effect.fail "release")
          |> Effect.bind (fun () ->
                 Effect.delay (Duration.ms 1_000) Effect.unit))
    | "body" ->
        Effect.thunk "foreach.body.wait_for_acquire" (fun () ->
            Eio.Promise.await acquired)
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
  let tick = Effect.thunk "tick" (fun () -> incr ticks) in
  run_ok rt (Effect.repeat (Schedule.recurs 3) tick);
  Alcotest.(check int) "initial run plus three repeats" 4 !ticks

let test_effect_repeat_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let ticks = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
  in
  let promise =
    fork_run sw rt (Effect.thunk "tick" (fun () -> incr ticks) |> Effect.repeat schedule)
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
    Effect.thunk "attempt" (fun () ->
        incr attempts;
        !attempts)
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
    Effect.thunk "attempt" (fun () ->
        incr attempts;
        !attempts)
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
    Effect.thunk "attempt" (fun () ->
        incr attempts;
        !attempts)
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
      ~acquire:(Effect.thunk "supervisor.acquire" (fun () -> ()))
      ~release:(fun () ->
        Effect.thunk "supervisor.release" (fun () -> finalizer_ran := true))
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
              (Effect.thunk "supervisor.wait_for_child" (fun () ->
                   wait_for_sleepers clock 1))
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
    Effect.thunk "slow.done" (fun () ->
        slow_completed := true;
        "slow")
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
    Effect.thunk "nested.done" (fun () ->
        slow_completed := true;
        "slow")
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
           Effect.thunk "release.done" (fun () -> released := true)
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
    Effect.thunk "cpu.loser" (fun () ->
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
        Effect.thunk "release" (fun () -> incr released)
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
  let load = Effect.thunk "resource.load" (fun () -> !source) in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Resource.get resource
           |> Effect.bind (fun initial ->
                  Effect.thunk "source.set" (fun () -> source := 1)
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
    Effect.thunk "resource.load" (fun () -> !source)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Effect.thunk "source.fail" (fun () -> source := Error "Uh oh!")
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
    Effect.thunk "resource.auto.load" (fun () ->
        incr source;
        !source)
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
    Effect.thunk "resource.auto.load" (fun () ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result)
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
    Effect.thunk "law.add" (fun () -> deps.add 1);
    Effect.thunk "law.mul" (fun () -> deps.mul 2);
    Effect.pure 2 |> Effect.map (fun n -> n + 4);
    Effect.pure 3 |> Effect.bind (fun n -> Effect.pure (n * 3));
    Effect.fail `E0 |> Effect.catch (fun `E0 -> Effect.pure 7);
  ]

let law_functions deps : (string * (int -> (int, law_err) Effect.t)) list =
  [
    ("inc", fun x -> Effect.pure (x + 1));
    ( "fail-negative",
      fun x -> if x < 0 then Effect.fail `Neg else Effect.pure (x * 2) );
    ("deps-add", fun x -> Effect.thunk "law.f.add" (fun () -> deps.add x));
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
        Effect.thunk "retry.always-succeed" (fun () ->
            incr attempts;
            i)
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
           (Effect.thunk "repeat.tick" (fun () -> incr ticks)));
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
        ~acquire:(Effect.thunk ("acquire." ^ name) (fun () -> ()))
        ~release:(fun () ->
          Effect.thunk ("release." ^ name) (fun () ->
              releases := name :: !releases))
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
      ~acquire:(Effect.thunk "acquire.cancelled" (fun () ->
          Eio.Promise.resolve acquired_u ()))
      ~release:(fun () ->
        Effect.thunk "release.cancelled" (fun () -> incr releases))
  in
  let slow =
    Effect.scoped
      (resource
      |> Effect.bind (fun () ->
             Effect.pure "slow" |> Effect.delay (Duration.seconds 10)))
  in
  let fast =
    Effect.thunk "wait-acquired" (fun () -> Eio.Promise.await acquired)
    |> Effect.map (fun () -> "fast")
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  check_exit_ok Alcotest.string "fast wins" "fast" (Eio.Promise.await promise);
  Alcotest.(check int) "cancelled release once" 1 !releases

(* Dependencies are ordinary OCaml values. A composes B and C by closing over
   the explicit dependency record, without an ambient Effet env channel. *)
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
  let b msg = Effect.thunk "log" (fun () -> services#info msg) in
  let c id =
    Effect.thunk "db" (fun () -> services#query (string_of_int (deps.add id)))
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
    Effect.thunk "slow" (fun () ->
        Eio.Fiber.yield ();
        other_done := true;
        99)
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
    Effect.thunk name (fun () -> incr slow_done)
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
    Effect.thunk "enter" (fun () ->
        incr active;
        max_seen := max !max_seen !active)
    |> Effect.bind (fun () ->
           Effect.pure x
           |> Effect.delay (Duration.ms 10)
           |> Effect.tap (fun _ ->
                  Effect.thunk "leave" (fun () -> decr active)))
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
    Effect.thunk "worker" (fun () ->
        incr active;
        max_seen := max !max_seen !active;
        decr active;
        x)
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
        Effect.thunk "slow" (fun () -> slow_done := true)
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

external hold_lock_sleep : float -> unit = "effet_test_hold_lock_sleep"

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
            String.equal point.Meter.name "effet.blocking.run_ms"
            && List.mem ("effet.blocking.pool", "detach") point.attrs
            && List.exists
                 (fun (k, v) ->
                   String.equal k "effet.blocking.outcome"
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
  if not (domain_p99 < 20_000 && domain_p99 < normal_p99) then
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
             String.equal event.Tracer.ev_name "effet.blocking"
             && List.mem ("effet.blocking.name", "test.label") event.ev_attrs
             && List.mem ("effet.blocking.pool", "observed") event.ev_attrs)
           span.Tracer.events)
       spans);
  Alcotest.(check bool) "run timing metric" true
    (Meter.dump meter
     |> List.exists (fun point ->
            String.equal point.Meter.name "effet.blocking.run_ms"
            && List.mem ("effet.blocking.name", "test.label") point.attrs
            &&
            match point.value with Meter.Int ms -> ms >= 15 | Meter.Float _ -> false))

let () =
  Alcotest.run "effet"
    [
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
          Alcotest.test_case "auto instrument thunk leaves" `Quick
            test_observability_auto_instrument_eval_leaves;
          Alcotest.test_case "auto instrument leaves nest" `Quick
            test_observability_auto_instrument_leaves_nest_under_named;
          Alcotest.test_case "auto instrument failure status" `Quick
            test_observability_auto_instrument_failure_status;
          Alcotest.test_case "all for_each_par supervisor inherit parent" `Quick
            test_observability_all_for_each_supervisor_inherit_parent;
        ] );
    ]
