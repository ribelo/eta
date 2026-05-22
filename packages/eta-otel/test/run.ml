(* Test runner for eta-otel. Wires the ported Effect-TS suites
   (Tracer/Logger/Metrics) plus the OTLP encoder smoke and live-motel
   integration tests. *)

open Eta

let rec json_has_span_kind ~name ~kind = function
  | `Assoc fields ->
      let has_name = List.assoc_opt "name" fields = Some (`String name) in
      let has_kind = List.assoc_opt "kind" fields = Some (`Int kind) in
      (has_name && has_kind)
      || List.exists (fun (_, value) -> json_has_span_kind ~name ~kind value) fields
  | `List xs -> List.exists (json_has_span_kind ~name ~kind) xs
  | _ -> false

let rec json_has_string_field ~key ~value = function
  | `Assoc fields ->
      List.assoc_opt key fields = Some (`String value)
      || List.exists (fun (_, v) -> json_has_string_field ~key ~value v) fields
  | `List xs -> List.exists (json_has_string_field ~key ~value) xs
  | _ -> false

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listening socket"

let closed_tcp_port net =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  tcp_port (Eio.Net.listening_addr socket)

let start_response_server ~sw ~net ~clock ?(delay_s = 0.0) ?(connections = 16)
    response =
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:16 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         for _ = 1 to connections do
           Eio.Switch.run @@ fun conn_sw ->
           let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
           if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
           Eio.Flow.copy_string response flow;
           try Eio.Flow.shutdown flow `Send with _ -> ()
         done
       with _ -> ());
      `Stop_daemon);
  port

let emit_span (tracer : Capabilities.tracer) name =
  let span = tracer#begin_span ~name ~started_ms:0 () in
  tracer#end_span ~span_id:span ~status:Capabilities.Ok ~ended_ms:0

let test_encoder_smoke () =
  let bodies = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let exporter =
    Eta_otel.create ~sw
      ~net:(Eio.Stdenv.net stdenv)
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port:1
      ~service_name:"eta-otel-encoder-smoke"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path:_ ~body -> bodies := body :: !bodies)
      ()
  in
  let tracer = Eta_otel.tracer exporter in
  let external_parent =
    Option.get
      (Trace_context.make ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
         ~span_id:"00f067aa0ba902b7"
         ~trace_state:[ ("rojo", "00f067aa0ba902b7") ]
         ~baggage:[ ("tenant", "acme") ] ())
  in
  let parent =
    tracer#begin_span ~external_parent ~name:"parent" ~started_ms:1000 ()
  in
  tracer#add_attr ~key:"phase" ~value:"setup";
  let child =
    tracer#begin_span ~parent_id:parent ~kind:Capabilities.Server ~name:"child"
      ~started_ms:1010 ()
  in
  tracer#end_span ~span_id:child ~status:Capabilities.Ok ~ended_ms:1020;
  tracer#end_span ~span_id:parent
    ~status:(Capabilities.Error "boom") ~ended_ms:1030;
  Eta_otel.flush exporter;
  Alcotest.(check pass) "encoder ran without raising" () ();
  let body = String.concat "\n" (List.rev !bodies) in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check bool) "server span kind encoded" true
    (json_has_span_kind ~name:"child" ~kind:2 json);
  Alcotest.(check bool) "tracestate encoded" true
    (json_has_string_field ~key:"traceState" ~value:"rojo=00f067aa0ba902b7" json)

let test_exception_stacktrace_exported () =
  let bodies = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Eta_otel.create ~sw
      ~net:(Eio.Stdenv.net stdenv)
      ~clock ~host:"127.0.0.1" ~port:1
      ~service_name:"eta-otel-exception-stacktrace"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path:_ ~body -> bodies := body :: !bodies)
      ()
  in
  let rt = Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) () in
  let eff =
    Effect.named "failing.span"
      (Effect.named "failing.leaf" (Effect.sync (fun () -> failwith "wire stacktrace"))
      |> Effect.annotate ~key:"phase" ~value:"test")
  in
  ignore (Runtime.run rt eff : (unit, _) Exit.t);
  Eta_otel.flush exporter;
  let body = String.concat "\n" (List.rev !bodies) in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check bool) "exception event exported" true
    (json_has_string_field ~key:"name" ~value:"exception" json);
  Alcotest.(check bool) "stacktrace attr exported" true
    (json_has_string_field ~key:"key" ~value:"exception.stacktrace" json);
  Alcotest.(check bool) "annotation attr exported" true
    (json_has_string_field ~key:"key" ~value:"eta.annotation.phase" json)

let test_network_partition_reports_error () =
  let errors = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let port = closed_tcp_port net in
  let exporter =
    Eta_otel.create ~sw
      ~net
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-network-partition"
      ~on_error:(fun msg -> errors := msg :: !errors)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "partitioned";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  Alcotest.(check bool) "network error reported" true (!errors <> [])

let test_malformed_response_reports_error () =
  let errors = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port =
    start_response_server ~sw ~net ~clock
      "HTTP/1.1 500 Broken\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-malformed-response"
      ~on_error:(fun msg -> errors := msg :: !errors)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "malformed";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  Alcotest.(check bool) "collector error reported" true (!errors <> [])

let test_slow_collector_flush_timeout () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port =
    start_response_server ~sw ~net ~clock ~delay_s:1.0
      "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-slow-collector"
      ~on_error:(fun _ -> ())
      ()
  in
  emit_span (Eta_otel.tracer exporter) "slow";
  let started = Eio.Time.now clock in
  Eta_otel.flush ~timeout_s:0.02 exporter;
  let elapsed = Eio.Time.now clock -. started in
  Alcotest.(check bool) "flush respects timeout" true (elapsed < 0.5)

let test_backpressure_overflow_drops () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let gate, release = Eio.Promise.create () in
  let net = Eio.Stdenv.net stdenv in
  let port = closed_tcp_port net in
  let exporter =
    Eta_otel.create ~sw
      ~net
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port ~queue_capacity:1
      ~service_name:"eta-otel-backpressure"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path:_ ~body:_ -> Eio.Promise.await gate)
      ()
  in
  let tracer = Eta_otel.tracer exporter in
  for i = 1 to 128 do
    emit_span tracer ("overflow-" ^ string_of_int i)
  done;
  Alcotest.(check bool)
    "overflow drops instead of blocking producers" true
    (Eta_otel.Internal.dropped exporter > 0);
  Eio.Promise.resolve release ();
  Eta_otel.flush ~timeout_s:1.0 exporter

let test_shutdown_closes_queues () =
  let sends = ref 0 in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let port = closed_tcp_port net in
  let exporter =
    Eta_otel.create ~sw
      ~net
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-shutdown"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path:_ ~body:_ -> incr sends)
      ()
  in
  let tracer = Eta_otel.tracer exporter in
  emit_span tracer "before-shutdown";
  Eta_otel.shutdown ~timeout_s:1.0 exporter;
  let sent_before_closed_offer = !sends in
  emit_span tracer "after-shutdown";
  Eta_otel.flush ~timeout_s:0.05 exporter;
  Alcotest.(check int)
    "signals after shutdown are not exported" sent_before_closed_offer !sends

let test_self_spans_do_not_reenter_export () =
  let bodies = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let port = closed_tcp_port net in
  let exporter =
    Eta_otel.create ~sw ~net
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-self-spans"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path:_ ~body -> bodies := body :: !bodies)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "application-span";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  let self_names =
    Eta_otel.Internal.self_spans exporter |> List.map (fun s -> s.Tracer.name)
  in
  Alcotest.(check bool) "config resource span recorded" true
    (List.exists (( = ) "eta_otel.config") self_names);
  Alcotest.(check bool) "self export span recorded" true
    (List.exists (( = ) "eta_otel.export.traces") self_names);
  let exported = String.concat "\n" (List.rev !bodies) in
  Alcotest.(check bool) "self spans are not exported" false
    (string_contains exported "eta_otel.export.traces");
  Alcotest.(check bool) "application span is exported" true
    (string_contains exported "application-span")

let motel_reachable net =
  try
    Eio.Switch.run @@ fun sw ->
    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
        ());
    let _ = sw in
    true
  with _ -> false

let live_motel_test net clock =
  Eio.Switch.run @@ fun sw ->
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port:27686
      ~traces_path:"/v1/traces" ~service_name:"eta-otel-itest"
      ~service_version:"0.0.1"
      ~resource_attrs:
        [ ("test.run_id", string_of_int (int_of_float (Eio.Time.now clock))) ]
      ~on_error:(fun msg ->
        prerr_endline ("[itest] export error: " ^ msg))
      ()
  in
  let rt =
    Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) ()
  in
  let demo =
    Effect.named "demo.root"
      (Effect.par
         (Effect.named "demo.left"
            (Effect.named "work-left" (Effect.sync (fun () ->
                 Eio.Time.sleep clock 0.005))
            |> Effect.annotate ~key:"side" ~value:"left"))
         (Effect.named "demo.right"
            (Effect.named "work-right" (Effect.sync (fun () ->
                 Eio.Time.sleep clock 0.010))
            |> Effect.annotate ~key:"side" ~value:"right"
            |> Effect.bind (fun () -> Effect.fail `Demo_boom)
            |> Effect.catch (fun (`Demo_boom : [ `Demo_boom ]) ->
                   Effect.pure ()))))
  in
  (match Runtime.run rt demo with
  | Exit.Ok _ -> ()
  | Exit.Error _ -> Alcotest.fail "expected success");
  let failing = Effect.named "demo.failing" (Effect.fail `Boom) in
  (match Runtime.run rt failing with
  | Exit.Ok _ -> Alcotest.fail "expected failure"
  | Exit.Error _ -> ());
  Eta_otel.flush exporter

let test_motel_live () =
  Eio_main.run @@ fun stdenv ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  if not (motel_reachable net) then
    print_endline "[skip] motel not reachable on 127.0.0.1:27686"
  else live_motel_test net clock

let () =
  Alcotest.run "eta-otel"
    [
      ( "encoder",
        [
          Alcotest.test_case "smoke" `Quick test_encoder_smoke;
          Alcotest.test_case "exception stacktrace" `Quick
            test_exception_stacktrace_exported;
        ] );
      ( "adversarial",
        [
          Alcotest.test_case "network partition" `Quick
            test_network_partition_reports_error;
          Alcotest.test_case "malformed response" `Quick
            test_malformed_response_reports_error;
          Alcotest.test_case "slow collector flush timeout" `Quick
            test_slow_collector_flush_timeout;
          Alcotest.test_case "backpressure overflow" `Quick
            test_backpressure_overflow_drops;
          Alcotest.test_case "shutdown closes queues" `Quick
            test_shutdown_closes_queues;
          Alcotest.test_case "self spans do not re-enter export" `Quick
            test_self_spans_do_not_reenter_export;
        ] );
      ( "motel",
        [ Alcotest.test_case "live export" `Quick test_motel_live ] );
      Test_tracer.suite;
      Test_logger.suite;
      Test_metrics.suite;
    ]
