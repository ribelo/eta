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

let metric_names body =
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc fields -> (
      match List.assoc "resourceMetrics" fields with
      | `List [ `Assoc rm_fields ] -> (
          match List.assoc "scopeMetrics" rm_fields with
          | `List [ `Assoc sm_fields ] -> (
              match List.assoc "metrics" sm_fields with
              | `List metrics ->
                  List.filter_map
                    (function
                      | `Assoc fields -> (
                          match List.assoc "name" fields with
                          | `String name -> Some name
                          | _ -> None)
                      | _ -> None)
                    metrics
              | _ -> [])
          | _ -> [])
      | _ -> [])
  | _ -> []

let test_metrics_otlp_live () =
  if not (motel_reachable ()) then print_endline "[skip] motel not reachable"
  else
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    let clock = Eio.Stdenv.clock stdenv in
    let captured = ref [] in
    let exporter =
      Support.create_exporter ~sw ~net ~clock ~host:"127.0.0.1" ~port:27686
        ~service_name:"eta-otel-test-meter" ~on_error:(fun _ -> ())
        ~on_send:(fun ~path ~body -> captured := (path, body) :: !captured)
        ()
    in
    let rt =
      Eta_eio.Runtime.create ~sw ~clock ~meter:(Eta_otel.meter exporter) ()
    in
    let program =
      Effect.bind
        (fun () ->
          Effect.bind
            (fun () ->
              Effect.metric_update ~name:"eta.demo.gauge"
                ~kind:Capabilities.Gauge (Capabilities.Float 1.5))
            (Effect.metric_update ~name:"eta.demo.counter" ~description:"demo"
               ~kind:Capabilities.Counter_monotonic (Capabilities.Int 1)))
        (Effect.metric_update ~name:"eta.demo.counter" ~description:"demo"
           ~kind:Capabilities.Counter_monotonic (Capabilities.Int 1))
    in
    ignore (Runtime.run rt program : (unit, 'err) Exit.t);
    Eta_otel.flush exporter;
    let metrics_sends =
      List.filter (fun (path, _) -> String.equal path "/v1/metrics") !captured
    in
    Alcotest.(check bool) "at least one metrics POST" true
      (metrics_sends <> []);
    let names =
      List.concat_map (fun (_, body) -> metric_names body) metrics_sends
    in
    Alcotest.(check bool) "counter metric exported" true
      (List.exists (String.equal "eta.demo.counter") names);
    Alcotest.(check bool) "gauge metric exported" true
      (List.exists (String.equal "eta.demo.gauge") names)

let suite =
  ( "Metrics",
    [ Alcotest.test_case "metrics OTLP live" `Quick test_metrics_otlp_live ] )
