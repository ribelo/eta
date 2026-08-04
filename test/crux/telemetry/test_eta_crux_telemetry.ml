module Crux = Eta_crux
module Observability = Eta_observability

let rec poll_closed driver =
  let open Eta.Syntax in
  let* event = Crux.Driver.poll driver in
  match event with
  | Some (Crux.Driver.Closed terminal) ->
      Eta.Effect.pure terminal
  | Some (Crux.Driver.Deliver delivery) ->
      let* _ = Crux.Driver.Delivery.delivered delivery in
      poll_closed driver
  | Some (Crux.Driver.Request event) ->
      let* _ = Crux.Request.Driver_event.accepted event in
      poll_closed driver
  | Some (Crux.Driver.Rejected _)
  | Some (Crux.Driver.Crash_detected _)
  | None ->
      let* () = Eta.Effect.yield in
      poll_closed driver

let normal_program () =
  let open Eta.Syntax in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 5)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let* event = Crux.Driver.poll driver in
  let output, delivery =
    match event with
    | Some (Crux.Driver.Deliver delivery) ->
        (Crux.Driver.Delivery.output delivery, delivery)
    | Some _ | None ->
        failwith "expected initial output delivery"
  in
  let* answer = Crux.Driver.Delivery.delivered delivery in
  (match answer with
  | Ok () -> ()
  | Error Crux.Driver.Delivery.Already_completed ->
      failwith "fresh delivery was already complete");
  let* idle = Crux.Driver.poll driver in
  (match idle with
  | None -> ()
  | Some _ -> failwith "expected an idle poll");
  Crux.Driver.request_stop driver;
  let+ terminal = poll_closed driver in
  (output, terminal)

let request_program () =
  let open Eta.Syntax in
  let int_codec =
    Crux.Codec.make
      ~encode:(fun value ->
        Bytes.of_string (string_of_int value))
      ~decode:(fun bytes ->
        try Ok (int_of_string (Bytes.to_string bytes))
        with Failure message ->
          Error { Crux.Codec.message = message })
  in
  let string_codec =
    Crux.Codec.make ~encode:Bytes.of_string
      ~decode:(fun bytes -> Ok (Bytes.to_string bytes))
  in
  let operation =
    Crux.Host_operation.define ~name:"telemetry.echo"
      ~request:int_codec ~response:string_codec
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack operation ]
  in
  let requester =
    Crux.Driver.Binding.requester binding operation
  in
  let response = ref None in
  let request =
    Crux.Requester.request requester 42
    |> Eta.Effect.map (fun value ->
           response := Some value)
    |> Eta.Effect.ignore_errors
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both (Crux.return ())
         (Crux.lifecycle (Crux.return request)))
  in
  let driver = Crux.Driver.create binding root in
  let* initial = Crux.Driver.poll driver in
  let delivery =
    match initial with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None ->
        failwith "expected request-root delivery"
  in
  let* _ = Crux.Driver.Delivery.delivered delivery in
  let rec await_request () =
    let* event = Crux.Driver.poll driver in
    match event with
    | Some (Crux.Driver.Request event) ->
        Eta.Effect.pure event
    | Some _ | None ->
        let* () = Eta.Effect.yield in
        await_request ()
  in
  let* event = await_request () in
  let* handled =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun value ~resolve ~on_cancel:_ ->
        resolve (string_of_int value)
        |> Eta.Effect.map (fun _ -> ()))
  in
  (match handled with
  | Crux.Request.Driver_event.Handled -> ()
  | Crux.Request.Driver_event.Different_operation ->
      failwith "request operation mismatch");
  let* _ = Crux.Request.Driver_event.accepted event in
  let rec await_response () =
    match !response with
    | Some response -> Eta.Effect.pure response
    | None ->
        let* () = Eta.Effect.yield in
        await_response ()
  in
  let* response = await_response () in
  Crux.Driver.request_stop driver;
  let+ _ = poll_closed driver in
  response

let replacement_attempt () =
  let first, _ =
    Crux.Serialized_session.candidate
      ~max_frame_bytes:4096
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized
      ~output:
        (Crux.Codec.make ~encode:Bytes.of_string
           ~decode:(fun bytes ->
             Ok (Bytes.to_string bytes)))
      ~operations:[] ~session:first
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return "replacement-output")
  in
  ignore (Crux.Driver.create binding root);
  let candidate, _ =
    Crux.Serialized_session.candidate
      ~max_frame_bytes:4096
      ~format:(module Eta_crux_json.Format)
  in
  Crux.Serialized_session.replace admin candidate
  |> Eta.Effect.to_result
  |> Eta.Effect.map (function
       | Error Crux.Serialized_session.Starting -> ()
       | Ok _
       | Error
           (Crux.Serialized_session.Replacement_pending
           | Crux.Serialized_session.Awaiting_delivery
           | Crux.Serialized_session.Terminating
           | Crux.Serialized_session.Closed) ->
           failwith "unexpected replacement result")

let telemetry_program () =
  let open Eta.Syntax in
  let* normal = normal_program () in
  let* response = request_program () in
  let* () = replacement_attempt () in
  Eta.Effect.pure (normal, response)

let sorted_strings values = List.sort String.compare values

let attrs_have_exact_keys expected attrs =
  sorted_strings (List.map fst attrs)
  = sorted_strings expected

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop offset =
    offset + fragment_length <= text_length
    && (String.sub text offset fragment_length = fragment
       || loop (offset + 1))
  in
  fragment_length = 0 || loop 0

let test_telemetry_contract () =
  let outcome = Eta_test.Run.run (telemetry_program ()) in
  let (output, terminal), response =
    Eta_test.Expect.expect_ok outcome.exit
  in
  Alcotest.(check int) "typed output unchanged" 5 output;
  Alcotest.(check string) "typed response unchanged" "42" response;
  Alcotest.(check bool) "normal terminal" true
    (match terminal with Crux.Driver.Stopped -> true | Crux.Driver.Crashed _ -> false);
  let logs = outcome.logs in
  let log_bodies =
    List.map (fun log -> log.Observability.Logger.body) logs
  in
  Alcotest.(check bool) "started log" true
    (List.mem "eta_crux.root.started" log_bodies);
  Alcotest.(check bool) "stopped log" true
    (List.mem "eta_crux.root.stopped" log_bodies);
  List.iter
    (fun log ->
      let expected_level =
        match log.Observability.Logger.body with
        | "eta_crux.root.started"
        | "eta_crux.root.stopped" ->
            Some Eta.Capabilities.Info
        | "eta_crux.root.crashed" ->
            Some Eta.Capabilities.Error
        | _ -> None
      in
      match expected_level with
      | None -> Alcotest.fail "unexpected Eta Crux log body"
      | Some level ->
          Alcotest.(check bool) "fixed log level" true
            (log.level = level))
    logs;
  let allowed_spans =
    [
      "eta_crux.advance";
      "eta_crux.post_commit";
      "eta_crux.driver.delivery";
      "eta_crux.driver.request";
      "eta_crux.session.replace";
      "eta_crux.root.teardown";
    ]
  in
  let span_names =
    List.map (fun span -> span.Observability.Tracer.name)
      outcome.spans
  in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("span exists: " ^ name) true
        (List.mem name span_names))
    allowed_spans;
  List.iter
    (fun name ->
      Alcotest.(check bool) "fixed span name" true
        (List.mem name allowed_spans))
    span_names;
  List.iter
    (fun point ->
      match point.Observability.Meter.name with
      | "eta_crux.advancements.total" ->
          Alcotest.(check string) "counter unit"
            "{advancement}" point.unit_;
          Alcotest.(check bool) "counter attributes" true
            (attrs_have_exact_keys
               [ "eta_crux.trigger"; "eta_crux.outcome" ]
               point.attrs);
          Alcotest.(check bool) "monotonic counter" true
            (match point.kind with
            | Eta.Capabilities.Counter { monotonic = true } ->
                true
            | _ -> false)
      | "eta_crux.advancement.duration" ->
          Alcotest.(check string) "duration unit" "ms"
            point.unit_;
          Alcotest.(check bool) "duration attributes" true
            (attrs_have_exact_keys
               [ "eta_crux.trigger"; "eta_crux.outcome" ]
               point.attrs);
          Alcotest.(check bool) "fixed duration buckets" true
            (match point.kind with
            | Eta.Capabilities.Histogram { boundaries } ->
                boundaries
                = [
                    0.01; 0.025; 0.05; 0.1; 0.25; 0.5;
                    1.; 2.5; 5.; 10.; 25.; 50.; 100.;
                    250.; 500.; 1000.;
                  ]
            | _ -> false)
      | "eta_crux.roots.terminal.total" ->
          Alcotest.(check string) "terminal unit" "{root}"
            point.unit_;
          Alcotest.(check bool) "terminal attributes" true
            (attrs_have_exact_keys
               [ "eta_crux.outcome" ] point.attrs)
      | _ -> Alcotest.fail "unexpected Eta Crux metric")
    outcome.metrics

let test_crash_redaction () =
  let secret = "secret-model-action-cause" in
  let crashing =
    Crux.map (Crux.return ()) ~f:(fun () ->
        raise (Failure secret))
  in
  let program =
    let open Eta.Syntax in
    let root =
      Crux.Root.create ~ingress_capacity:1
        ~request_capacity:1 crashing
    in
    let driver =
      Crux.Driver.create (Crux.Driver.Binding.identity []) root
    in
    let* detected = Crux.Driver.poll driver in
    (match detected with
    | Some (Crux.Driver.Crash_detected _) -> ()
    | Some _ | None -> failwith "expected crash detection");
    poll_closed driver
  in
  let outcome = Eta_test.Run.run program in
  ignore (Eta_test.Expect.expect_ok outcome.exit);
  let crash_log =
    List.find
      (fun log ->
        String.equal log.Observability.Logger.body
          "eta_crux.root.crashed")
      outcome.logs
  in
  Alcotest.(check bool) "crash level" true
    (crash_log.level = Eta.Capabilities.Error);
  Alcotest.(check bool) "closed crash attributes" true
    (attrs_have_exact_keys
       [
         "eta_crux.failure.origin";
         "eta_crux.failure.trigger";
         "eta_crux.observation.position";
       ]
       crash_log.attrs);
  let rendered =
    outcome.logs
    |> List.map Observability.Logger.format_logfmt
    |> String.concat "\n"
  in
  Alcotest.(check bool) "failure payload is redacted" false
    (contains rendered secret)

let test_span_boundaries () =
  let clock = Eta_test.Test_clock.create () in
  let advanced = ref false in
  let description =
    Crux.map (Crux.return ()) ~f:(fun () ->
        if not !advanced then (
          advanced := true;
          Eta_test.Test_clock.adjust clock (Eta.Duration.ms 7));
        ())
  in
  let program =
    let open Eta.Syntax in
    let root =
      Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
        description
    in
    let driver =
      Crux.Driver.create (Crux.Driver.Binding.identity []) root
    in
    let* initial = Crux.Driver.poll driver in
    let delivery =
      match initial with
      | Some (Crux.Driver.Deliver delivery) -> delivery
      | Some _ | None -> failwith "span-boundary root did not start"
    in
    let* _ = Crux.Driver.Delivery.delivered delivery in
    Crux.Driver.request_stop driver;
    let+ _ = poll_closed driver in
    ()
  in
  let outcome = Eta_test.Run.run ~clock program in
  ignore (Eta_test.Expect.expect_ok outcome.exit);
  let find name =
    List.find
      (fun span ->
        String.equal span.Observability.Tracer.name name)
      outcome.spans
  in
  let advance = find "eta_crux.advance" in
  Alcotest.(check int) "advance span starts before transition" 0
    advance.started_ms;
  Alcotest.(check int) "advance span ends after transition" 7
    advance.ended_ms;
  let teardown = find "eta_crux.root.teardown" in
  let teardown_parent =
    match teardown.parent_id with
    | None -> None
    | Some parent_id ->
        List.find_opt
          (fun span ->
            span.Observability.Tracer.span_id = parent_id)
          outcome.spans
  in
  Alcotest.(check (option string)) "teardown is inside post-commit"
    (Some "eta_crux.post_commit")
    (Option.map
       (fun span -> span.Observability.Tracer.name)
       teardown_parent)

let conformance_disabled_telemetry () =
  let enabled = Eta_test.Run.run (normal_program ()) in
  let disabled =
    Eta_test.Run.run
      (Observability.suppress_observability
         (normal_program ()))
  in
  let enabled_result = Eta_test.Expect.expect_ok enabled.exit in
  let disabled_result = Eta_test.Expect.expect_ok disabled.exit in
  let summarize (output, terminal) =
    ( output,
      match terminal with
      | Crux.Driver.Stopped -> "stopped"
      | Crux.Driver.Crashed _ -> "crashed" )
  in
  Alcotest.(check (pair int string))
    "semantic observation is unchanged"
    (summarize enabled_result)
    (summarize disabled_result);
  Alcotest.(check int) "disabled logs" 0
    (List.length disabled.logs);
  Alcotest.(check int) "disabled spans" 0
    (List.length disabled.spans);
  Alcotest.(check int) "disabled metrics" 0
    (List.length disabled.metrics);
  Alcotest.(check int) "disabled event retention" 0
    (List.length disabled.events)

let () =
  Alcotest.run "eta_crux telemetry"
    [
      ( "telemetry",
        [
          Alcotest.test_case "fixed contract" `Quick
            test_telemetry_contract;
          Alcotest.test_case "crash redaction" `Quick
            test_crash_redaction;
          Alcotest.test_case "span boundaries" `Quick
            test_span_boundaries;
          Alcotest.test_case "disabled conformance" `Quick
            conformance_disabled_telemetry;
        ] );
    ]
