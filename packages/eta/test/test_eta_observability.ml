open Eta
open Test
open Test_eta_support

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
  check_error_message "inner default" "<unexpected>" (find "inner").status;
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

let test_observability_sampler_ratio_same_name_uses_trace_id () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~sampler:(Sampler.ratio 0.5)
      ~random:(Capabilities.random_of_seed 0x51a7) ()
  in
  let spans = List.init 200 (fun _ -> Effect.named "same" Effect.unit) in
  run_ok rt (Effect.concat spans);
  let count = List.length (Tracer.dump tracer) in
  Alcotest.(check bool) "same-name roots mixed" true (count > 0 && count < 200)

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

let counting_noop_tracer count : Capabilities.tracer =
  object
    method with_fiber_context : 'a. (unit -> 'a) -> 'a = fun f -> f ()

    method begin_span ?parent_id:_ ?external_parent:_ ?trace_id:_ ?trace_flags:_
        ?trace_state:_ ?baggage:_ ?kind:_ ~name:_ ~started_ms:_ () =
      incr count;
      -1

    method end_span ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr ~key:_ ~value:_ = ()
    method add_attr_to ~span_id:_ ~key:_ ~value:_ = ()
    method add_event ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
    method add_link _ = ()
    method add_link_to ~span_id:_ _ = ()
    method inspect ~span_id:_ = None
  end

let test_observability_custom_noop_tracer_is_explicitly_enabled () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let spans_started = ref 0 in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(counting_noop_tracer spans_started) ()
  in
  check_exit_ok Alcotest.unit "named" ()
    (Runtime.run rt (Effect.named "custom.noop" Effect.unit));
  Alcotest.(check int) "custom tracer enabled" 1 !spans_started

let test_observability_suppress_observability () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let logger = Logger.in_memory () in
  let meter = Meter.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ~logger:(Logger.as_capability logger)
      ~meter:(Meter.as_capability meter) ()
  in
  let hidden =
    Effect.concat
      [
        Effect.log "hidden log";
        Effect.metric_update ~name:"hidden.metric" ~kind:Meter.Counter_cumulative
          (Meter.Int 1);
      ]
    |> Effect.named "hidden span"
    |> Effect.suppress_observability
  in
  run_ok rt hidden;
  Alcotest.(check int) "spans" 0 (List.length (Tracer.dump tracer));
  Alcotest.(check int) "logs" 0 (List.length (Logger.dump logger));
  Alcotest.(check int) "metrics" 0 (List.length (Meter.dump meter))

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

let test_in_memory_tracer_current_span_has_valid_ids () =
  with_traced_runtime @@ fun rt _tracer ->
  let info =
    run_ok rt (Effect.named "root" Effect.current_span)
    |> require_current_span
  in
  Alcotest.(check bool)
    "trace_id 32 lower hex" true
    (is_lower_hex ~len:32 info.trace_id);
  Alcotest.(check bool)
    "span_id 16 lower hex" true
    (is_lower_hex ~len:16 info.span_id)

let test_in_memory_tracer_child_inherits_trace_id () =
  with_traced_runtime @@ fun rt _tracer ->
  let parent, child =
    run_ok rt
      (Effect.named "parent"
         (Effect.bind
            (fun parent ->
              Effect.named "child"
                (Effect.map
                   (fun child ->
                     (require_current_span parent, require_current_span child))
                   Effect.current_span))
            Effect.current_span))
  in
  Alcotest.(check string) "child trace_id" parent.trace_id child.trace_id;
  Alcotest.(check bool) "distinct span_id" true
    (not (String.equal parent.span_id child.span_id))

let test_in_memory_tracer_external_context_trace_id_wins () =
  with_traced_runtime @@ fun rt _tracer ->
  let ctx =
    Option.get
      (Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
         ~span_id:"00f067aa0ba902b7" ())
  in
  let info =
    run_ok rt
      (Effect.with_context ctx (Effect.named "external" Effect.current_span))
    |> require_current_span
  in
  Alcotest.(check string) "trace_id" ctx.trace_id info.trace_id;
  Alcotest.(check bool)
    "span_id 16 lower hex" true
    (is_lower_hex ~len:16 info.span_id);
  Alcotest.(check bool) "new span id" true
    (not (String.equal ctx.span_id info.span_id))

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
