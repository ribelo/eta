(* Port of @effect/opentelemetry/test/Metrics.test.ts.

   The Effect-TS test exercises gauges and counters (cumulative + monotonic,
   double + bigint), then collects via MetricProducerImpl and asserts on
   OTel ResourceMetrics shapes.

   Eta's equivalent: Capabilities.meter trait, Eta.Metric_update AST,
   Meter.in_memory + Eta_otel.meter for live OTLP. The test here uses
   Meter.in_memory and asserts on the aggregated points produced via
   Eta_otel.aggregate_points (the same function the OTLP encoder uses,
   so test and live agree).

   We do not replicate the bigint vs double type distinction at the API
   surface — Capabilities.metric_value is a sum type [Int of int | Float
   of float] and OTLP encodes them as asInt / asDouble respectively. *)

open Eta

let with_meter f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Meter.in_memory () in
  let rt =
    Runtime.create ~sw
      ~clock:(Eio.Stdenv.clock stdenv)
      ~meter:(Meter.as_capability meter) ()
  in
  f rt meter

let counter ?(description = "") ?(unit_ = "") ~name ?(monotonic = false) value =
  Effect.metric_update ~name
    ~kind:(if monotonic then Capabilities.Counter_monotonic
           else Capabilities.Counter_cumulative)
    ~description ~unit_ value

let gauge ?(description = "") ?(unit_ = "") ?(attrs = []) ~name value =
  Effect.metric_update ~name ~kind:Capabilities.Gauge ~description ~unit_
    ~attrs value

(* ------------------------------------------------------------------ *)
(* Mirrors `it.effect("gauge", ...)`. *)
(* ------------------------------------------------------------------ *)

let metric_value_pp fmt = function
  | Capabilities.Int n -> Format.fprintf fmt "Int %d" n
  | Capabilities.Float f -> Format.fprintf fmt "Float %g" f

let metric_value_eq a b =
  match (a, b) with
  | Capabilities.Int a, Capabilities.Int b -> a = b
  | Capabilities.Float a, Capabilities.Float b -> a = b
  | _ -> false

let metric_value = Alcotest.testable metric_value_pp metric_value_eq

let test_gauge () =
  with_meter @@ fun rt meter ->
  let prog =
    Effect.bind
      (fun () ->
        Effect.bind
          (fun () ->
            gauge ~name:"rps"
              ~attrs:[ ("key", "value") ]
              (Capabilities.Int 20))
          (gauge ~name:"rps" ~attrs:[ ("key", "value") ] (Capabilities.Int 10)))
      (gauge ~name:"rps"
         ~attrs:[ ("key", "value"); ("unit", "requests") ]
         ~unit_:"requests" (Capabilities.Int 10))
  in
  let _ = Runtime.run rt prog in
  let aggregated = Meter.dump meter in
  Alcotest.(check int) "three updates" 3 (List.length aggregated);
  let agg = Eta_otel.aggregate_points aggregated in
  Alcotest.(check int) "two distinct attribute sets" 2 (List.length agg);
  let by_attrs target =
    List.find
      (fun (k, _) ->
        let module Mk = Eta_otel.Metric_key in
        List.sort compare k.Mk.attrs = List.sort compare target)
      agg
  in
  let _, (v1, _, _) = by_attrs [ ("key", "value"); ("unit", "requests") ] in
  let _, (v2, _, _) = by_attrs [ ("key", "value") ] in
  Alcotest.check metric_value "first set retains 10" (Capabilities.Int 10) v1;
  Alcotest.check metric_value "second set has latest write 20"
    (Capabilities.Int 20) v2

(* ------------------------------------------------------------------ *)
(* Mirrors `it.effect("counter", ...)`. *)
(* ------------------------------------------------------------------ *)
let test_counter () =
  with_meter @@ fun rt meter ->
  let prog =
    Effect.bind
      (fun () ->
        Effect.bind
          (fun () ->
            counter ~name:"counter" ~description:"Example"
              (Capabilities.Int 1))
          (counter ~name:"counter" ~description:"Example"
             (Capabilities.Int 1)))
      (Effect.metric_update ~name:"counter" ~description:"Example"
         ~unit_:"requests" ~kind:Capabilities.Counter_cumulative
         ~attrs:[ ("key", "value"); ("unit", "requests") ]
         (Capabilities.Int 1))
  in
  let _ = Runtime.run rt prog in
  let agg = Eta_otel.aggregate_points (Meter.dump meter) in
  Alcotest.(check int) "two distinct attribute sets" 2 (List.length agg)

let test_counter_cumulative_keeps_latest_value () =
  with_meter @@ fun rt meter ->
  let prog =
    Effect.concat
      [
        counter ~name:"cumulative" (Capabilities.Int 10);
        counter ~name:"cumulative" (Capabilities.Int 12);
        counter ~name:"cumulative" (Capabilities.Int 15);
      ]
  in
  let _ = Runtime.run rt prog in
  match Eta_otel.aggregate_points (Meter.dump meter) with
  | [ (_key, (value, _, _)) ] ->
      Alcotest.check metric_value "latest cumulative value"
        (Capabilities.Int 15) value
  | points ->
      Alcotest.failf "expected one aggregated point, got %d"
        (List.length points)

(* ------------------------------------------------------------------ *)
(* Mirrors `it.effect("counter-inc", ...)`. *)
(* ------------------------------------------------------------------ *)
let test_counter_monotonic () =
  with_meter @@ fun rt meter ->
  let prog =
    Effect.bind
      (fun () ->
        counter ~name:"counter-inc" ~description:"Example" ~monotonic:true
          (Capabilities.Int 1))
      (counter ~name:"counter-inc" ~description:"Example" ~monotonic:true
         (Capabilities.Int 1))
  in
  let _ = Runtime.run rt prog in
  let agg = Eta_otel.aggregate_points (Meter.dump meter) in
  match agg with
  | [ (key, (value, _, _)) ] ->
      Alcotest.(check string) "monotonic counter name" "counter-inc"
        key.Eta_otel.Metric_key.name;
      (match key.kind with
      | Capabilities.Counter_monotonic -> ()
      | _ -> Alcotest.fail "expected monotonic counter");
      Alcotest.check metric_value "summed value" (Capabilities.Int 2) value
  | _ -> Alcotest.failf "expected one aggregated point, got %d" (List.length agg)

(* ------------------------------------------------------------------ *)
(* Live OTLP integration. *)
(* ------------------------------------------------------------------ *)
let motel_reachable () =
  try
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
        ());
    let _ = sw in
    true
  with _ -> false

let test_metrics_otlp_live () =
  if not (motel_reachable ()) then
    print_endline "[skip] motel not reachable"
  else
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    let clock = Eio.Stdenv.clock stdenv in
    let captured = ref [] in
    let exporter =
      Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port:27686
        ~service_name:"eta-otel-test-meter"
        ~on_error:(fun _ -> ())
        ~on_send:(fun ~path ~body -> captured := (path, body) :: !captured)
        ()
    in
    let rt =
      Runtime.create ~sw ~clock
        ~meter:(Eta_otel.meter exporter) ()
    in
    let prog =
      Effect.bind
        (fun () ->
          Effect.bind
            (fun () ->
              Effect.metric_update ~name:"eta.demo.gauge"
                ~kind:Capabilities.Gauge (Capabilities.Float 1.5))
            (Effect.metric_update ~name:"eta.demo.counter" ~description:"demo"
               ~kind:Capabilities.Counter_monotonic
               (Capabilities.Int 1)))
        (Effect.metric_update ~name:"eta.demo.counter" ~description:"demo"
           ~kind:Capabilities.Counter_monotonic
           (Capabilities.Int 1))
    in
    let _ = Runtime.run rt prog in
    Eta_otel.flush exporter;
    (* Verify the exporter sent an OTLP/JSON metrics payload to /v1/metrics. *)
    let metrics_sends =
      List.filter (fun (path, _) -> path = "/v1/metrics") !captured
    in
    Alcotest.(check bool) "at least one metrics POST" true
      (metrics_sends <> []);
    let _, body = List.hd metrics_sends in
    let json = Yojson.Safe.from_string body in
    let names =
      match json with
      | `Assoc fields -> (
          match List.assoc "resourceMetrics" fields with
          | `List [ rm ] -> (
              match rm with
              | `Assoc rm_fields -> (
                  match List.assoc "scopeMetrics" rm_fields with
                  | `List [ sm ] -> (
                      match sm with
                      | `Assoc sm_fields -> (
                          match List.assoc "metrics" sm_fields with
                          | `List metrics ->
                              List.map
                                (fun m ->
                                  match m with
                                  | `Assoc fs -> (
                                      match List.assoc "name" fs with
                                      | `String n -> n
                                      | _ -> "")
                                  | _ -> "")
                                metrics
                          | _ -> [])
                      | _ -> [])
                  | _ -> [])
              | _ -> [])
          | _ -> [])
      | _ -> []
    in
    Alcotest.(check bool) "counter metric exported" true
      (List.exists (String.equal "eta.demo.counter") names);
    Alcotest.(check bool) "gauge metric exported" true
      (List.exists (String.equal "eta.demo.gauge") names)

let suite =
  ( "Metrics",
    [
      Alcotest.test_case "gauge" `Quick test_gauge;
      Alcotest.test_case "counter cumulative" `Quick test_counter;
      Alcotest.test_case "counter cumulative keeps latest" `Quick
        test_counter_cumulative_keeps_latest_value;
      Alcotest.test_case "counter monotonic" `Quick test_counter_monotonic;
      Alcotest.test_case "metrics OTLP live" `Quick test_metrics_otlp_live;
    ] )
