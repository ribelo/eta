open Eta

let push target line = target := !target @ [ line ]

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let test_terminal_exporter_runtime_adapters () =
  let stdout = ref [] in
  let stderr = ref [] in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let now = ref 100 in
  let terminal =
    Eta_otel.Terminal.create ~stdout:(push stdout) ~stderr:(push stderr) ()
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~now_ms:(fun () -> !now)
      ~tracer:(Eta_otel.Terminal.tracer terminal)
      ~meter:(Eta_otel.Terminal.meter terminal) ()
  in
  let program =
    Effect.concat
      [
        Effect.named "live.span" (Effect.sync (fun () -> now := 125));
        Effect.sync (fun () -> now := 200);
        Effect.metric_update ~name:"live.metric" ~description:"Live metric"
          ~unit_:"item" ~kind:Capabilities.Gauge
          ~attrs:[ ("source", "terminal-test") ]
          (Capabilities.Int 7);
      ]
  in
  (match Runtime.run rt program with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause);
  let span_line, metric_line =
    match !stdout with
    | [ span_line; metric_line ] -> (span_line, metric_line)
    | lines ->
        Alcotest.failf "expected two stdout lines, got %d" (List.length lines)
  in
  List.iter
    (fun field ->
      Alcotest.(check bool) field true (string_contains span_line field))
    [
      "otel.span ";
      "ts_ms=125";
      "started_ms=100";
      "ended_ms=125";
      "duration=25ms";
      "name=live.span";
      "kind=internal";
      "status=ok";
      "span_id=0000000000000001";
      "trace_flags=1";
    ];
  Alcotest.(check string) "metric line"
    "otel.metric ts_ms=200 name=live.metric kind=gauge value=7 description=\"Live metric\" unit=item attr.source=terminal-test"
    metric_line;
  Alcotest.(check (list string)) "stderr" [] !stderr

let suite =
  ( "terminal",
    [
      Alcotest.test_case "runtime adapters" `Quick
        test_terminal_exporter_runtime_adapters;
    ] )
