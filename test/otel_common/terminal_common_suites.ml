open Eta

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let push target line = target := !target @ [ line ]

  let test_terminal_tracer_formats_completed_spans () =
    let stdout = ref [] in
    let stderr = ref [] in
    let terminal =
      Eta_otel.Terminal.create ~stdout:(push stdout) ~stderr:(push stderr) ()
    in
    let tracer = Eta_otel.Terminal.tracer terminal in
    B.with_runtime_contract @@ fun _ctx contract ->
    let span =
      tracer#begin_span contract ~trace_id:"11111111111111111111111111111111"
        ~kind:Capabilities.Client ~name:"GET /users" ~started_ms:100 ()
    in
    tracer#add_attr_to contract ~span_id:span ~key:"route" ~value:"/users";
    tracer#add_event contract ~span_id:span ~name:"db.query" ~ts_ms:112
      ~attrs:[ ("rows", "3") ];
    tracer#add_link_to contract ~span_id:span
      {
        Capabilities.link_trace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        link_span_id = "bbbbbbbbbbbbbbbb";
        link_attrs = [ ("kind", "parent") ];
      };
    tracer#end_span contract ~span_id:span ~status:Capabilities.Ok ~ended_ms:137;
    Alcotest.(check (list string)) "stdout"
      [
        "otel.span ts_ms=137 started_ms=100 ended_ms=137 duration=37ms name=\"GET /users\" kind=client status=ok trace_id=11111111111111111111111111111111 span_id=0000000000000001 trace_flags=1 attr.route=/users event.0.name=db.query event.0.ts_ms=112 event.0.attr.rows=3 link.0.trace_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa link.0.span_id=bbbbbbbbbbbbbbbb link.0.attr.kind=parent";
      ]
      !stdout;
    Alcotest.(check (list string)) "stderr" [] !stderr

  let test_terminal_tracer_routes_failed_spans_to_stderr () =
    let stdout = ref [] in
    let stderr = ref [] in
    let terminal =
      Eta_otel.Terminal.create ~stdout:(push stdout) ~stderr:(push stderr) ()
    in
    let tracer = Eta_otel.Terminal.tracer terminal in
    B.with_runtime_contract @@ fun _ctx contract ->
    let span =
      tracer#begin_span contract ~trace_id:"22222222222222222222222222222222"
        ~name:"db" ~started_ms:10 ()
    in
    tracer#end_span contract ~span_id:span
      ~status:(Capabilities.Error "connection refused") ~ended_ms:15;
    Alcotest.(check (list string)) "stdout" [] !stdout;
    Alcotest.(check (list string)) "stderr"
      [
        "otel.span ts_ms=15 started_ms=10 ended_ms=15 duration=5ms name=db kind=internal status=error status_message=\"connection refused\" trace_id=22222222222222222222222222222222 span_id=0000000000000001 trace_flags=1";
      ]
      !stderr

  let test_terminal_meter_formats_metric_points () =
    let stdout = ref [] in
    let stderr = ref [] in
    let terminal =
      Eta_otel.Terminal.create ~stdout:(push stdout) ~stderr:(push stderr) ()
    in
    let meter = Eta_otel.Terminal.meter terminal in
    meter#record
      {
        Meter.name = "requests.total";
        description = "Total requests";
        unit_ = "request";
        kind = Capabilities.Counter { monotonic = true };
        attrs = [ ("route", "/users"); ("bad key", "x") ];
        value = Capabilities.Number (Capabilities.Int 2);
        ts_ms = 200;
      };
    meter#record
      {
        Meter.name = "latency";
        description = "";
        unit_ = "ms";
        kind = Capabilities.Histogram { boundaries = [ 10.0; 20.0 ] };
        attrs = [];
        value = Capabilities.Number (Capabilities.Float 12.5);
        ts_ms = 201;
      };
    Alcotest.(check (list string)) "stdout"
      [
        "otel.metric ts_ms=200 name=requests.total kind=counter_monotonic value=2 description=\"Total requests\" unit=request attr.route=/users attr.bad_key=x";
        "otel.metric ts_ms=201 name=latency kind=histogram value=12.5 boundaries=10,20 unit=ms";
      ]
      !stdout;
    Alcotest.(check (list string)) "stderr" [] !stderr

  let suite =
    ( "Terminal",
      [
        Alcotest.test_case "formats completed spans" `Quick
          test_terminal_tracer_formats_completed_spans;
        Alcotest.test_case "routes failed spans to stderr" `Quick
          test_terminal_tracer_routes_failed_spans_to_stderr;
        Alcotest.test_case "formats metric points" `Quick
          test_terminal_meter_formats_metric_points;
      ] )
end
