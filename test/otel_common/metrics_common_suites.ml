(* Port of @eff/opentelemetry/test/Metrics.test.ts.

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

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

let with_meter f =
  B.with_meter_runtime (fun _ctx rt meter -> f rt meter)

let counter ?(description = "") ?(unit_ = "") ~name ?(monotonic = false) value =
  Effect.metric_update ~name
    ~kind:(if monotonic then Capabilities.Counter_monotonic
           else Capabilities.Counter_cumulative)
    ~description ~unit_ value

let gauge ?(description = "") ?(unit_ = "") ?(attrs = []) ~name value =
  Effect.metric_update ~name ~kind:Capabilities.Gauge ~description ~unit_
    ~attrs value

(* ------------------------------------------------------------------ *)
(* Mirrors `it.eff("gauge", ...)`. *)
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
  let _ = B.run rt prog in
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
(* Mirrors `it.eff("counter", ...)`. *)
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
  let _ = B.run rt prog in
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
  let _ = B.run rt prog in
  match Eta_otel.aggregate_points (Meter.dump meter) with
  | [ (_key, (value, _, _)) ] ->
      Alcotest.check metric_value "latest cumulative value"
        (Capabilities.Int 15) value
  | points ->
      Alcotest.failf "expected one aggregated point, got %d"
        (List.length points)

(* ------------------------------------------------------------------ *)
(* Mirrors `it.eff("counter-inc", ...)`. *)
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
  let _ = B.run rt prog in
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

let metric_point ~name ~kind value : Meter.point =
  {
    name;
    description = "";
    unit_ = "";
    kind;
    attrs = [];
    value;
    ts_ms = 1;
  }

let metrics_json body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc "resourceMetrics" fields with
      | `List [ `Assoc rm_fields ] -> (
          match List.assoc "scopeMetrics" rm_fields with
          | `List [ `Assoc sm_fields ] -> (
              match List.assoc "metrics" sm_fields with
              | `List metrics -> metrics
              | _ -> [])
          | _ -> [])
      | _ -> [])
  | _ -> []

let metric_temporality name body =
  metrics_json body
  |> List.find_map (function
       | `Assoc fields -> (
           match (List.assoc_opt "name" fields, List.assoc_opt "sum" fields) with
           | Some (`String metric_name), Some (`Assoc sum_fields)
             when String.equal metric_name name -> (
               match List.assoc_opt "aggregationTemporality" sum_fields with
               | Some (`Int value) -> Some value
               | _ -> None)
           | _ -> None)
       | _ -> None)

let test_counter_temporality_json () =
  let body =
    Eta_otel.Internal.encode_metrics_request ~resource_attrs:[] ~scope_name:"test"
      [
        metric_point ~name:"cumulative"
          ~kind:Capabilities.Counter_cumulative (Capabilities.Int 42);
        metric_point ~name:"delta"
          ~kind:Capabilities.Counter_monotonic (Capabilities.Int 2);
      ]
  in
  Alcotest.(check (option int)) "cumulative temporality" (Some 2)
    (metric_temporality "cumulative" body);
  Alcotest.(check (option int)) "monotonic delta temporality" (Some 1)
    (metric_temporality "delta" body)

let rec json_contains_negative_as_int = function
  | `Assoc fields ->
      List.exists
        (function
          | "asInt", `String s -> String.length s > 0 && Char.equal s.[0] '-'
          | _, value -> json_contains_negative_as_int value)
        fields
  | `List values -> List.exists json_contains_negative_as_int values
  | _ -> false

let test_monotonic_counter_aggregation_does_not_overflow_negative () =
  let p value =
    metric_point ~name:"eta.test.overflowing_counter"
      ~kind:Capabilities.Counter_monotonic (Capabilities.Int value)
  in
  let body =
    Eta_otel.Internal.encode_metrics_request ~resource_attrs:[]
      ~scope_name:"eta-otel-test"
      [ p (max_int - 1); p 3 ]
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check bool)
    "monotonic counter did not wrap negative" false
    (json_contains_negative_as_int json)

let rec json_contains_negative_time = function
  | `Assoc fields ->
      List.exists
        (function
          | ( ("timeUnixNano" | "startTimeUnixNano" | "observedTimeUnixNano"),
              `String s ) ->
              String.length s > 0 && Char.equal s.[0] '-'
          | _, value -> json_contains_negative_time value)
        fields
  | `List values -> List.exists json_contains_negative_time values
  | _ -> false

let test_metric_timestamp_conversion_does_not_wrap_negative () =
  let point : Meter.point =
    {
      name = "eta.test.timestamp";
      description = "timestamp overflow regression";
      unit_ = "1";
      kind = Capabilities.Gauge;
      attrs = [];
      value = Capabilities.Int 1;
      ts_ms = (max_int / 1_000_000) + 1;
    }
  in
  let body =
    Eta_otel.Internal.encode_metrics_request ~resource_attrs:[]
      ~scope_name:"eta-otel-test" [ point ]
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check bool)
    "timestamp did not wrap negative" false
    (json_contains_negative_time json)

let suite =
  ( "Metrics",
    [
      Alcotest.test_case "gauge" `Quick test_gauge;
      Alcotest.test_case "counter cumulative" `Quick test_counter;
      Alcotest.test_case "counter cumulative keeps latest" `Quick
        test_counter_cumulative_keeps_latest_value;
      Alcotest.test_case "counter monotonic" `Quick test_counter_monotonic;
      Alcotest.test_case "counter temporality JSON" `Quick
        test_counter_temporality_json;
      Alcotest.test_case "monotonic counter aggregation no negative overflow"
        `Quick test_monotonic_counter_aggregation_does_not_overflow_negative;
      Alcotest.test_case "metric timestamp conversion no negative wrap" `Quick
        test_metric_timestamp_conversion_does_not_wrap_negative;
    ] )
end
