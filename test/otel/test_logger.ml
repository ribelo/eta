open Eta

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

let test_log_otlp_live () =
  if not (motel_reachable ()) then print_endline "[skip] motel not reachable"
  else
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    let clock = Eio.Stdenv.clock stdenv in
    let exporter =
      Support.create_exporter ~sw ~net ~clock ~host:"127.0.0.1" ~port:27686
        ~service_name:"eta-otel-test-logger"
        ~on_error:(fun msg -> prerr_endline ("[itest] " ^ msg))
        ()
    in
    let rt =
      Eta_eio.Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter)
        ~logger:(Eta_otel.logger exporter) ()
    in
    let program =
      Effect.named "parent"
        (Effect.log "hello from inside parent"
        |> Effect.bind (fun () -> Effect.log "still inside"))
    in
    ignore (Runtime.run rt program : (unit, 'err) Exit.t);
    Eta_otel.flush exporter

let suite =
  ( "Logger",
    [ Alcotest.test_case "log OTLP live" `Quick test_log_otlp_live ] )
