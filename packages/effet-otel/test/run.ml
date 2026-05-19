(* Test runner for effet-otel. Wires the ported Effect-TS suites
   (Tracer/Logger/Metrics) plus the OTLP encoder smoke and live-motel
   integration tests. *)

open Effet

let env = ()

let test_encoder_smoke () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let exporter =
    Effet_otel.create ~sw
      ~net:(Eio.Stdenv.net stdenv)
      ~clock:(Eio.Stdenv.clock stdenv)
      ~host:"127.0.0.1" ~port:1
      ~service_name:"effet-otel-encoder-smoke"
      ~on_error:(fun _ -> ())
      ()
  in
  let tracer = Effet_otel.tracer exporter in
  let parent = tracer#begin_span ~name:"parent" ~started_ms:1000 () in
  tracer#add_attr ~key:"phase" ~value:"setup";
  let child =
    tracer#begin_span ~parent_id:parent ~name:"child" ~started_ms:1010 ()
  in
  tracer#end_span ~span_id:child ~status:Capabilities.Ok ~ended_ms:1020;
  tracer#end_span ~span_id:parent
    ~status:(Capabilities.Error "boom") ~ended_ms:1030;
  Alcotest.(check pass) "encoder ran without raising" () ()

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
    Effet_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port:27686
      ~path:"/v1/traces" ~service_name:"effet-otel-itest"
      ~service_version:"0.0.1"
      ~resource_attrs:
        [ ("test.run_id", string_of_int (int_of_float (Eio.Time.now clock))) ]
      ~on_error:(fun msg ->
        prerr_endline ("[itest] export error: " ^ msg))
      ()
  in
  let rt =
    Runtime.create ~sw ~clock ~tracer:(Effet_otel.tracer exporter) ~env ()
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
  Effet_otel.flush exporter

let test_motel_live () =
  Eio_main.run @@ fun stdenv ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  if not (motel_reachable net) then
    print_endline "[skip] motel not reachable on 127.0.0.1:27686"
  else live_motel_test net clock

let () =
  Alcotest.run "effet-otel"
    [
      ( "encoder",
        [ Alcotest.test_case "smoke" `Quick test_encoder_smoke ] );
      ( "motel",
        [ Alcotest.test_case "live export" `Quick test_motel_live ] );
      Test_tracer.suite;
      Test_logger.suite;
      Test_metrics.suite;
    ]
