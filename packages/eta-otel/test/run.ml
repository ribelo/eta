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

let json_attr_has ~key ~value = function
  | `Assoc fields ->
      List.assoc_opt "key" fields = Some (`String key)
      && (match List.assoc_opt "value" fields with
         | Some (`Assoc value_fields) ->
             List.assoc_opt "stringValue" value_fields = Some (`String value)
         | _ -> false)
  | _ -> false

let rec json_span_has_attr ~name ~key ~value = function
  | `Assoc fields ->
      let is_span = List.assoc_opt "name" fields = Some (`String name) in
      let has_attr =
        match List.assoc_opt "attributes" fields with
        | Some (`List attrs) -> List.exists (json_attr_has ~key ~value) attrs
        | _ -> false
      in
      (is_span && has_attr)
      || List.exists (fun (_, v) -> json_span_has_attr ~name ~key ~value v) fields
  | `List xs -> List.exists (json_span_has_attr ~name ~key ~value) xs
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

let parse_content_length line =
  match String.index_opt line ':' with
  | None -> None
  | Some index ->
      let name =
        String.sub line 0 index |> String.trim |> String.lowercase_ascii
      in
      if name <> "content-length" then None
      else
        String.sub line (index + 1) (String.length line - index - 1)
        |> String.trim |> int_of_string_opt

let parse_request_target line =
  match String.split_on_char ' ' line with
  | _method_ :: target :: _ -> Some target
  | _ -> None

let consume_request flow =
  try
    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
    let content_length = ref 0 in
    let target = parse_request_target (Eio.Buf_read.line reader) in
    let rec headers () =
      match Eio.Buf_read.line reader with
      | "" -> ()
      | line ->
          (match parse_content_length line with
          | Some len -> content_length := len
          | None -> ());
          headers ()
    in
    headers ();
    if !content_length > 0 then
      ignore (Eio.Buf_read.take !content_length reader : string);
    target
  with _ -> None

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
             ignore (consume_request flow);
             if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
             Eio.Flow.copy_string response flow;
             try Eio.Flow.shutdown flow `Send with _ -> ()
         done
       with _ -> ());
      `Stop_daemon);
  port

let start_response_sequence_server ~sw ~net ~clock ?(delay_s = 0.0)
    ?(on_request = fun _ -> ())
    ?(connections = 16) responses =
  match responses with
  | [] -> invalid_arg "start_response_sequence_server: empty response list"
  | responses ->
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:16 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port = tcp_port (Eio.Net.listening_addr socket) in
      let responses = Array.of_list responses in
      let hits = ref 0 in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          (try
             for _ = 1 to connections do
               Eio.Switch.run @@ fun conn_sw ->
               let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
               let index = min !hits (Array.length responses - 1) in
               incr hits;
               (match consume_request flow with
               | Some target -> on_request target
               | None -> ());
               if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
               Eio.Flow.copy_string responses.(index) flow;
               try Eio.Flow.shutdown flow `Send with _ -> ()
             done
           with _ -> ());
          `Stop_daemon);
      (port, hits)

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
      ~on_send:(fun ~path ~body -> bodies := (path, body) :: !bodies)
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
  let body =
    !bodies
    |> List.find_map (fun (path, body) ->
           if String.equal path "/v1/traces" then Some body else None)
    |> Option.value ~default:"{}"
  in
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
      ~on_send:(fun ~path ~body -> bodies := (path, body) :: !bodies)
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
  let body =
    !bodies
    |> List.find_map (fun (path, body) ->
           if String.equal path "/v1/traces" then Some body else None)
    |> Option.value ~default:"{}"
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check bool) "exception event exported" true
    (json_has_string_field ~key:"name" ~value:"exception" json);
  Alcotest.(check bool) "stacktrace attr exported" true
    (json_has_string_field ~key:"key" ~value:"exception.stacktrace" json);
  Alcotest.(check bool) "annotation attr exported" true
    (json_has_string_field ~key:"key" ~value:"eta.annotation.phase" json)

let test_concurrent_span_attributes_stay_on_active_span () =
  let bodies = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Eta_otel.create ~sw
      ~net:(Eio.Stdenv.net stdenv)
      ~clock ~host:"127.0.0.1" ~port:1
      ~service_name:"eta-otel-concurrent-attrs"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path ~body -> bodies := (path, body) :: !bodies)
      ()
  in
  let rt = Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) () in
  let left =
    Effect.named "left"
      (Effect.delay (Duration.ms 5)
         (Effect.annotate ~key:"side" ~value:"left" Effect.unit))
  in
  let right =
    Effect.named "right" (Effect.delay (Duration.ms 20) Effect.unit)
  in
  (match Runtime.run rt (Effect.par left right) with
  | Exit.Ok _ -> ()
  | Exit.Error _ -> Alcotest.fail "expected concurrent spans to succeed");
  Eta_otel.flush exporter;
  let trace_jsons =
    !bodies
    |> List.filter_map (fun (path, body) ->
           if String.equal path "/v1/traces" then
             Some (Yojson.Safe.from_string body)
           else None)
  in
  let any_trace pred = List.exists pred trace_jsons in
  Alcotest.(check bool) "left has its attr" true
    (any_trace (json_span_has_attr ~name:"left" ~key:"side" ~value:"left"));
  Alcotest.(check bool) "right does not receive left attr" false
    (any_trace (json_span_has_attr ~name:"right" ~key:"side" ~value:"left"))

let test_direct_tracer_attributes_use_fiber_span_stack () =
  let bodies = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Eta_otel.create ~sw
      ~net:(Eio.Stdenv.net stdenv)
      ~clock ~host:"127.0.0.1" ~port:1
      ~service_name:"eta-otel-direct-concurrent-attrs"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path ~body -> bodies := (path, body) :: !bodies)
      ()
  in
  let tracer = Eta_otel.tracer exporter in
  let rt = Runtime.create ~sw ~clock ~tracer () in
  let right_started, wake_right_started = Eio.Promise.create () in
  let left_attr_done, wake_left_attr_done = Eio.Promise.create () in
  let left =
    Effect.named "left-direct"
      (Effect.sync (fun () -> Eio.Promise.await right_started)
      |> Effect.bind (fun () ->
             Effect.sync (fun () ->
                 tracer#add_attr ~key:"side" ~value:"left-direct";
                 Eio.Promise.resolve wake_left_attr_done ())))
  in
  let right =
    Effect.named "right-direct"
      (Effect.sync (fun () ->
           Eio.Promise.resolve wake_right_started ();
           Eio.Promise.await left_attr_done))
  in
  (match Runtime.run rt (Effect.par left right) with
  | Exit.Ok _ -> ()
  | Exit.Error _ -> Alcotest.fail "expected concurrent spans to succeed");
  Eta_otel.flush exporter;
  let trace_jsons =
    !bodies
    |> List.filter_map (fun (path, body) ->
           if String.equal path "/v1/traces" then
             Some (Yojson.Safe.from_string body)
           else None)
  in
  let any_trace pred = List.exists pred trace_jsons in
  Alcotest.(check bool) "left direct span has its attr" true
    (any_trace
       (json_span_has_attr ~name:"left-direct" ~key:"side"
          ~value:"left-direct"));
  Alcotest.(check bool) "right direct span does not receive left attr" false
    (any_trace
       (json_span_has_attr ~name:"right-direct" ~key:"side"
          ~value:"left-direct"))

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

let test_encode_failure_drains_in_flight () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port = closed_tcp_port net in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-encode-failure"
      ~on_error:(fun _ -> ())
      ()
  in
  let meter = Eta_otel.meter exporter in
  meter#record ~name:"bad.float" ~description:"" ~unit_:"1"
    ~kind:Capabilities.Gauge ~attrs:[]
    ~value:(Capabilities.Float (0.0 /. 0.0))
    ~ts_ms:0;
  Eta_otel.flush ~timeout_s:0.2 exporter;
  Alcotest.(check int) "in-flight drained after encode failure" 0
    (Eta_otel.Internal.in_flight exporter)

let test_otlp_retry_excludes_408 () =
  let errors = ref [] in
  let paths = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port, _hits =
    start_response_sequence_server ~sw ~net ~clock
      ~on_request:(fun path -> paths := path :: !paths)
      [
        "HTTP/1.1 408 Request Timeout\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      ]
  in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-no-408-retry"
      ~on_error:(fun msg -> errors := msg :: !errors)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "no-408-retry";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  let trace_hits =
    !paths |> List.filter (String.equal "/v1/traces") |> List.length
  in
  Alcotest.(check int) "one trace attempt" 1 trace_hits;
  Alcotest.(check bool) "408 reported" true (!errors <> [])

let test_otlp_retry_includes_429 () =
  let errors = ref [] in
  let paths = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port, _hits =
    start_response_sequence_server ~sw ~net ~clock
      ~on_request:(fun path -> paths := path :: !paths)
      [
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      ]
  in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-429-retry"
      ~on_error:(fun msg -> errors := msg :: !errors)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "retry-429";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  let trace_hits =
    !paths |> List.filter (String.equal "/v1/traces") |> List.length
  in
  Alcotest.(check int) "two trace attempts" 2 trace_hits;
  Alcotest.(check bool) "no final error" true (!errors = [])

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

let test_self_metrics_export_without_recursion () =
  let sends = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port =
    start_response_server ~sw ~net ~clock ~connections:4
      "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-self-metrics"
      ~on_error:(fun _ -> ())
      ~on_send:(fun ~path ~body -> sends := (path, body) :: !sends)
      ()
  in
  emit_span (Eta_otel.tracer exporter) "application-span";
  Eta_otel.flush ~timeout_s:1.0 exporter;
  let metrics =
    !sends
    |> List.filter (fun (path, _) -> String.equal path "/v1/metrics")
    |> List.map snd
  in
  Alcotest.(check int) "one self metrics export" 1 (List.length metrics);
  let body =
    match metrics with
    | [ body ] -> body
    | _ -> Alcotest.fail "expected one metrics request body"
  in
  let json = Yojson.Safe.from_string body in
  [
    "eta_otel.export.batches";
    "eta_otel.export.items";
    "eta_otel.queue.depth";
    "eta_otel.queue.dropped";
    "eta_otel.in_flight";
  ]
  |> List.iter (fun name ->
         Alcotest.(check bool)
           ("self metric " ^ name) true
           (json_has_string_field ~key:"name" ~value:name json))

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
          Alcotest.test_case "concurrent span attrs" `Quick
            test_concurrent_span_attributes_stay_on_active_span;
          Alcotest.test_case "direct concurrent span attrs" `Quick
            test_direct_tracer_attributes_use_fiber_span_stack;
        ] );
      ( "adversarial",
        [
          Alcotest.test_case "network partition" `Quick
            test_network_partition_reports_error;
          Alcotest.test_case "malformed response" `Quick
            test_malformed_response_reports_error;
          Alcotest.test_case "encode failure drains in-flight" `Quick
            test_encode_failure_drains_in_flight;
          Alcotest.test_case "OTLP does not retry 408" `Quick
            test_otlp_retry_excludes_408;
          Alcotest.test_case "OTLP retries 429" `Quick
            test_otlp_retry_includes_429;
          Alcotest.test_case "slow collector flush timeout" `Quick
            test_slow_collector_flush_timeout;
          Alcotest.test_case "backpressure overflow" `Quick
            test_backpressure_overflow_drops;
          Alcotest.test_case "shutdown closes queues" `Quick
            test_shutdown_closes_queues;
          Alcotest.test_case "self spans do not re-enter export" `Quick
            test_self_spans_do_not_reenter_export;
          Alcotest.test_case "self metrics export without recursion" `Quick
            test_self_metrics_export_without_recursion;
        ] );
      ( "motel",
        [ Alcotest.test_case "live export" `Quick test_motel_live ] );
      Test_tracer.suite;
      Test_logger.suite;
      Test_metrics.suite;
    ]
