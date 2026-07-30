open Eta

let record ?(level = Eta_observability.Logger.Info) ?(body = "hello world") ?(attrs = [])
    ?(trace_id = "") ?(span_id = "") () =
  {
    Eta_observability.Logger.level = level;
    body;
    ts_ms = 1_234;
    attrs;
    trace_id;
    span_id;
  }

let test_logger_formatters () =
  let log =
    record
      ~attrs:[ ("user", "alice"); ("detail", "needs quote") ]
      ~trace_id:"trace" ~span_id:"span" ()
  in
  Alcotest.(check string) "pretty"
    "[00:00:01.234] INFO hello world user=alice detail=\"needs quote\" trace_id=trace span_id=span"
    (Eta_observability.Logger.format_pretty log);
  Alcotest.(check string) "logfmt"
    "timestamp_ms=1234 level=info msg=\"hello world\" user=alice detail=\"needs quote\" trace_id=trace span_id=span"
    (Eta_observability.Logger.format_logfmt log);
  Alcotest.(check string) "json"
    "{\"timestamp_ms\":1234,\"level\":\"info\",\"msg\":\"hello world\",\"attrs\":{\"user\":\"alice\",\"detail\":\"needs quote\"},\"trace_id\":\"trace\",\"span_id\":\"span\"}"
    (Eta_observability.Logger.format_json log)

let test_logger_json_escapes_values () =
  let log = record ~body:"quote \" newline\n" ~attrs:[ ("k", "tab\t") ] () in
  Alcotest.(check string) "json escaped"
    "{\"timestamp_ms\":1234,\"level\":\"info\",\"msg\":\"quote \\\" newline\\n\",\"attrs\":{\"k\":\"tab\\t\"}}"
    (Eta_observability.Logger.format_json log)

let test_logger_logfmt_rejects_invalid_labels () =
  let log = record ~attrs:[ ("bad key", "value") ] () in
  Alcotest.check_raises "invalid label"
    (Invalid_argument "Logger.format_logfmt: invalid logfmt label bad key")
    (fun () -> ignore (Eta_observability.Logger.format_logfmt log));
  Alcotest.(check string) "pretty accepts diagnostic key"
    "[00:00:01.234] INFO hello world \"bad key\"=value"
    (Eta_observability.Logger.format_pretty log)

let test_logger_with_min_level () =
  let memory = Eta_observability.Logger.in_memory () in
  let logger = Eta_observability.Logger.with_min_level Eta_observability.Logger.Warn (Eta_observability.Logger.as_capability memory) in
  logger#log (record ~level:Eta_observability.Logger.Info ());
  logger#log (record ~level:Eta_observability.Logger.Warn ~body:"warn" ());
  logger#log (record ~level:Eta_observability.Logger.Fatal ~body:"fatal" ());
  let logs = Eta_observability.Logger.dump memory in
  Alcotest.(check int) "kept records" 2 (List.length logs);
  Alcotest.(check string) "first kept" "warn" (List.nth logs 0).Eta_observability.Logger.body;
  Alcotest.(check string) "second kept" "fatal" (List.nth logs 1).Eta_observability.Logger.body

let test_logger_console_routes_and_filters () =
  let stdout = ref [] in
  let stderr = ref [] in
  let push target line = target := !target @ [ line ] in
  let logger =
    Eta_observability.Logger.console_logfmt ~stdout:(push stdout) ~stderr:(push stderr)
      ~min_level:Eta_observability.Logger.Warn ()
  in
  logger#log (record ~level:Eta_observability.Logger.Info ~body:"drop" ());
  logger#log (record ~level:Eta_observability.Logger.Warn ~body:"keep stdout" ());
  logger#log (record ~level:Eta_observability.Logger.Error ~body:"keep stderr" ());
  logger#log (record ~level:Eta_observability.Logger.Fatal ~body:"fatal stderr" ());
  Alcotest.(check (list string)) "stdout"
    [ "timestamp_ms=1234 level=warn msg=\"keep stdout\"" ]
    !stdout;
  Alcotest.(check (list string)) "stderr"
    [
      "timestamp_ms=1234 level=error msg=\"keep stderr\"";
      "timestamp_ms=1234 level=fatal msg=\"fatal stderr\"";
    ]
    !stderr

let tests =
  [
    ( "Logger",
      [
        Alcotest.test_case "formatters" `Quick test_logger_formatters;
        Alcotest.test_case "json escapes values" `Quick
          test_logger_json_escapes_values;
        Alcotest.test_case "logfmt rejects invalid labels" `Quick
          test_logger_logfmt_rejects_invalid_labels;
        Alcotest.test_case "with_min_level" `Quick test_logger_with_min_level;
        Alcotest.test_case "console routes and filters" `Quick
          test_logger_console_routes_and_filters;
      ] );
  ]
