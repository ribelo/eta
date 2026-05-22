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
      (Effect.sync "failing.leaf" (fun () -> failwith "wire stacktrace")
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
            (Effect.sync "work-left" (fun () ->
                 Eio.Time.sleep clock 0.005)
            |> Effect.annotate ~key:"side" ~value:"left"))
         (Effect.named "demo.right"
            (Effect.sync "work-right" (fun () ->
                 Eio.Time.sleep clock 0.010)
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
      ( "motel",
        [ Alcotest.test_case "live export" `Quick test_motel_live ] );
      Test_tracer.suite;
      Test_logger.suite;
      Test_metrics.suite;
    ]
