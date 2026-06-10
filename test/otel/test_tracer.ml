open Eta

let with_otlp_runtime ~host ~port f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Support.create_exporter ~sw ~net ~clock ~host ~port
      ~service_name:"eta-otel-test-tracer"
      ~on_error:(fun msg -> prerr_endline ("[itest] " ^ msg))
      ()
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) ()
  in
  f rt exporter

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let motel_reachable () =
  try
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net
      (fun _ -> ());
    let _ = sw in
    true
  with _ -> false

let test_with_span_context_otlp () =
  if not (motel_reachable ()) then print_endline "[skip] motel not reachable"
  else
    with_otlp_runtime ~host:"127.0.0.1" ~port:27686 @@ fun rt exporter ->
    let parent_trace = "abcdef0123456789abcdef0123456789" in
    let parent_span = "1122334455667788" in
    let program =
      Effect.with_external_parent ~trace_id:parent_trace ~span_id:parent_span
        (Effect.named "external-child" Effect.unit)
    in
    ignore (run_ok rt program : unit);
    Eta_otel.flush exporter

let suite =
  ( "Tracer",
    [
      Alcotest.test_case "withSpanContext OTLP live" `Quick
        test_with_span_context_otlp;
    ] )
