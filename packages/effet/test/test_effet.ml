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
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~env:() ()
  in
  f rt tracer

let with_sampled_traced_runtime sampler f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~sampler ~env:() ()
  in
  f rt tracer

let with_auto_traced_runtime auto_instrument f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~auto_instrument ~env:() ()
  in
  f rt tracer

let with_runtime_capture_backtrace capture_backtrace f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~capture_backtrace
      ~env:() ()
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
      ~sleep:(Test_clock.sleep clock) ~env:() ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~tracer:(Tracer.as_capability tracer)
      ~env:() ()
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
        Effect.thunk "leaf-a" (fun _ -> ()) |> Effect.map (fun _ -> ());
        Effect.thunk "leaf-b" (fun _ -> ());
      ]
    |> Effect.named "outer"
  in
  Alcotest.(check (list string))
    "names in pre-order"
    [ "outer"; "leaf-a"; "leaf-b" ]
    (Effect.collect_names e)

let test_tracer_manual_spans () =
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
  let fail_eff : (unit, observability_err, unit) Effect.t =
    Effect.named "fail" (Effect.fail `Boom)
  in
  ignore (Runtime.run rt fail_eff : (unit, observability_err) Exit.t);
  let render_db : observability_err -> string = function
    | `Db code -> "db:" ^ string_of_int code
    | _ -> "<unexpected>"
  in
  let custom_eff : (unit, observability_err, unit) Effect.t =
    Effect.named ~error_renderer:render_db "custom" (Effect.fail (`Db 42))
  in
  ignore
    (Runtime.run rt custom_eff : (unit, observability_err) Exit.t);
  let inner = Effect.named "inner" (Effect.fail `Inner) in
  let render_outer : observability_err -> string = function
    | `Outer -> "outer"
    | _ -> "<unexpected>"
  in
  let outer : (unit, observability_err, unit) Effect.t =
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
      ~acquire:(Effect.thunk "supervisor.acquire" (fun _ -> ()))
      ~release:(fun () ->
        Effect.thunk "supervisor.release" (fun _ -> finalizer_ran := true))
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
              (Effect.thunk "supervisor.wait_for_child" (fun _ ->
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
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
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

type law_env = < add : int -> int ; mul : int -> int >

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
  let env =
    object
      method add n = n + 1
      method mul n = n * 2
    end
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env ()
  in
  f rt

let check_law rt name left right =
  let left_exit = Runtime.run rt left in
  let right_exit = Runtime.run rt right in
  if not (Exit.equal Int.equal equal_law_err left_exit right_exit) then
    Alcotest.failf "%s failed:@.left:  %a@.right: %a" name
      (Exit.pp Format.pp_print_int pp_law_err)
      left_exit
      (Exit.pp Format.pp_print_int pp_law_err)
      right_exit

let law_effects () : (law_env, law_err, int) Effect.t list =
  [
    Effect.pure (-2);
    Effect.pure 0;
    Effect.pure 3;
    Effect.fail `E0;
    Effect.fail `E1;
    Effect.thunk "law.add" (fun env -> env#add 1);
    Effect.thunk "law.mul" (fun env -> env#mul 2);
    Effect.pure 2 |> Effect.map (fun n -> n + 4);
    Effect.pure 3 |> Effect.bind (fun n -> Effect.pure (n * 3));
    Effect.fail `E0 |> Effect.catch (fun `E0 -> Effect.pure 7);
  ]

let law_functions () :
    (string * (int -> (law_env, law_err, int) Effect.t)) list =
  [
    ("inc", fun x -> Effect.pure (x + 1));
    ( "fail-negative",
      fun x -> if x < 0 then Effect.fail `Neg else Effect.pure (x * 2) );
    ("env-add", fun x -> Effect.thunk "law.f.add" (fun env -> env#add x));
    ("mapped", fun x -> Effect.pure x |> Effect.map (fun n -> n + 3));
    ( "catch-local",
      fun x -> Effect.fail `E0 |> Effect.catch (fun `E0 -> Effect.pure (x + 5)) );
  ]

let test_properties_monad_laws () =
  with_law_runtime @@ fun rt ->
  let values = [ -2; 0; 3 ] in
  let effects = law_effects () in
  let functions = law_functions () in
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

let catch_handler : law_err -> (law_env, law_err, int) Effect.t = function
  | `E0 -> Effect.pure 10
  | `E1 -> Effect.pure 20
  | `Neg -> Effect.pure 30
  | `Retry -> Effect.pure 40
  | `Release -> Effect.pure 50
  | `Timeout -> Effect.pure 60

let test_properties_catch_laws () =
  with_law_runtime @@ fun rt ->
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
        (law_functions ()))
    ([ `E0; `E1; `Neg ] : law_err list);
  List.iter
    (fun x ->
      check_law rt "catch handles continuation failure"
        (Effect.catch catch_handler
           (Effect.bind (fun _ -> Effect.fail `E1) (Effect.pure x)))
        (catch_handler `E1))
    [ -2; 0; 3 ]

let test_properties_race_success_invariant () =
  with_law_runtime @@ fun rt ->
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
  with_law_runtime @@ fun rt ->
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
        Effect.thunk "retry.always-succeed" (fun _ ->
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
           (Effect.thunk "repeat.tick" (fun _ -> incr ticks)));
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

(* Auto-DI regression: A defined without naming services or threading.
   The env-row property is the whole reason for the 'env channel.
   See journal V-R10 and scratch/r_research/r_b_env_row.ml. *)
let test_env_row_auto_di () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let log_calls = ref [] in
  let env =
    object
      method db = object method query s = "row:" ^ s end
      method log =
        object method info m = log_calls := m :: !log_calls end
    end
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env ()
  in
  let b msg = Effect.thunk "log" (fun env -> env#log#info msg) in
  let c id = Effect.thunk "db" (fun env -> env#db#query id) in
  (* A composes B and C without naming services or threading. *)
  let a id =
    let open Effect in
    bind (fun () -> c id) (b ("fetching " ^ id))
  in
  match Runtime.run rt (a "42") with
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
    Effect.thunk "slow" (fun _ ->
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

let () =
  Alcotest.run "effet"
    [
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "env row auto DI" `Quick test_env_row_auto_di;
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
