module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let pp_hidden ppf _ = Format.pp_print_string ppf "<observability>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let pp_log_level fmt = function
    | Capabilities.Trace -> Format.pp_print_string fmt "Trace"
    | Capabilities.Debug -> Format.pp_print_string fmt "Debug"
    | Capabilities.Info -> Format.pp_print_string fmt "Info"
    | Capabilities.Warn -> Format.pp_print_string fmt "Warn"
    | Capabilities.Error -> Format.pp_print_string fmt "Error"
    | Capabilities.Fatal -> Format.pp_print_string fmt "Fatal"

  let log_level = Alcotest.testable pp_log_level ( = )

  let check_exit_ok testable label expected = function
    | Exit.Ok actual -> Alcotest.check testable label expected actual
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Ok, got %a" label (Cause.pp pp_hidden)
          cause

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected at least %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 20

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

  let is_lower_hex ~len value =
    String.length value = len
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         value

  let require_current_span = function
    | Some span -> span
    | None -> Alcotest.fail "expected current span"

  let only_log logger =
    match Logger.dump logger with
    | [ record ] -> record
    | records -> Alcotest.failf "expected one log, got %d" (List.length records)

  let log_attr key record = List.assoc_opt key record.Logger.attrs

  type observability_err = [ `Boom | `Db of int | `Inner | `Outer ]

  let test_tracer_manual_spans () =
    B.with_runtime_contract @@ fun _ctx contract ->
    Tracer.with_task_context contract @@ fun () ->
    let tracer = Tracer.in_memory () in
    let t = Tracer.as_capability tracer in
    t#add_attr contract ~key:"pending" ~value:"yes";
    let parent = t#begin_span contract ~name:"parent" ~started_ms:1 () in
    t#add_attr contract ~key:"inside" ~value:"parent";
    let child = t#begin_span contract ~name:"child" ~started_ms:2 () in
    t#end_span contract ~span_id:child ~status:Tracer.Ok ~ended_ms:3;
    t#end_span contract ~span_id:parent ~status:(Tracer.Error "boom")
      ~ended_ms:4;
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
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let eff = Effect.named "foo" (Effect.pure 1) in
    Alcotest.(check int) "value" 1 (run_ok rt eff);
    let span = only_span tracer in
    Alcotest.(check string) "name" "foo" span.name;
    check_status "status" Tracer.Ok span.status

  let test_observability_span_kind () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    run_ok rt (Effect.named_kind ~kind:Capabilities.Server "server" Effect.unit);
    let span = only_span tracer in
    Alcotest.(check bool) "server kind" true (span.kind = Tracer.Server)

  let test_observability_fn_loc () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let program = Effect.fn __POS__ __FUNCTION__ (Effect.pure ()) in
    run_ok rt program;
    let span = only_span tracer in
    Alcotest.(check string) "name" __FUNCTION__ span.name;
    match attr "loc" span with
    | Some loc -> Alcotest.(check bool) "test file" true (String.contains loc '/')
    | None -> Alcotest.fail "missing loc attr"

  let test_observability_annotate_all_and_fn_attrs () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let program =
      Effect.fn
        ~attrs:[ ("component", "ingest"); ("phase", "assets") ]
        __POS__ "ingest.assets" Effect.unit
    in
    run_ok rt program;
    let span = only_span tracer in
    Alcotest.(check (option string)) "component" (Some "ingest")
      (attr "component" span);
    Alcotest.(check (option string)) "phase" (Some "assets")
      (attr "phase" span);
    Alcotest.(check bool) "loc present" true (Option.is_some (attr "loc" span))

  let test_observability_event_records_current_span () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let program =
      Effect.named "ingest.assets"
        (Effect.event ~attrs:[ ("batch", "1") ] "ingest.assets.progress")
    in
    run_ok rt program;
    let span = only_span tracer in
    match span.events with
    | [ event ] ->
        Alcotest.(check string) "event name" "ingest.assets.progress"
          event.Tracer.ev_name;
        Alcotest.(check (option string)) "event attr" (Some "1")
          (List.assoc_opt "batch" event.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one span event, got %d" (List.length events)

  let test_observability_with_result_attrs () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let observe eff =
      Effect.with_result_attrs
        ~ok_attrs:(fun rows ->
          [ ("result", "ok"); ("row_count", string_of_int (List.length rows)) ])
        ~err_attrs:(fun (`Bad code) ->
          [ ("result", "error"); ("error.code", string_of_int code) ])
        eff
    in
    let ok_effect = Effect.named "rows.ok" (observe (Effect.pure [ 1; 2; 3 ])) in
    let err_effect = Effect.named "rows.err" (observe (Effect.fail (`Bad 7))) in
    Alcotest.(check (list int)) "ok value" [ 1; 2; 3 ] (run_ok rt ok_effect);
    ignore (B.run rt err_effect : (int list, [ `Bad of int ]) Exit.t);
    let spans = Tracer.dump tracer in
    let find name = List.find (fun span -> String.equal span.Tracer.name name) spans in
    let ok_span = find "rows.ok" in
    let err_span = find "rows.err" in
    Alcotest.(check (option string)) "ok result" (Some "ok")
      (attr "result" ok_span);
    Alcotest.(check (option string)) "row count" (Some "3")
      (attr "row_count" ok_span);
    Alcotest.(check (option string)) "error result" (Some "error")
      (attr "result" err_span);
    Alcotest.(check (option string)) "error code" (Some "7")
      (attr "error.code" err_span)

  let test_observability_annotation_order () =
    let run eff =
      B.with_traced_runtime @@ fun _ctx rt tracer ->
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

  let test_observability_statuses () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let fail_eff : (unit, observability_err) Effect.t =
      Effect.named "fail" (Effect.fail `Boom)
    in
    ignore (B.run rt fail_eff : (unit, observability_err) Exit.t);
    let render_db : observability_err -> string = function
      | `Db code -> "db:" ^ string_of_int code
      | _ -> "<unexpected>"
    in
    let custom_eff : (unit, observability_err) Effect.t =
      Effect.named ~error_renderer:render_db "custom" (Effect.fail (`Db 42))
    in
    ignore (B.run rt custom_eff : (unit, observability_err) Exit.t);
    let inner = Effect.named "inner" (Effect.fail `Inner) in
    let render_outer : observability_err -> string = function
      | `Outer -> "outer"
      | _ -> "<unexpected>"
    in
    let outer : (unit, observability_err) Effect.t =
      Effect.named ~error_renderer:render_outer "outer"
        (Effect.catch (function `Inner -> Effect.fail `Outer) inner)
    in
    ignore (B.run rt outer : (unit, observability_err) Exit.t);
    ignore
      (B.run rt
         (Effect.named "die" (Effect.sync (fun () -> failwith "boom"))) :
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
    check_status "die" (Tracer.Error "") (find "die").status

  let test_observability_nested_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
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

  let test_observability_renderer_exception_preserves_failure () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let render _ = failwith "renderer exploded" in
    let eff =
      Effect.named ~error_renderer:render "renderer-fails"
        (Effect.fail "original")
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Fail msg) ->
        Alcotest.(check string) "original failure" "original" msg
    | Exit.Error _ -> Alcotest.fail "expected original typed failure"
    | Exit.Ok _ -> Alcotest.fail "expected failure");
    let span = only_span tracer in
    check_error_message "fallback status" "<error renderer raised>" span.status;
    match span.events with
    | [ event ] ->
        Alcotest.(check (option string))
          "fallback exception message" (Some "<error renderer raised>")
          (List.assoc_opt "exception.message" event.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one exception event, got %d"
          (List.length events)

  let test_observability_concurrent_status () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let eff =
      Effect.named "concurrent"
        (Effect.race [ Effect.fail "a"; Effect.fail "b" ])
    in
    ignore (B.run rt eff : (unit, string) Exit.t);
    let span = only_span tracer in
    check_status "concurrent" (Tracer.Error "") span.status

  let test_observability_par_children_inherit_parent () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let child name = Effect.named name (Effect.pure ()) in
    let eff = Effect.named "parent" (Effect.par (child "a") (child "b")) in
    ignore (run_ok rt eff);
    match Tracer.dump tracer with
    | [ a; b; parent ] ->
        Alcotest.(check (option int)) "a parent" (Some parent.span_id)
          a.parent_id;
        Alcotest.(check (option int)) "b parent" (Some parent.span_id)
          b.parent_id
    | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

  let test_observability_cancelled_parallel_child_status () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let slow =
      Effect.named "slow" (Effect.pure () |> Effect.delay (Duration.ms 10))
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; Effect.pure () ]) in
    wait_for_sleepers clock 1;
    check_exit_ok Alcotest.unit "race done" () (B.await promise);
    let slow_span =
      List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
    in
    check_status "slow cancelled" Tracer.Cancelled slow_span.status

  let test_observability_uninterruptible_parallel_child_status () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let slow =
      Effect.named "slow"
        (Effect.pure () |> Effect.delay (Duration.ms 10)
       |> Effect.uninterruptible)
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; Effect.pure () ]) in
    wait_for_sleepers clock 1;
    B.yield ();
    Alcotest.(check bool) "protected child still running" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 10);
    check_exit_ok Alcotest.unit "race done" () (B.await promise);
    let slow_span =
      List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
    in
    check_status "slow ok" Tracer.Ok slow_span.status

  let test_observability_par_pending_attrs_links_are_fiber_local () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let branch ~name ~delay ~attr_key ~link_span_id =
      Effect.pure ()
      |> Effect.named name
      |> Effect.delay (Duration.ms delay)
      |> Effect.link_span ~trace_id:("trace-" ^ name) ~span_id:link_span_id
      |> Effect.annotate ~key:attr_key ~value:"yes"
    in
    let promise =
      B.fork_run ctx rt
        (Effect.par
           (branch ~name:"left" ~delay:10 ~attr_key:"left"
              ~link_span_id:"left-link")
           (branch ~name:"right" ~delay:5 ~attr_key:"right"
              ~link_span_id:"right-link"))
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    B.yield ();
    B.adjust_clock clock (Duration.ms 5);
    check_exit_ok
      (Alcotest.pair Alcotest.unit Alcotest.unit)
      "par done" ((), ()) (B.await promise);
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
    B.with_sampled_traced_runtime Sampler.always_off @@ fun _ctx rt tracer ->
    run_ok rt (Effect.named "off" Effect.unit);
    Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

  let test_observability_sampler_ratio () =
    B.with_sampled_traced_runtime (Sampler.ratio 0.5) @@ fun _ctx rt tracer ->
    let spans =
      List.init 1_000 (fun i ->
          Effect.named ("span-" ^ string_of_int i) Effect.unit)
    in
    run_ok rt (Effect.concat spans);
    let count = List.length (Tracer.dump tracer) in
    Alcotest.(check bool) "roughly half sampled" true (count > 350 && count < 650)

  let test_observability_sampler_ratio_same_name_uses_trace_id () =
    B.with_seeded_sampled_traced_runtime ~seed:0x51a7 (Sampler.ratio 0.5)
    @@ fun _ctx rt tracer ->
    let spans = List.init 200 (fun _ -> Effect.named "same" Effect.unit) in
    run_ok rt (Effect.concat spans);
    let count = List.length (Tracer.dump tracer) in
    Alcotest.(check bool) "same-name roots mixed" true (count > 0 && count < 200)

  let test_observability_sampler_parent_based () =
    B.with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun _ctx rt tracer ->
    run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
    Alcotest.(check int) "parent and child sampled" 2
      (List.length (Tracer.dump tracer));
    B.with_sampled_traced_runtime
      (Sampler.parent_based ~root:Sampler.always_off ())
    @@ fun _ctx rt tracer ->
    run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
    Alcotest.(check int) "unsampled parent suppresses child" 0
      (List.length (Tracer.dump tracer))

  let test_observability_sampler_unsampled_parent_suppresses_par_children () =
    B.with_sampled_traced_runtime Sampler.always_off @@ fun _ctx rt tracer ->
    let child name = Effect.named name Effect.unit in
    ignore
      (run_ok rt (Effect.named "parent" (Effect.par (child "a") (child "b"))));
    Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

  let test_observability_noop_runtime_keeps_die_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let exn = Failure "noop diagnostic" in
    let eff =
      Effect.sync (fun () -> raise exn)
      |> Effect.annotate ~key:"request.id" ~value:"noop-1"
      |> Effect.named "noop.span"
    in
    match B.run rt eff with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check bool) "same exception" true (die.exn == exn);
        Alcotest.(check (option string)) "span name" (Some "noop.span")
          die.span_name;
        Alcotest.(check (option string)) "annotation" (Some "noop-1")
          (List.assoc_opt "request.id" die.annotations)
    | _ -> Alcotest.fail "expected Die with noop runtime diagnostics"

  let test_observability_annotate_all_die_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let exn = Failure "annotate_all diagnostic" in
    let eff =
      Effect.sync (fun () -> raise exn)
      |> Effect.annotate_all [ ("first", "1"); ("second", "2") ]
    in
    match B.run rt eff with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check bool) "same exception" true (die.exn == exn);
        Alcotest.(check (list (pair string string)))
          "annotation order" [ ("first", "1"); ("second", "2") ]
        die.annotations
    | _ -> Alcotest.fail "expected Die with annotate_all diagnostics"

  let test_observability_annotate_logs_propagates () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.log "request.started"
      |> Effect.annotate_logs [ ("request.id", "req-1") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check string) "body" "request.started" record.Logger.body;
    Alcotest.(check (option string)) "request id" (Some "req-1")
      (log_attr "request.id" record)

  let test_observability_annotate_logs_nested_composition () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.log "nested"
      |> Effect.annotate_logs [ ("inner", "yes") ]
      |> Effect.annotate_logs [ ("outer", "yes") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check (list (pair string string)))
      "attrs" [ ("outer", "yes"); ("inner", "yes") ] record.Logger.attrs

  let test_observability_annotate_logs_merges_per_call_attrs () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.log ~attrs:[ ("call", "yes") ] "merged"
      |> Effect.annotate_logs [ ("scope", "yes") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check (list (pair string string)))
      "attrs" [ ("scope", "yes"); ("call", "yes") ] record.Logger.attrs

  let test_observability_annotate_logs_is_fiber_local () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let branch name =
      Effect.yield
      |> Effect.bind (fun () -> Effect.log name)
      |> Effect.annotate_logs [ ("branch", name) ]
    in
    let program = Effect.par (branch "left") (branch "right") in
    ignore (run_ok rt program : unit * unit);
    let records = Logger.dump logger in
    Alcotest.(check int) "log count" 2 (List.length records);
    List.iter
      (fun record ->
        Alcotest.(check (option string))
          ("branch attr for " ^ record.Logger.body)
          (Some record.Logger.body)
          (log_attr "branch" record))
      records

  let test_observability_span_annotate_does_not_affect_logs () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger _meter ->
    let program =
      Effect.named "span"
        (Effect.log "inside"
        |> Effect.annotate ~key:"span.attr" ~value:"yes")
    in
    run_ok rt program;
    let span = only_span tracer in
    Alcotest.(check (option string)) "span attr" (Some "yes")
      (attr "span.attr" span);
    let record = only_log logger in
    Alcotest.(check (list (pair string string))) "log attrs" []
      record.Logger.attrs

  let test_observability_log_level_helpers () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let cases =
      [
        (Capabilities.Trace, Effect.log_trace ~attrs:[ ("case", "trace") ] "trace");
        (Capabilities.Debug, Effect.log_debug "debug");
        (Capabilities.Info, Effect.log_info "info");
        (Capabilities.Warn, Effect.log_warn "warn");
        (Capabilities.Error, Effect.log_error "error");
        (Capabilities.Fatal, Effect.log_fatal "fatal");
      ]
    in
    run_ok rt (Effect.concat (List.map snd cases));
    Alcotest.(check (list log_level))
      "levels" (List.map fst cases)
      (List.map (fun record -> record.Logger.level) (Logger.dump logger));
    match Logger.dump logger with
    | first :: _ ->
        Alcotest.(check (option string)) "helper attrs" (Some "trace")
          (log_attr "case" first)
    | [] -> Alcotest.fail "expected helper logs"

  let counting_noop_tracer count : Capabilities.tracer =
    object
      method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a =
        fun _ f -> f ()

      method begin_span _ ?parent_id:_ ?external_parent:_ ?trace_id:_
          ?trace_flags:_ ?trace_state:_ ?baggage:_ ?kind:_ ~name:_
          ~started_ms:_ () =
        incr count;
        -1

      method end_span _ ~span_id:_ ~status:_ ~ended_ms:_ = ()
      method add_attr _ ~key:_ ~value:_ = ()
      method add_attr_to _ ~span_id:_ ~key:_ ~value:_ = ()
      method add_event _ ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
      method add_link _ _ = ()
      method add_link_to _ ~span_id:_ _ = ()
      method inspect _ ~span_id:_ = None
    end

  let test_observability_custom_noop_tracer_is_explicitly_enabled () =
    let spans_started = ref 0 in
    B.with_custom_tracer_runtime (counting_noop_tracer spans_started)
    @@ fun _ctx rt ->
    check_exit_ok Alcotest.unit "named" ()
      (B.run rt (Effect.named "custom.noop" Effect.unit));
    Alcotest.(check int) "custom tracer enabled" 1 !spans_started

  let test_observability_suppress_observability () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger meter ->
    let hidden =
      Effect.concat
        [
          Effect.log "hidden log";
          Effect.metric_update ~name:"hidden.metric"
            ~kind:(Meter.Counter { monotonic = false })
            (Meter.Number (Meter.Int 1));
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

  let test_trace_context_extract_pair_scanner_edges () =
    let ctx =
      Trace_context.extract
        [
          ( " TraceParent ",
            " 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 " );
          ( "tracestate",
            " good = value , empty= , repeated=a=b , also = ok " );
          ("baggage", " tenant = acme ; ignored=param , broken=a=b , flag ");
        ]
    in
    match ctx with
    | None -> Alcotest.fail "expected trace context with edge pairs"
    | Some ctx ->
        Alcotest.(check (option string)) "tracestate good" (Some "value")
          (List.assoc_opt "good" ctx.trace_state);
        Alcotest.(check (option string)) "tracestate also" (Some "ok")
          (List.assoc_opt "also" ctx.trace_state);
        Alcotest.(check (option string)) "tracestate empty rejected" None
          (List.assoc_opt "empty" ctx.trace_state);
        Alcotest.(check (option string)) "tracestate repeated rejected" None
          (List.assoc_opt "repeated" ctx.trace_state);
        Alcotest.(check (option string)) "baggage parameter ignored" (Some "acme")
          (List.assoc_opt "tenant" ctx.baggage);
        Alcotest.(check (option string)) "baggage repeated rejected" None
          (List.assoc_opt "broken" ctx.baggage)

  let test_trace_context_extracts_higher_version_traceparent () =
    let ctx =
      Trace_context.extract
        [
          ( "traceparent",
            "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-09-extra" );
          ("tracestate", "congo=t61rcWkgMzE");
          ("baggage", "tenant=acme");
        ]
    in
    match ctx with
    | None -> Alcotest.fail "expected higher-version trace context"
    | Some ctx ->
        Alcotest.(check string) "trace_id"
          "4bf92f3577b34da6a3ce929d0e0e4736" ctx.trace_id;
        Alcotest.(check string) "span_id" "00f067aa0ba902b7" ctx.span_id;
        Alcotest.(check int) "trace_flags sampled bit" 1 ctx.trace_flags;
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
    let with_extra_field =
      Trace_context.extract
        [
          ( "traceparent",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra" );
        ]
    in
    let forbidden_version =
      Trace_context.extract
        [
          ( "traceparent",
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" );
        ]
    in
    Alcotest.(check bool) "all-zero trace rejected" true (Option.is_none bad);
    Alcotest.(check bool) "v00 extra field rejected" true
      (Option.is_none with_extra_field);
    Alcotest.(check bool) "ff version rejected" true
      (Option.is_none forbidden_version)

  let test_trace_context_current_and_par_inherit_baggage () =
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
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
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
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
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
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
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
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

  let test_in_memory_tracer_shared_state_is_locked_source () =
    let source_path =
      let candidates =
        [
          "lib/eta/tracer.ml";
          "../lib/eta/tracer.ml";
          "../../lib/eta/tracer.ml";
          "../../../lib/eta/tracer.ml";
          "../../../../lib/eta/tracer.ml";
        ]
      in
      match List.find_opt Sys.file_exists candidates with
      | Some path -> path
      | None -> Alcotest.failf "could not locate tracer.ml from %s" (Sys.getcwd ())
    in
    let source =
      let input = open_in_bin source_path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () -> really_input_string input (in_channel_length input))
    in
    let require needle =
      let rec search index =
        if index + String.length needle > String.length source then false
        else if String.sub source index (String.length needle) = needle then true
        else search (index + 1)
      in
      if not (search 0) then Alcotest.failf "missing source marker: %s" needle
    in
    require "mutex : Sync_lock.t";
    require "let with_lock t f =";
    require "Sync_lock.use t.mutex";
    require "t.next_id <- t.next_id + 1";
    require "with_lock t @@ fun () ->"

  let test_trace_context_unsampled_parent_suppresses_child () =
    B.with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun _ctx rt tracer ->
    let ctx =
      Option.get
        (Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
           ~span_id:"00f067aa0ba902b7" ~trace_flags:0 ())
    in
    run_ok rt (Effect.with_context ctx (Effect.named "child" Effect.unit));
    Alcotest.(check int) "unsampled parent suppresses child span" 0
      (List.length (Tracer.dump tracer))

  let test_observability_auto_instrument_default_off () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    run_ok rt (Effect.sync (fun () -> ()));
    Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

  let test_observability_auto_instrument_eval_leaves () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    let leaf name = Effect.named name (Effect.sync (fun () -> ())) in
    run_ok rt
      (Effect.concat [ leaf "a"; Effect.sync (fun () -> ()); leaf "b"; leaf "c" ]);
    Alcotest.(check (list string)) "leaf spans" [ "a"; "b"; "c" ]
      (List.map (fun span -> span.Tracer.name) (Tracer.dump tracer))

  let test_observability_auto_instrument_leaves_nest_under_named () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    let leaf name = Effect.named name (Effect.sync (fun () -> ())) in
    run_ok rt
      (Effect.named "outer" (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]));
    let spans = Tracer.dump tracer in
    let outer = List.find (fun span -> span.Tracer.name = "outer") spans in
    let children = List.filter (fun span -> span.Tracer.name <> "outer") spans in
    List.iter
      (fun span ->
        Alcotest.(check (option int)) span.Tracer.name (Some outer.span_id)
          span.parent_id)
      children

  let test_observability_auto_instrument_failure_status () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    ignore
      (B.run rt
         (Effect.named "boom" (Effect.sync (fun () -> failwith "boom"))) :
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
    B.with_traced_runtime @@ fun _ctx rt tracer ->
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

  let tests =
    [
      ( "Observability",
        [
          Alcotest.test_case "manual tracer spans" `Quick
            test_tracer_manual_spans;
          Alcotest.test_case "named span status ok" `Quick
            test_observability_named_ok;
          Alcotest.test_case "span kind" `Quick test_observability_span_kind;
          Alcotest.test_case "fn records location" `Quick test_observability_fn_loc;
          Alcotest.test_case "annotate_all and fn attrs" `Quick
            test_observability_annotate_all_and_fn_attrs;
          Alcotest.test_case "event records current span" `Quick
            test_observability_event_records_current_span;
          Alcotest.test_case "with_result_attrs" `Quick
            test_observability_with_result_attrs;
          Alcotest.test_case "annotation order" `Quick
            test_observability_annotation_order;
          Alcotest.test_case "statuses" `Quick test_observability_statuses;
          Alcotest.test_case "nested spans" `Quick test_observability_nested_spans;
          Alcotest.test_case "renderer exception preserves failure" `Quick
            test_observability_renderer_exception_preserves_failure;
          Alcotest.test_case "concurrent status" `Quick
            test_observability_concurrent_status;
          Alcotest.test_case "par children inherit parent" `Quick
            test_observability_par_children_inherit_parent;
          Alcotest.test_case "cancelled child status" `Quick
            test_observability_cancelled_parallel_child_status;
          Alcotest.test_case "uninterruptible child status" `Quick
            test_observability_uninterruptible_parallel_child_status;
          Alcotest.test_case "par pending attrs links are fiber-local" `Quick
            test_observability_par_pending_attrs_links_are_fiber_local;
          Alcotest.test_case "sampler always off" `Quick
            test_observability_sampler_always_off;
          Alcotest.test_case "sampler ratio" `Quick
            test_observability_sampler_ratio;
          Alcotest.test_case "sampler ratio same name uses trace id" `Quick
            test_observability_sampler_ratio_same_name_uses_trace_id;
          Alcotest.test_case "sampler parent based" `Quick
            test_observability_sampler_parent_based;
          Alcotest.test_case "sampler suppresses par children" `Quick
            test_observability_sampler_unsampled_parent_suppresses_par_children;
          Alcotest.test_case "noop runtime keeps die diagnostics" `Quick
            test_observability_noop_runtime_keeps_die_diagnostics;
          Alcotest.test_case "annotate_all die diagnostics" `Quick
            test_observability_annotate_all_die_diagnostics;
          Alcotest.test_case "annotate_logs propagates" `Quick
            test_observability_annotate_logs_propagates;
          Alcotest.test_case "annotate_logs nested composition" `Quick
            test_observability_annotate_logs_nested_composition;
          Alcotest.test_case "annotate_logs merges per-call attrs" `Quick
            test_observability_annotate_logs_merges_per_call_attrs;
          Alcotest.test_case "annotate_logs is fiber-local" `Quick
            test_observability_annotate_logs_is_fiber_local;
          Alcotest.test_case "span annotate does not affect logs" `Quick
            test_observability_span_annotate_does_not_affect_logs;
          Alcotest.test_case "log level helpers" `Quick
            test_observability_log_level_helpers;
          Alcotest.test_case "custom noop tracer is explicitly enabled" `Quick
            test_observability_custom_noop_tracer_is_explicitly_enabled;
          Alcotest.test_case "suppress observability" `Quick
            test_observability_suppress_observability;
          Alcotest.test_case "trace context extract inject" `Quick
            test_trace_context_extract_inject;
          Alcotest.test_case "trace context pair scanner edges" `Quick
            test_trace_context_extract_pair_scanner_edges;
          Alcotest.test_case "trace context higher version traceparent" `Quick
            test_trace_context_extracts_higher_version_traceparent;
          Alcotest.test_case "trace context rejects malformed traceparent" `Quick
            test_trace_context_rejects_malformed_traceparent;
          Alcotest.test_case "trace context par inherits baggage" `Quick
            test_trace_context_current_and_par_inherit_baggage;
          Alcotest.test_case "in-memory tracer current span has valid ids"
            `Quick test_in_memory_tracer_current_span_has_valid_ids;
          Alcotest.test_case "in-memory tracer child inherits trace id" `Quick
            test_in_memory_tracer_child_inherits_trace_id;
          Alcotest.test_case "in-memory tracer external trace id wins" `Quick
            test_in_memory_tracer_external_context_trace_id_wins;
          Alcotest.test_case "in-memory tracer shared state is locked" `Quick
            test_in_memory_tracer_shared_state_is_locked_source;
          Alcotest.test_case "trace context unsampled parent suppresses child"
            `Quick test_trace_context_unsampled_parent_suppresses_child;
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
    ]
end
