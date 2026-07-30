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

  let attr key span = List.assoc_opt key span.Eta_observability.Tracer.attrs

  let link_span_id span =
    List.map (fun link -> link.Eta_observability.Tracer.link_span_id) span.Eta_observability.Tracer.links

  let only_span tracer =
    match Eta_observability.Tracer.dump tracer with
    | [ span ] -> span
    | spans ->
        Alcotest.failf "expected one span, got %d" (List.length spans)

  let check_status name expected actual =
    match (expected, actual) with
    | Eta_observability.Tracer.Ok, Eta_observability.Tracer.Ok -> ()
    | Eta_observability.Tracer.Cancelled, Eta_observability.Tracer.Cancelled -> ()
    | Eta_observability.Tracer.Error _, Eta_observability.Tracer.Error _ -> ()
    | _ -> Alcotest.failf "%s: unexpected span status" name

  let check_error_message name expected actual =
    match actual with
    | Eta_observability.Tracer.Error msg -> Alcotest.(check string) name expected msg
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
    match Eta_observability.Logger.dump logger with
    | [ record ] -> record
    | records -> Alcotest.failf "expected one log, got %d" (List.length records)

  let log_attr key record = List.assoc_opt key record.Eta_observability.Logger.attrs
  let log_bodies logger = List.map (fun record -> record.Eta_observability.Logger.body) (Eta_observability.Logger.dump logger)

  type observability_err = [ `Boom | `Db of int | `Inner | `Outer ]

  let test_tracer_manual_spans () =
    B.with_runtime_contract @@ fun _ctx contract ->
    Eta_observability.Tracer.with_task_context contract @@ fun () ->
    let tracer = Eta_observability.Tracer.in_memory () in
    let t = Eta_observability.Tracer.as_capability tracer in
    t#add_attr contract ~key:"pending" ~value:"yes";
    let parent = t#begin_span contract ~name:"parent" ~started_ms:1 () in
    t#add_attr contract ~key:"inside" ~value:"parent";
    let child = t#begin_span contract ~name:"child" ~started_ms:2 () in
    t#end_span contract ~span_id:child ~status:Eta_observability.Tracer.Ok ~ended_ms:3;
    t#end_span contract ~span_id:parent ~status:(Eta_observability.Tracer.Error "boom")
      ~ended_ms:4;
    match Eta_observability.Tracer.dump tracer with
    | [ child_span; parent_span ] ->
        Alcotest.(check int) "child parent" parent
          (Option.get child_span.Eta_observability.Tracer.parent_id);
        Alcotest.(check (option string)) "pending attr" (Some "yes")
          (attr "pending" parent_span);
        Alcotest.(check (option string)) "inside attr" (Some "parent")
          (attr "inside" parent_span);
        check_status "child" Eta_observability.Tracer.Ok child_span.status;
        check_status "parent" (Eta_observability.Tracer.Error "boom") parent_span.status
    | spans -> Alcotest.failf "expected two spans, got %d" (List.length spans)

  let test_observability_named_ok () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let eff = Eta_observability.named "foo" (Effect.pure 1) in
    Alcotest.(check int) "value" 1 (run_ok rt eff);
    let span = only_span tracer in
    Alcotest.(check string) "name" "foo" span.name;
    check_status "status" Eta_observability.Tracer.Ok span.status

  let test_observability_span_kind () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    run_ok rt (Eta_observability.named ~kind:Capabilities.Server "server" Effect.unit);
    let span = only_span tracer in
    Alcotest.(check bool) "server kind" true (span.kind = Eta_observability.Tracer.Server)

  let test_observability_fn_loc () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let program = Eta_observability.fn __POS__ __FUNCTION__ (Effect.pure ()) in
    run_ok rt program;
    let span = only_span tracer in
    Alcotest.(check string) "name" __FUNCTION__ span.name;
    match attr "loc" span with
    | Some loc -> Alcotest.(check bool) "test file" true (String.contains loc '/')
    | None -> Alcotest.fail "missing loc attr"

  let test_observability_annotate_all_and_fn_attrs () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let program =
      Eta_observability.fn
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
      Eta_observability.named "ingest.assets"
        (Eta_observability.event ~attrs:[ ("batch", "1") ] "ingest.assets.progress")
    in
    run_ok rt program;
    let span = only_span tracer in
    match span.events with
    | [ event ] ->
        Alcotest.(check string) "event name" "ingest.assets.progress"
          event.Eta_observability.Tracer.ev_name;
        Alcotest.(check (option string)) "event attr" (Some "1")
          (List.assoc_opt "batch" event.Eta_observability.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one span event, got %d" (List.length events)

  let test_observability_with_result_attrs () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let observe eff =
      Eta_observability.with_result_attrs
        ~ok_attrs:(fun rows ->
          [ ("result", "ok"); ("row_count", string_of_int (List.length rows)) ])
        ~err_attrs:(fun (`Bad code) ->
          [ ("result", "error"); ("error.code", string_of_int code) ])
        eff
    in
    let ok_effect = Eta_observability.named "rows.ok" (observe (Effect.pure [ 1; 2; 3 ])) in
    let err_effect = Eta_observability.named "rows.err" (observe (Effect.fail (`Bad 7))) in
    Alcotest.(check (list int)) "ok value" [ 1; 2; 3 ] (run_ok rt ok_effect);
    ignore (B.run rt err_effect : (int list, [ `Bad of int ]) Exit.t);
    let spans = Eta_observability.Tracer.dump tracer in
    let find name = List.find (fun span -> String.equal span.Eta_observability.Tracer.name name) spans in
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
      Effect.pure () |> Eta_observability.annotate ~key:"k" ~value:"inside"
      |> Eta_observability.named "span"
    in
    let outside =
      Effect.pure () |> Eta_observability.named "span"
      |> Eta_observability.annotate ~key:"k" ~value:"outside"
    in
    Alcotest.(check (option string)) "inside" (Some "inside") (run inside);
    Alcotest.(check (option string)) "outside" (Some "outside") (run outside)

  let test_observability_statuses () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let fail_eff : (unit, observability_err) Effect.t =
      Eta_observability.named "fail" (Effect.fail `Boom)
    in
    ignore (B.run rt fail_eff : (unit, observability_err) Exit.t);
    let render_db : Format.formatter -> observability_err -> unit =
     fun fmt -> function
      | `Db code -> Format.fprintf fmt "db:%d" code
      | _ -> Format.pp_print_string fmt "<unexpected>"
    in
    let custom_eff : (unit, observability_err) Effect.t =
      Eta_observability.named ~error_pp:render_db "custom" (Effect.fail (`Db 42))
    in
    ignore (B.run rt custom_eff : (unit, observability_err) Exit.t);
    let inner = Eta_observability.named "inner" (Effect.fail `Inner) in
    let render_outer : Format.formatter -> observability_err -> unit =
     fun fmt -> function
      | `Outer -> Format.pp_print_string fmt "outer"
      | _ -> Format.pp_print_string fmt "<unexpected>"
    in
    let outer : (unit, observability_err) Effect.t =
      Eta_observability.named ~error_pp:render_outer "outer"
        (Effect.bind_error (function `Inner -> Effect.fail `Outer) inner)
    in
    ignore (B.run rt outer : (unit, observability_err) Exit.t);
    ignore
      (B.run rt
         (Eta_observability.named "die" (Effect.sync (fun () -> failwith "boom"))) :
        (unit, _) Exit.t);
    let spans = Eta_observability.Tracer.dump tracer in
    let find name = List.find (fun span -> span.Eta_observability.Tracer.name = name) spans in
    let fail_span = find "fail" in
    check_error_message "fail default" "<typed failure>" fail_span.status;
    (match fail_span.events with
    | [ event ] ->
        Alcotest.(check (option string))
          "fail exception message" (Some "<typed failure>")
          (List.assoc_opt "exception.message" event.Eta_observability.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one fail exception event, got %d"
          (List.length events));
    let custom_span = find "custom" in
    check_error_message "custom status" "db:42" custom_span.status;
    (match custom_span.events with
    | [ event ] ->
        Alcotest.(check (option string))
          "custom exception message" (Some "db:42")
          (List.assoc_opt "exception.message" event.Eta_observability.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one custom exception event, got %d"
          (List.length events));
    check_error_message "inner default" "<unexpected>" (find "inner").status;
    check_error_message "outer custom" "outer" (find "outer").status;
    check_status "die" (Eta_observability.Tracer.Error "") (find "die").status

  let test_observability_nested_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let eff =
      Eta_observability.named "outer"
        (Eta_observability.named "inner-a" (Effect.pure ())
        |> Effect.bind (fun () -> Eta_observability.named "inner-b" (Effect.pure ())))
    in
    run_ok rt eff;
    match Eta_observability.Tracer.dump tracer with
    | [ a; b; outer ] ->
        Alcotest.(check string) "outer" "outer" outer.name;
        Alcotest.(check (option int)) "a parent" (Some outer.span_id)
          a.parent_id;
        Alcotest.(check (option int)) "b parent" (Some outer.span_id)
          b.parent_id
    | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

  let test_observability_error_pp_raise_becomes_defect () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let render _fmt _ = failwith "renderer exploded" in
    let eff =
      Eta_observability.named ~error_pp:render "renderer-fails"
        (Effect.fail "original")
    in
    (match B.run rt eff with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check string)
          "defect message" "Failure(\"renderer exploded\")"
          (Printexc.to_string die.exn)
    | Exit.Error (Cause.Fail _) ->
        Alcotest.fail "expected defect from raising error_pp, not typed failure"
    | Exit.Error _ -> Alcotest.fail "expected die defect from raising error_pp"
    | Exit.Ok _ -> Alcotest.fail "expected failure");
    let span = only_span tracer in
    (* Span still closes; status comes from the defect, not a swallowed fallback. *)
    check_status "defect status" (Eta_observability.Tracer.Error "") span.status

  let test_observability_named_error_pp_domain_string () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let pp_err fmt = function
      | `Db_down -> Format.pp_print_string fmt "db.save: connection refused"
    in
    let eff =
      Eta_observability.named ~error_pp:pp_err "db.save" (Effect.fail `Db_down)
    in
    ignore (B.run rt eff : (unit, [ `Db_down ]) Exit.t);
    let span = only_span tracer in
    check_error_message "domain status" "db.save: connection refused" span.status;
    match span.events with
    | [ event ] ->
        Alcotest.(check (option string))
          "domain exception message"
          (Some "db.save: connection refused")
          (List.assoc_opt "exception.message" event.Eta_observability.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one exception event, got %d" (List.length events)

  let test_observability_error_pp_render_once () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let calls = ref 0 in
    let pp_err fmt err =
      incr calls;
      Format.pp_print_string fmt err
    in
    let eff =
      Eta_observability.named ~error_pp:pp_err "once" (Effect.fail "boom-once")
    in
    ignore (B.run rt eff : (unit, string) Exit.t);
    let span = only_span tracer in
    check_error_message "status" "boom-once" span.status;
    (match span.events with
    | [ event ] ->
        Alcotest.(check (option string))
          "exception message" (Some "boom-once")
          (List.assoc_opt "exception.message" event.Eta_observability.Tracer.ev_attrs)
    | events ->
        Alcotest.failf "expected one exception event, got %d" (List.length events));
    Alcotest.(check int) "render once" 1 !calls

  let test_observability_named_optional_omission_yields_effects () =
    (* Compile-time erasure probe: optional omission still yields Effect.t. *)
    let _omit : (unit, string) Effect.t =
      Eta_observability.named "x" (Effect.fail "e")
    in
    let _kind_only : (unit, string) Effect.t =
      Eta_observability.named ~kind:Capabilities.Client "x" (Effect.fail "e")
    in
    let pp fmt s = Format.pp_print_string fmt s in
    let _pp_only : (unit, string) Effect.t =
      Eta_observability.named ~error_pp:pp "x" (Effect.fail "e")
    in
    let _both : (unit, string) Effect.t =
      Eta_observability.named ~kind:Capabilities.Client ~error_pp:pp "x" (Effect.fail "e")
    in
    ()

  let test_observability_concurrent_status () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let eff =
      Eta_observability.named "concurrent"
        (Effect.race [ Effect.fail "a"; Effect.fail "b" ])
    in
    ignore (B.run rt eff : (unit, string) Exit.t);
    let span = only_span tracer in
    check_status "concurrent" (Eta_observability.Tracer.Error "") span.status

  let test_observability_par_children_inherit_parent () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let child name = Eta_observability.named name (Effect.pure ()) in
    let eff = Eta_observability.named "parent" (Effect.par (child "a") (child "b")) in
    ignore (run_ok rt eff);
    match Eta_observability.Tracer.dump tracer with
    | [ a; b; parent ] ->
        Alcotest.(check (option int)) "a parent" (Some parent.span_id)
          a.parent_id;
        Alcotest.(check (option int)) "b parent" (Some parent.span_id)
          b.parent_id
    | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

  let test_observability_cancelled_parallel_child_status () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let slow =
      Eta_observability.named "slow" (Effect.pure () |> Effect.delay (Duration.ms 10))
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; Effect.pure () ]) in
    wait_for_sleepers clock 1;
    check_exit_ok Alcotest.unit "race done" () (B.await promise);
    let slow_span =
      List.find (fun span -> span.Eta_observability.Tracer.name = "slow") (Eta_observability.Tracer.dump tracer)
    in
    check_status "slow cancelled" Eta_observability.Tracer.Cancelled slow_span.status

  let test_observability_uninterruptible_parallel_child_status () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let slow =
      Eta_observability.named "slow"
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
      List.find (fun span -> span.Eta_observability.Tracer.name = "slow") (Eta_observability.Tracer.dump tracer)
    in
    check_status "slow ok" Eta_observability.Tracer.Ok slow_span.status

  let test_observability_par_pending_attrs_links_are_fiber_local () =
    B.with_traced_test_clock @@ fun ctx clock rt tracer ->
    let branch ~name ~delay ~attr_key ~link_span_id =
      Effect.pure ()
      |> Eta_observability.named name
      |> Effect.delay (Duration.ms delay)
      |> Eta_observability.link_span ~trace_id:("trace-" ^ name) ~span_id:link_span_id
      |> Eta_observability.annotate ~key:attr_key ~value:"yes"
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
    let spans = Eta_observability.Tracer.dump tracer in
    let left = List.find (fun span -> span.Eta_observability.Tracer.name = "left") spans in
    let right = List.find (fun span -> span.Eta_observability.Tracer.name = "right") spans in
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
    run_ok rt (Eta_observability.named "off" Effect.unit);
    Alcotest.(check int) "no spans" 0 (List.length (Eta_observability.Tracer.dump tracer))

  let test_observability_sampler_ratio () =
    B.with_sampled_traced_runtime (Sampler.ratio 0.5) @@ fun _ctx rt tracer ->
    let spans =
      List.init 1_000 (fun i ->
          Eta_observability.named ("span-" ^ string_of_int i) Effect.unit)
    in
    run_ok rt (Effect.concat spans);
    let count = List.length (Eta_observability.Tracer.dump tracer) in
    Alcotest.(check bool) "roughly half sampled" true (count > 350 && count < 650)

  let test_observability_sampler_ratio_same_name_uses_trace_id () =
    B.with_seeded_sampled_traced_runtime ~seed:0x51a7 (Sampler.ratio 0.5)
    @@ fun _ctx rt tracer ->
    let spans = List.init 200 (fun _ -> Eta_observability.named "same" Effect.unit) in
    run_ok rt (Effect.concat spans);
    let count = List.length (Eta_observability.Tracer.dump tracer) in
    Alcotest.(check bool) "same-name roots mixed" true (count > 0 && count < 200)

  let test_observability_sampler_parent_based () =
    B.with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun _ctx rt tracer ->
    run_ok rt (Eta_observability.named "parent" (Eta_observability.named "child" Effect.unit));
    Alcotest.(check int) "parent and child sampled" 2
      (List.length (Eta_observability.Tracer.dump tracer));
    B.with_sampled_traced_runtime
      (Sampler.parent_based ~root:Sampler.always_off ())
    @@ fun _ctx rt tracer ->
    run_ok rt (Eta_observability.named "parent" (Eta_observability.named "child" Effect.unit));
    Alcotest.(check int) "unsampled parent suppresses child" 0
      (List.length (Eta_observability.Tracer.dump tracer))

  let test_observability_sampler_unsampled_parent_suppresses_par_children () =
    B.with_sampled_traced_runtime Sampler.always_off @@ fun _ctx rt tracer ->
    let child name = Eta_observability.named name Effect.unit in
    ignore
      (run_ok rt (Eta_observability.named "parent" (Effect.par (child "a") (child "b"))));
    Alcotest.(check int) "no spans" 0 (List.length (Eta_observability.Tracer.dump tracer))

  let test_observability_noop_runtime_keeps_die_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let exn = Failure "noop diagnostic" in
    let eff =
      Effect.sync (fun () -> raise exn)
      |> Eta_observability.annotate ~key:"request.id" ~value:"noop-1"
      |> Eta_observability.named "noop.span"
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
      |> Eta_observability.annotate_all [ ("first", "1"); ("second", "2") ]
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
      Eta_observability.log "request.started"
      |> Eta_observability.annotate_logs [ ("request.id", "req-1") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check string) "body" "request.started" record.Eta_observability.Logger.body;
    Alcotest.(check (option string)) "request id" (Some "req-1")
      (log_attr "request.id" record)

  let test_observability_annotate_logs_nested_composition () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Eta_observability.log "nested"
      |> Eta_observability.annotate_logs [ ("inner", "yes") ]
      |> Eta_observability.annotate_logs [ ("outer", "yes") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check (list (pair string string)))
      "attrs" [ ("outer", "yes"); ("inner", "yes") ] record.Eta_observability.Logger.attrs

  let test_observability_annotate_logs_merges_per_call_attrs () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Eta_observability.log ~attrs:[ ("call", "yes") ] "merged"
      |> Eta_observability.annotate_logs [ ("scope", "yes") ]
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check (list (pair string string)))
      "attrs" [ ("scope", "yes"); ("call", "yes") ] record.Eta_observability.Logger.attrs

  let test_observability_annotate_logs_is_fiber_local () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let branch name =
      Effect.yield
      |> Effect.bind (fun () -> Eta_observability.log name)
      |> Eta_observability.annotate_logs [ ("branch", name) ]
    in
    let program = Effect.par (branch "left") (branch "right") in
    ignore (run_ok rt program : unit * unit);
    let records = Eta_observability.Logger.dump logger in
    Alcotest.(check int) "log count" 2 (List.length records);
    List.iter
      (fun record ->
        Alcotest.(check (option string))
          ("branch attr for " ^ record.Eta_observability.Logger.body)
          (Some record.Eta_observability.Logger.body)
          (log_attr "branch" record))
      records

  let test_observability_span_annotate_does_not_affect_logs () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger _meter ->
    let program =
      Eta_observability.named "span"
        (Eta_observability.log "inside"
        |> Eta_observability.annotate ~key:"span.attr" ~value:"yes")
    in
    run_ok rt program;
    let span = only_span tracer in
    Alcotest.(check (option string)) "span attr" (Some "yes")
      (attr "span.attr" span);
    let record = only_log logger in
    Alcotest.(check (list (pair string string))) "log attrs" []
      record.Eta_observability.Logger.attrs

  let test_observability_log_level_helpers () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let cases =
      [
        (Capabilities.Trace, Eta_observability.log_trace ~attrs:[ ("case", "trace") ] "trace");
        (Capabilities.Debug, Eta_observability.log_debug "debug");
        (Capabilities.Info, Eta_observability.log_info "info");
        (Capabilities.Warn, Eta_observability.log_warn "warn");
        (Capabilities.Error, Eta_observability.log_error "error");
        (Capabilities.Fatal, Eta_observability.log_fatal "fatal");
      ]
    in
    run_ok rt (Effect.concat (List.map snd cases));
    Alcotest.(check (list log_level))
      "levels" (List.map fst cases)
      (List.map (fun record -> record.Eta_observability.Logger.level) (Eta_observability.Logger.dump logger));
    match Eta_observability.Logger.dump logger with
    | first :: _ ->
        Alcotest.(check (option string)) "helper attrs" (Some "trace")
          (log_attr "case" first)
    | [] -> Alcotest.fail "expected helper logs"

  let test_logf_disabled_does_not_invoke_builtin_user_or_thunk_formatters () =
    let builtin_calls = ref 0 in
    let user_calls = ref 0 in
    let thunk_calls = ref 0 in
    let intercept_calls = ref 0 in
    let builtin fmt =
      incr builtin_calls;
      Format.fprintf fmt "builtin %d" 7
    in
    let print_user fmt value =
      incr user_calls;
      Format.pp_print_int fmt value
    in
    let user fmt = Format.fprintf fmt "user %a" print_user 8 in
    let print_thunk fmt =
      incr thunk_calls;
      Format.pp_print_string fmt "thunk"
    in
    let thunk fmt = Format.fprintf fmt "value %t" print_thunk in
    let program =
      Effect.concat
        (List.map
           (Eta_observability.logf ~level:Capabilities.Debug)
           [ builtin; user; thunk ])
    in
    (B.with_runtime @@ fun _ctx rt -> run_ok rt program);
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let observe _record =
      incr intercept_calls;
      Eta_observability.Keep
    in
    run_ok rt
      (program |> Eta_observability.intercept_log observe
      |> Eta_observability.with_minimum_log_level Capabilities.Warn);
    Alcotest.(check int) "builtin calls" 0 !builtin_calls;
    Alcotest.(check int) "user printer calls" 0 !user_calls;
    Alcotest.(check int) "thunk printer calls" 0 !thunk_calls;
    Alcotest.(check int) "intercept calls" 0 !intercept_calls;
    Alcotest.(check int) "sink calls" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_logf_enabled_invokes_builtin_user_and_thunk_exactly_once () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let builtin_calls = ref 0 in
    let user_calls = ref 0 in
    let thunk_calls = ref 0 in
    let builtin fmt =
      incr builtin_calls;
      Format.fprintf fmt "builtin %d" 7
    in
    let print_user fmt value =
      incr user_calls;
      Format.pp_print_int fmt value
    in
    let user fmt = Format.fprintf fmt "user %a" print_user 8 in
    let print_thunk fmt =
      incr thunk_calls;
      Format.pp_print_string fmt "thunk"
    in
    let thunk fmt = Format.fprintf fmt "value %t" print_thunk in
    run_ok rt (Effect.concat (List.map Eta_observability.logf [ builtin; user; thunk ]));
    Alcotest.(check int) "builtin calls" 1 !builtin_calls;
    Alcotest.(check int) "user printer calls" 1 !user_calls;
    Alcotest.(check int) "thunk printer calls" 1 !thunk_calls;
    Alcotest.(check (list string))
      "bodies" [ "builtin 7"; "user 8"; "value thunk" ] (log_bodies logger)

  let test_logf_disabled_defers_million_width_builtin_conversion () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let formatter_calls = ref 0 in
    let print fmt =
      incr formatter_calls;
      Format.fprintf fmt "%1000000d" 1
    in
    run_ok rt
      (Eta_observability.logf ~level:Capabilities.Debug print
      |> Eta_observability.with_minimum_log_level Capabilities.Warn);
    Alcotest.(check int) "formatter calls" 0 !formatter_calls;
    Alcotest.(check int) "sink calls" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_logf_composes_attrs_and_intercepts () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let formatter_calls = ref 0 in
    let transform (record : Capabilities.log_record) =
      Alcotest.(check (list (pair string string)))
        "attrs before intercept"
        [ ("request.id", "req-1"); ("table", "users") ]
        record.attrs;
      Eta_observability.Replace { record with body = record.body ^ "!" }
    in
    let program =
      Eta_observability.logf ~attrs:[ ("table", "users") ] (fun fmt ->
          incr formatter_calls;
          Format.fprintf fmt "retry %d" 3)
      |> Eta_observability.annotate_logs [ ("request.id", "req-1") ]
      |> Eta_observability.intercept_log transform
    in
    run_ok rt program;
    Alcotest.(check int) "formatter calls" 1 !formatter_calls;
    Alcotest.(check string) "transformed body" "retry 3!"
      (only_log logger).Eta_observability.Logger.body

  let test_logf_drop_occurs_after_formatting () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let formatter_calls = ref 0 in
    let print fmt =
      incr formatter_calls;
      Format.fprintf fmt "secret %d" 1
    in
    let program =
      Eta_observability.logf print
      |> Eta_observability.intercept_log (fun _record -> Eta_observability.Drop)
    in
    run_ok rt program;
    Alcotest.(check int) "formatter calls" 1 !formatter_calls;
    Alcotest.(check int) "sink calls" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_logf_raising_printer_becomes_defect () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let exn = Failure "logf printer failed" in
    let print _fmt () = raise exn in
    let write fmt = Format.fprintf fmt "broken %a" print () in
    (match B.run rt (Eta_observability.logf write) with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check bool) "same exception" true (die.exn == exn)
    | _ -> Alcotest.fail "expected printer exception to become Die");
    Alcotest.(check int) "sink calls" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_logf_work_inside_formatter_is_deferred () =
    let inside_calls = ref 0 in
    let outside_calls = ref 0 in
    let outside () =
      incr outside_calls;
      7
    in
    let value = outside () in
    let emit =
      Eta_observability.logf (fun fmt ->
          incr inside_calls;
          Format.fprintf fmt "len %d" value)
    in
    Alcotest.(check int) "outside before run" 1 !outside_calls;
    Alcotest.(check int) "inside before run" 0 !inside_calls;
    (B.with_runtime @@ fun _ctx rt -> run_ok rt emit);
    Alcotest.(check int) "inside after disabled run" 0 !inside_calls;
    B.with_logger_runtime @@ fun _ctx rt logger ->
    run_ok rt emit;
    Alcotest.(check int) "inside after enabled run" 1 !inside_calls;
    Alcotest.(check string) "body" "len 7" (only_log logger).Eta_observability.Logger.body

  let test_logf_blueprint_retains_formatter_captures () =
    let make () =
      let captured = ref 7 in
      let weak = Weak.create 1 in
      Weak.set weak 0 (Some captured);
      let emit = Eta_observability.logf (fun fmt -> Format.fprintf fmt "%d" !captured) in
      (emit, weak)
    in
    let emit, weak = make () in
    Gc.full_major ();
    Alcotest.(check bool) "capture retained" true
      (Option.is_some (Weak.get weak 0));
    B.with_runtime @@ fun _ctx rt -> run_ok rt emit

  let test_observability_minimum_log_level_drops_lower () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.concat
        [
          Eta_observability.log ~level:Capabilities.Trace "trace";
          Eta_observability.log ~level:Capabilities.Debug "debug";
          Eta_observability.log ~level:Capabilities.Info "info";
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Warn
    in
    run_ok rt program;
    Alcotest.(check (list string)) "logs" [] (log_bodies logger)

  let test_observability_minimum_log_level_allows_equal_and_higher () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.concat
        [
          Eta_observability.log ~level:Capabilities.Warn "warn";
          Eta_observability.log ~level:Capabilities.Error "error";
          Eta_observability.log ~level:Capabilities.Fatal "fatal";
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Warn
    in
    run_ok rt program;
    Alcotest.(check (list string))
      "logs" [ "warn"; "error"; "fatal" ] (log_bodies logger)

  let test_observability_minimum_log_level_nested_composition () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let inner_strict =
      Effect.concat
        [
          Eta_observability.log ~level:Capabilities.Info "inner-info";
          Eta_observability.log ~level:Capabilities.Error "inner-error";
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Error
    in
    let inner_loose =
      Effect.concat
        [
          Eta_observability.log ~level:Capabilities.Trace "loose-trace";
          Eta_observability.log ~level:Capabilities.Debug "loose-debug";
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Trace
    in
    let program =
      Effect.concat
        [
          Eta_observability.log ~level:Capabilities.Debug "outer-debug";
          inner_strict;
          inner_loose;
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Debug
    in
    run_ok rt program;
    Alcotest.(check (list string))
      "logs" [ "outer-debug"; "inner-error"; "loose-debug" ]
      (log_bodies logger)

  let test_observability_minimum_log_level_is_fiber_local () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let left =
      Effect.yield
      |> Effect.bind (fun () ->
             Effect.concat [ Eta_observability.log_debug "left-debug"; Eta_observability.log_error "left-error" ])
      |> Eta_observability.with_minimum_log_level Capabilities.Error
    in
    let right =
      Effect.yield |> Effect.bind (fun () -> Eta_observability.log_debug "right-debug")
    in
    ignore (run_ok rt (Effect.par left right) : unit * unit);
    let bodies = log_bodies logger in
    Alcotest.(check int) "log count" 2 (List.length bodies);
    Alcotest.(check bool) "left error emitted" true
      (List.mem "left-error" bodies);
    Alcotest.(check bool) "right debug emitted" true
      (List.mem "right-debug" bodies);
    Alcotest.(check bool) "left debug dropped" false
      (List.mem "left-debug" bodies)

  let test_observability_log_level_helpers_respect_minimum () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.concat
        [
          Eta_observability.log_warn "warn";
          Eta_observability.log_error "error";
          Eta_observability.log_fatal "fatal";
        ]
      |> Eta_observability.with_minimum_log_level Capabilities.Error
    in
    run_ok rt program;
    Alcotest.(check (list string)) "logs" [ "error"; "fatal" ]
      (log_bodies logger)

  let test_observability_annotate_logs_with_minimum_log_level () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let program =
      Effect.concat [ Eta_observability.log_debug "dropped"; Eta_observability.log_warn "allowed" ]
      |> Eta_observability.annotate_logs [ ("request.id", "req-1") ]
      |> Eta_observability.with_minimum_log_level Capabilities.Warn
    in
    run_ok rt program;
    let record = only_log logger in
    Alcotest.(check string) "body" "allowed" record.Eta_observability.Logger.body;
    Alcotest.(check (option string)) "request id" (Some "req-1")
      (log_attr "request.id" record)

  let test_observability_intercept_log_order_and_redaction () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let calls = ref [] in
    let outer (record : Capabilities.log_record) =
      calls := !calls @ [ "outer" ];
      Alcotest.(check (option string)) "scoped attr visible" (Some "req-1")
        (List.assoc_opt "request.id" record.attrs);
      let attrs =
        List.map
          (fun (key, value) ->
            if String.equal key "password" then (key, "[redacted]")
            else (key, value))
          record.attrs
      in
      Eta_observability.Replace { record with attrs }
    in
    let inner (record : Capabilities.log_record) =
      calls := !calls @ [ "inner" ];
      Alcotest.(check (option string)) "inner sees outer transform"
        (Some "[redacted]")
        (List.assoc_opt "password" record.attrs);
      Eta_observability.Keep
    in
    let program =
      Eta_observability.log ~attrs:[ ("password", "open-sesame") ] "login"
      |> Eta_observability.annotate_logs [ ("request.id", "req-1") ]
      |> Eta_observability.intercept_log inner
      |> Eta_observability.intercept_log outer
    in
    run_ok rt program;
    Alcotest.(check (list string)) "outermost first" [ "outer"; "inner" ]
      !calls;
    Alcotest.(check (option string)) "sink sees redaction" (Some "[redacted]")
      (log_attr "password" (only_log logger))

  let test_observability_intercept_log_drop_short_circuits () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let calls = ref [] in
    let drop (_ : Capabilities.log_record) =
      calls := !calls @ [ "drop" ];
      Eta_observability.Drop
    in
    let later record =
      calls := !calls @ [ "later" ];
      Eta_observability.Keep
    in
    let program =
      Eta_observability.log "secret"
      |> Eta_observability.intercept_log later
      |> Eta_observability.intercept_log drop
    in
    run_ok rt program;
    Alcotest.(check (list string)) "short-circuit" [ "drop" ] !calls;
    Alcotest.(check int) "sink not called" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_observability_intercept_log_runs_after_filter () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let calls = ref 0 in
    let observe record =
      incr calls;
      Eta_observability.Keep
    in
    let program =
      Eta_observability.log_debug "filtered"
      |> Eta_observability.intercept_log observe
      |> Eta_observability.with_minimum_log_level Capabilities.Warn
    in
    run_ok rt program;
    Alcotest.(check int) "intercept not called" 0 !calls;
    Alcotest.(check int) "sink not called" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_observability_intercept_log_is_fiber_local () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let redact (record : Capabilities.log_record) =
      Eta_observability.Replace { record with body = "redacted" }
    in
    let left = Eta_observability.intercept_log redact (Eta_observability.log "left") in
    let right = Effect.yield |> Effect.bind (fun () -> Eta_observability.log "right") in
    ignore (run_ok rt (Effect.par left right) : unit * unit);
    let bodies = log_bodies logger in
    Alcotest.(check bool) "left transformed" true (List.mem "redacted" bodies);
    Alcotest.(check bool) "sibling unchanged" true (List.mem "right" bodies)

  let test_observability_intercept_log_with_logger_both_orders () =
    B.with_logger_runtime @@ fun _ctx rt base_logger ->
    let inside_logger = Eta_observability.Logger.in_memory () in
    let outside_logger = Eta_observability.Logger.in_memory () in
    let scrub (record : Capabilities.log_record) =
      Eta_observability.Replace { record with body = "[redacted]" }
    in
    let sink logger = Eta_observability.Logger.as_capability logger in
    let logger_inside =
      Eta_observability.intercept_log scrub
        (Eta_observability.with_logger (sink inside_logger) (Eta_observability.log "secret-1"))
    in
    let logger_outside =
      Eta_observability.with_logger (sink outside_logger)
        (Eta_observability.intercept_log scrub (Eta_observability.log "secret-2"))
    in
    run_ok rt (Effect.concat [ logger_inside; logger_outside ]);
    Alcotest.(check string) "logger inside" "[redacted]"
      (only_log inside_logger).Eta_observability.Logger.body;
    Alcotest.(check string) "logger outside" "[redacted]"
      (only_log outside_logger).Eta_observability.Logger.body;
    Alcotest.(check int) "base bypassed" 0
      (List.length (Eta_observability.Logger.dump base_logger))

  let test_observability_intercept_log_raise_becomes_defect () =
    B.with_logger_runtime @@ fun _ctx rt logger ->
    let exn = Failure "intercept failed" in
    let program =
      Eta_observability.intercept_log (fun _ -> raise exn) (Eta_observability.log "not emitted")
    in
    (match B.run rt program with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check bool) "same exception" true (die.exn == exn)
    | _ -> Alcotest.fail "expected intercept exception to become Die");
    Alcotest.(check int) "sink not called" 0 (List.length (Eta_observability.Logger.dump logger))

  let test_observability_intercept_metric_enriches_subtree () =
    B.with_observed_runtime @@ fun _ctx rt _tracer _logger meter ->
    let enrich (point : Capabilities.metric_point) =
      Eta_observability.Replace { point with attrs = point.attrs @ [ ("tenant", "acme") ] }
    in
    let program =
      Eta_observability.metric_counter ~name:"requests" ~monotonic:true
        (Capabilities.Int 1)
      |> Eta_observability.intercept_metric enrich
    in
    run_ok rt program;
    match Eta_observability.Meter.dump meter with
    | [ point ] ->
        Alcotest.(check (option string)) "tenant" (Some "acme")
          (List.assoc_opt "tenant" point.attrs)
    | points -> Alcotest.failf "expected one metric, got %d" (List.length points)

  let test_observability_intercept_metric_drop_short_circuits () =
    B.with_observed_runtime @@ fun _ctx rt _tracer _logger meter ->
    let calls = ref [] in
    let drop (_ : Capabilities.metric_point) =
      calls := !calls @ [ "drop" ];
      Eta_observability.Drop
    in
    let later point =
      calls := !calls @ [ "later" ];
      Eta_observability.Keep
    in
    let program =
      Eta_observability.metric_gauge ~name:"queue.depth" (Capabilities.Int 3)
      |> Eta_observability.intercept_metric later
      |> Eta_observability.intercept_metric drop
    in
    run_ok rt program;
    Alcotest.(check (list string)) "short-circuit" [ "drop" ] !calls;
    Alcotest.(check int) "meter not called" 0 (List.length (Eta_observability.Meter.dump meter))

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
      (B.run rt (Eta_observability.named "custom.noop" Effect.unit));
    Alcotest.(check int) "custom tracer enabled" 1 !spans_started

  let empty_id_tracer : Capabilities.tracer =
    object
      method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a =
        fun _ f -> f ()

      method begin_span _ ?parent_id:_ ?external_parent:_ ?trace_id:_
          ?trace_flags:_ ?trace_state:_ ?baggage:_ ?kind:_ ~name:_
          ~started_ms:_ () =
        1

      method end_span _ ~span_id:_ ~status:_ ~ended_ms:_ = ()
      method add_attr _ ~key:_ ~value:_ = ()
      method add_attr_to _ ~span_id:_ ~key:_ ~value:_ = ()
      method add_event _ ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
      method add_link _ _ = ()
      method add_link_to _ ~span_id:_ _ = ()

      method inspect _ ~span_id:_ =
        Some
          {
            Capabilities.trace_id = "";
            span_id = "";
            name = "untracked";
            trace_flags = 1;
            trace_state = [];
            baggage = [];
          }
    end

  let test_scoped_tracer_empty_ids_use_ambient_parent () =
    B.with_custom_tracer_runtime empty_id_tracer @@ fun _ctx rt ->
    let inner = Eta_observability.Tracer.in_memory () in
    let program =
      Eta_observability.named "outer"
        (Eta_observability.with_tracer (Eta_observability.Tracer.as_capability inner)
           (Eta_observability.named "inner" Effect.unit))
    in
    run_ok rt program;
    let span = only_span inner in
    Alcotest.(check bool)
      "untracked outer span does not manufacture external parent" true
      (Option.is_none span.external_parent)

  let test_observability_suppress_observability () =
    B.with_observed_runtime @@ fun _ctx rt tracer logger meter ->
    let hidden =
      Effect.concat
        [
          Eta_observability.log "hidden log";
          Eta_observability.metric_update ~name:"hidden.metric"
            ~kind:(Eta_observability.Meter.Counter { monotonic = false })
            (Eta_observability.Meter.Number (Eta_observability.Meter.Int 1));
        ]
      |> Eta_observability.named "hidden span"
      |> Eta_observability.suppress_observability
    in
    run_ok rt hidden;
    Alcotest.(check int) "spans" 0 (List.length (Eta_observability.Tracer.dump tracer));
    Alcotest.(check int) "logs" 0 (List.length (Eta_observability.Logger.dump logger));
    Alcotest.(check int) "metrics" 0 (List.length (Eta_observability.Meter.dump meter))

  let test_trace_context_extract_inject () =
    let ctx =
      Eta_observability.Trace_context.extract
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
          (List.assoc_opt "traceparent" (Eta_observability.Trace_context.inject ctx))

  let test_trace_context_extract_pair_scanner_edges () =
    let ctx =
      Eta_observability.Trace_context.extract
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
      Eta_observability.Trace_context.extract
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
          (List.assoc_opt "traceparent" (Eta_observability.Trace_context.inject ctx))

  let test_trace_context_rejects_malformed_traceparent () =
    let bad =
      Eta_observability.Trace_context.extract
        [
          ( "traceparent",
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01" );
        ]
    in
    let with_extra_field =
      Eta_observability.Trace_context.extract
        [
          ( "traceparent",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra" );
        ]
    in
    let forbidden_version =
      Eta_observability.Trace_context.extract
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
        (Eta_observability.Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
           ~span_id:"00f067aa0ba902b7" ~trace_state:[ ("rojo", "1") ]
           ~baggage:[ ("tenant", "acme") ] ())
    in
    let left = Eta_observability.current_context in
    let right = Eta_observability.current_context in
    let a, b = run_ok rt (Eta_observability.with_context ctx (Effect.par left right)) in
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
      run_ok rt (Eta_observability.named "root" Eta_observability.current_span)
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
        (Eta_observability.named "parent"
           (Effect.bind
              (fun parent ->
                Eta_observability.named "child"
                  (Effect.map
                     (fun child ->
                       (require_current_span parent, require_current_span child))
                     Eta_observability.current_span))
              Eta_observability.current_span))
    in
    Alcotest.(check string) "child trace_id" parent.trace_id child.trace_id;
    Alcotest.(check bool) "distinct span_id" true
      (not (String.equal parent.span_id child.span_id))

  let test_in_memory_tracer_external_context_trace_id_wins () =
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
    let ctx =
      Option.get
        (Eta_observability.Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
           ~span_id:"00f067aa0ba902b7" ())
    in
    let info =
      run_ok rt
        (Eta_observability.with_context ctx (Eta_observability.named "external" Eta_observability.current_span))
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
          "lib/observability/tracer.ml";
          "../lib/observability/tracer.ml";
          "../../lib/observability/tracer.ml";
          "../../../lib/observability/tracer.ml";
          "../../../../lib/observability/tracer.ml";
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
        (Eta_observability.Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
           ~span_id:"00f067aa0ba902b7" ~trace_flags:0 ())
    in
    run_ok rt (Eta_observability.with_context ctx (Eta_observability.named "child" Effect.unit));
    Alcotest.(check int) "unsampled parent suppresses child span" 0
      (List.length (Eta_observability.Tracer.dump tracer))

  let test_observability_auto_instrument_default_off () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    run_ok rt (Effect.sync (fun () -> ()));
    Alcotest.(check int) "no spans" 0 (List.length (Eta_observability.Tracer.dump tracer))

  let test_observability_auto_instrument_eval_leaves () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    let leaf name = Eta_observability.named name (Effect.sync (fun () -> ())) in
    run_ok rt
      (Effect.concat [ leaf "a"; Effect.sync (fun () -> ()); leaf "b"; leaf "c" ]);
    Alcotest.(check (list string)) "leaf spans" [ "a"; "b"; "c" ]
      (List.map (fun span -> span.Eta_observability.Tracer.name) (Eta_observability.Tracer.dump tracer))

  let test_observability_auto_instrument_leaves_nest_under_named () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    let leaf name = Eta_observability.named name (Effect.sync (fun () -> ())) in
    run_ok rt
      (Eta_observability.named "outer" (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]));
    let spans = Eta_observability.Tracer.dump tracer in
    let outer = List.find (fun span -> span.Eta_observability.Tracer.name = "outer") spans in
    let children = List.filter (fun span -> span.Eta_observability.Tracer.name <> "outer") spans in
    List.iter
      (fun span ->
        Alcotest.(check (option int)) span.Eta_observability.Tracer.name (Some outer.span_id)
          span.parent_id)
      children

  let test_observability_auto_instrument_failure_status () =
    B.with_auto_traced_runtime true @@ fun _ctx rt tracer ->
    ignore
      (B.run rt
         (Eta_observability.named "boom" (Effect.sync (fun () -> failwith "boom"))) :
        (unit, _) Exit.t);
    let span = only_span tracer in
    check_status "leaf failed" (Eta_observability.Tracer.Error "") span.status;
    match span.events with
    | [ event ] ->
        Alcotest.(check (option string)) "leaf cause path" (Some "cause")
          (List.assoc_opt "eta.cause.path" event.Eta_observability.Tracer.ev_attrs);
        Alcotest.(check bool) "leaf stacktrace" true
          (Option.is_some
             (List.assoc_opt "exception.stacktrace" event.Eta_observability.Tracer.ev_attrs))
    | events ->
        Alcotest.failf "expected one exception event, got %d" (List.length events)

  let test_observability_all_for_each_supervisor_inherit_parent () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let child name = Eta_observability.named name (Effect.pure ()) in
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
      Eta_observability.named "parent"
        (Effect.all [ child "all-a"; child "all-b" ]
        |> Effect.bind (fun _ ->
               Effect.map_par child [ "each-a"; "each-b" ])
        |> Effect.bind (fun _ -> supervised))
    in
    run_ok rt eff;
    let spans = Eta_observability.Tracer.dump tracer in
    let parent = List.find (fun span -> span.Eta_observability.Tracer.name = "parent") spans in
    let children = List.filter (fun span -> span.Eta_observability.Tracer.name <> "parent") spans in
    List.iter
      (fun span ->
        Alcotest.(check (option int)) span.Eta_observability.Tracer.name (Some parent.span_id)
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
          Alcotest.test_case "error_pp raise becomes defect" `Quick
            test_observability_error_pp_raise_becomes_defect;
          Alcotest.test_case "named error_pp domain string" `Quick
            test_observability_named_error_pp_domain_string;
          Alcotest.test_case "error_pp render once" `Quick
            test_observability_error_pp_render_once;
          Alcotest.test_case "named optional omission yields effects" `Quick
            test_observability_named_optional_omission_yields_effects;
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
          Alcotest.test_case
            "logf disabled does not invoke builtin user or thunk formatters"
            `Quick
            test_logf_disabled_does_not_invoke_builtin_user_or_thunk_formatters;
          Alcotest.test_case
            "logf enabled invokes builtin user and thunk exactly once" `Quick
            test_logf_enabled_invokes_builtin_user_and_thunk_exactly_once;
          Alcotest.test_case
            "logf disabled defers million-width builtin conversion" `Quick
            test_logf_disabled_defers_million_width_builtin_conversion;
          Alcotest.test_case "logf composes attrs and intercepts" `Quick
            test_logf_composes_attrs_and_intercepts;
          Alcotest.test_case "logf Drop occurs after formatting" `Quick
            test_logf_drop_occurs_after_formatting;
          Alcotest.test_case "logf raising printer becomes defect" `Quick
            test_logf_raising_printer_becomes_defect;
          Alcotest.test_case "logf work inside formatter is deferred" `Quick
            test_logf_work_inside_formatter_is_deferred;
          Alcotest.test_case "logf blueprint retains formatter captures" `Quick
            test_logf_blueprint_retains_formatter_captures;
          Alcotest.test_case "minimum log level drops lower records" `Quick
            test_observability_minimum_log_level_drops_lower;
          Alcotest.test_case "minimum log level allows equal and higher" `Quick
            test_observability_minimum_log_level_allows_equal_and_higher;
          Alcotest.test_case "minimum log level nested composition" `Quick
            test_observability_minimum_log_level_nested_composition;
          Alcotest.test_case "minimum log level is fiber-local" `Quick
            test_observability_minimum_log_level_is_fiber_local;
          Alcotest.test_case "log level helpers respect minimum" `Quick
            test_observability_log_level_helpers_respect_minimum;
          Alcotest.test_case "annotate_logs with minimum log level" `Quick
            test_observability_annotate_logs_with_minimum_log_level;
          Alcotest.test_case "intercept_log order and redaction" `Quick
            test_observability_intercept_log_order_and_redaction;
          Alcotest.test_case "intercept_log drop short-circuits" `Quick
            test_observability_intercept_log_drop_short_circuits;
          Alcotest.test_case "intercept_log runs after filter" `Quick
            test_observability_intercept_log_runs_after_filter;
          Alcotest.test_case "intercept_log is fiber-local" `Quick
            test_observability_intercept_log_is_fiber_local;
          Alcotest.test_case "intercept_log with_logger both orders" `Quick
            test_observability_intercept_log_with_logger_both_orders;
          Alcotest.test_case "intercept_log raise becomes defect" `Quick
            test_observability_intercept_log_raise_becomes_defect;
          Alcotest.test_case "intercept_metric enriches subtree" `Quick
            test_observability_intercept_metric_enriches_subtree;
          Alcotest.test_case "intercept_metric drop short-circuits" `Quick
            test_observability_intercept_metric_drop_short_circuits;
          Alcotest.test_case "custom noop tracer is explicitly enabled" `Quick
            test_observability_custom_noop_tracer_is_explicitly_enabled;
          Alcotest.test_case "empty tracer ids use ambient parent" `Quick
            test_scoped_tracer_empty_ids_use_ambient_parent;
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
          Alcotest.test_case "all map_par supervisor inherit parent" `Quick
            test_observability_all_for_each_supervisor_inherit_parent;
          Alcotest.test_case "with_result_attrs callback failures" `Quick
            (fun () ->
              B.with_traced_runtime @@ fun _ctx rt _tracer ->
              let ok_boom = Failure "ok_attrs" in
              let ok_program =
                Eta_observability.with_result_attrs
                  ~ok_attrs:(fun () -> raise ok_boom)
                  ~err_attrs:(fun _ -> []) Effect.unit
              in
              (match B.run rt ok_program with
              | Exit.Error (Cause.Die die) ->
                  Alcotest.(check bool) "success replaced" true
                    (die.exn == ok_boom)
              | _ -> Alcotest.fail "expected ok_attrs defect");
              let err_boom = Failure "err_attrs" in
              let err_program =
                Eta_observability.with_result_attrs
                  ~ok_attrs:(fun _ -> [])
                  ~err_attrs:(fun `Bad -> raise err_boom)
                  (Effect.fail `Bad)
              in
              match B.run rt err_program with
              | Exit.Error
                  (Cause.Suppressed
                    {
                      primary = Cause.Fail `Bad;
                      finalizer = Cause.Finalizer.Die die;
                    }) ->
                  Alcotest.(check bool) "failure kept primary" true
                    (die.exn == err_boom)
              | _ -> Alcotest.fail "expected suppressed err_attrs defect");
          Alcotest.test_case "with_context active parent precedence" `Quick
            (fun () ->
              B.with_traced_runtime @@ fun _ctx rt _tracer ->
              let inbound =
                Option.get
                  (Eta_observability.Trace_context.make
                     ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
                     ~span_id:"00f067aa0ba902b7" ())
              in
              let parent, child =
                run_ok rt
                  (Eta_observability.named "parent"
                     (Effect.bind
                        (fun parent ->
                          Eta_observability.with_context inbound
                            (Eta_observability.named "child"
                               (Effect.map
                                  (fun child ->
                                    ( require_current_span parent,
                                      require_current_span child ))
                                  Eta_observability.current_span)))
                        Eta_observability.current_span))
              in
              Alcotest.(check string) "active parent trace wins" parent.trace_id
                child.trace_id;
              Alcotest.(check bool) "external trace did not replace parent" true
                (not (String.equal inbound.trace_id child.trace_id)));
          Alcotest.test_case "tracing admission observes suppression" `Quick
            (fun () ->
              B.with_traced_runtime @@ fun _ctx rt _tracer ->
              Alcotest.(check bool) "installed tracer admitted" true
                (run_ok rt Eta_observability.is_tracing_enabled);
              Alcotest.(check bool) "suppressed tracer not admitted" false
                (run_ok rt
                   (Eta_observability.suppress_observability
                      Eta_observability.is_tracing_enabled)));
        ] );
    ]
end
