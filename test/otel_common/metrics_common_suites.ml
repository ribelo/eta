open Eta

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let with_meter f = B.with_meter_runtime (fun _ctx rt meter -> f rt meter)

  let number_pp fmt = function
    | Capabilities.Int n -> Format.fprintf fmt "Int %d" n
    | Capabilities.Float f -> Format.fprintf fmt "Float %g" f

  let number_eq a b =
    match (a, b) with
    | Capabilities.Int a, Capabilities.Int b -> a = b
    | Capabilities.Float a, Capabilities.Float b -> a = b
    | _ -> false

  let number = Alcotest.testable number_pp number_eq

  let run_ok_unit rt eff =
    match B.run rt eff with
    | Exit.Ok () -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected success, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<hidden>"))
          cause

  let metric_point ?(description = "") ?(unit_ = "") ?(attrs = []) ~name ~kind
      value : Meter.point =
    { name; description; unit_; kind; attrs; value; ts_ms = 1 }

  let only_aggregate points =
    match Eta_otel.aggregate_points points with
    | [ point ] -> point
    | points -> Alcotest.failf "expected one aggregate, got %d" (List.length points)

  let test_gauge_keeps_latest_value () =
    with_meter @@ fun rt meter ->
    run_ok_unit rt
      (Effect.concat
         [
           Effect.metric_gauge ~name:"rps" (Capabilities.Int 10);
           Effect.metric_gauge ~name:"rps" (Capabilities.Int 20);
         ]);
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Gauge value ->
        Alcotest.check number "latest value" (Capabilities.Int 20) value
    | _ -> Alcotest.fail "expected gauge aggregate"

  let test_counter_cumulative_keeps_latest_value () =
    with_meter @@ fun rt meter ->
    run_ok_unit rt
      (Effect.concat
         [
           Effect.metric_counter ~name:"cumulative" (Capabilities.Int 10);
           Effect.metric_counter ~name:"cumulative" (Capabilities.Int 15);
         ]);
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Sum value ->
        Alcotest.check number "latest cumulative value" (Capabilities.Int 15) value
    | _ -> Alcotest.fail "expected sum aggregate"

  let test_counter_monotonic_sums_increments () =
    with_meter @@ fun rt meter ->
    run_ok_unit rt
      (Effect.concat
         [
           Effect.metric_counter ~name:"counter-inc" ~monotonic:true
             (Capabilities.Int 1);
           Effect.metric_counter ~name:"counter-inc" ~monotonic:true
             (Capabilities.Int 1);
         ]);
    let key, (value, _, _) = only_aggregate (Meter.dump meter) in
    Alcotest.(check string) "name" "counter-inc" key.Eta_otel.Metric_key.name;
    (match key.kind with
    | Capabilities.Counter { monotonic = true } -> ()
    | _ -> Alcotest.fail "expected monotonic counter");
    match value with
    | Eta_otel.Sum value ->
        Alcotest.check number "summed value" (Capabilities.Int 2) value
    | _ -> Alcotest.fail "expected sum aggregate"

  let test_frequency_counts_categories () =
    with_meter @@ fun rt meter ->
    run_ok_unit rt
      (Effect.concat
         [
           Effect.metric_frequency ~name:"status" "ok";
           Effect.metric_frequency ~name:"status" "error";
           Effect.metric_frequency ~name:"status" "ok";
         ]);
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Frequency counts ->
        Alcotest.(check (list (pair string int)))
          "category counts" [ ("error", 1); ("ok", 2) ] counts
    | _ -> Alcotest.fail "expected frequency aggregate"

  let test_histogram_aggregates_explicit_buckets () =
    with_meter @@ fun rt meter ->
    run_ok_unit rt
      (Effect.concat
         [
           Effect.metric_histogram ~name:"latency" ~boundaries:[ 10.0; 20.0 ] 5.0;
           Effect.metric_histogram ~name:"latency" ~boundaries:[ 10.0; 20.0 ] 15.0;
           Effect.metric_histogram ~name:"latency" ~boundaries:[ 10.0; 20.0 ] 25.0;
         ]);
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Histogram state ->
        Alcotest.(check int) "count" 3 state.count;
        Alcotest.(check (float 0.001)) "sum" 45.0 state.sum;
        Alcotest.(check (option (float 0.001))) "min" (Some 5.0) state.min;
        Alcotest.(check (option (float 0.001))) "max" (Some 25.0) state.max;
        Alcotest.(check (list (pair (float 0.001) int)))
          "buckets" [ (10.0, 1); (20.0, 1); (infinity, 1) ] state.buckets
    | _ -> Alcotest.fail "expected histogram aggregate"

  let test_summary_computes_quantiles () =
    with_meter @@ fun rt meter ->
    let sample value =
      Effect.metric_summary ~name:"payload" ~quantiles:[ 0.5; 1.0 ]
        ~max_age:(Duration.seconds 60) ~max_size:10 value
    in
    run_ok_unit rt (Effect.concat [ sample 1.0; sample 3.0; sample 5.0 ]);
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Summary state ->
        Alcotest.(check int) "count" 3 state.count;
        Alcotest.(check (float 0.001)) "sum" 9.0 state.sum;
        Alcotest.(check (option (float 0.001))) "min" (Some 1.0) state.min;
        Alcotest.(check (option (float 0.001))) "max" (Some 5.0) state.max;
        Alcotest.(check (list (pair (float 0.001) (float 0.001))))
          "quantiles" [ (0.5, 3.0); (1.0, 5.0) ] state.quantiles
    | _ -> Alcotest.fail "expected summary aggregate"

  let test_timer_records_elapsed_histogram_on_failure () =
    B.with_meter_test_clock @@ fun _ctx clock rt meter ->
    let program =
      Effect.metric_timer ~name:"operation.duration" ~boundaries:[ 10.0; 30.0 ]
        (Effect.sync (fun () -> B.adjust_clock clock (Duration.ms 25))
        |> Effect.bind (fun () -> Effect.fail `Boom))
    in
    (match B.run rt program with
    | Exit.Error (Cause.Fail `Boom) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
          cause
    | Exit.Ok _ -> Alcotest.fail "expected typed failure");
    let _key, (value, _, _) = only_aggregate (Meter.dump meter) in
    match value with
    | Eta_otel.Histogram state ->
        Alcotest.(check int) "timer count" 1 state.count;
        Alcotest.(check (float 0.001)) "timer elapsed" 25.0 state.sum
    | _ -> Alcotest.fail "expected timer histogram"

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

  let find_metric name body =
    metrics_json body
    |> List.find_opt (function
         | `Assoc fields -> (
             match List.assoc_opt "name" fields with
             | Some (`String metric_name) -> String.equal metric_name name
             | _ -> false)
         | _ -> false)

  let test_counter_temporality_json () =
    let body =
      Eta_otel.Internal.encode_metrics_request ~resource_attrs:[] ~scope_name:"test"
        [
          metric_point ~name:"cumulative"
            ~kind:(Capabilities.Counter { monotonic = false })
            (Capabilities.Number (Capabilities.Int 42));
          metric_point ~name:"delta"
            ~kind:(Capabilities.Counter { monotonic = true })
            (Capabilities.Number (Capabilities.Int 2));
        ]
    in
    let temporality name =
      Option.bind (find_metric name body) (function
           | `Assoc fields -> (
               match List.assoc_opt "sum" fields with
               | Some (`Assoc sum_fields) -> (
                   match List.assoc_opt "aggregationTemporality" sum_fields with
                   | Some (`Int value) -> Some value
                   | _ -> None)
               | _ -> None)
           | _ -> None)
    in
    Alcotest.(check (option int)) "cumulative temporality" (Some 2)
      (temporality "cumulative");
    Alcotest.(check (option int)) "monotonic delta temporality" (Some 1)
      (temporality "delta")

  let test_distribution_json_shapes () =
    let body =
      Eta_otel.Internal.encode_metrics_request ~resource_attrs:[] ~scope_name:"test"
        [
          metric_point ~name:"freq" ~kind:Capabilities.Frequency
            (Capabilities.Category "ok");
          metric_point ~name:"freq" ~kind:Capabilities.Frequency
            (Capabilities.Category "ok");
          metric_point ~name:"hist"
            ~kind:(Capabilities.Histogram { boundaries = [ 10.0 ] })
            (Capabilities.Number (Capabilities.Float 5.0));
          metric_point ~name:"sum"
            ~kind:
              (Capabilities.Summary
                 {
                   quantiles = [ 0.5 ];
                   max_age = Duration.seconds 60;
                   max_size = 10;
                 })
            (Capabilities.Number (Capabilities.Float 7.0));
        ]
    in
    let has_field name field =
      match find_metric name body with
      | Some (`Assoc fields) -> List.mem_assoc field fields
      | _ -> false
    in
    Alcotest.(check bool) "frequency gauge" true (has_field "freq" "gauge");
    Alcotest.(check bool) "histogram field" true (has_field "hist" "histogram");
    Alcotest.(check bool) "summary field" true (has_field "sum" "summary")

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
        ~kind:(Capabilities.Counter { monotonic = true })
        (Capabilities.Number (Capabilities.Int value))
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
        value = Capabilities.Number (Capabilities.Int 1);
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
        Alcotest.test_case "gauge latest" `Quick test_gauge_keeps_latest_value;
        Alcotest.test_case "counter cumulative latest" `Quick
          test_counter_cumulative_keeps_latest_value;
        Alcotest.test_case "counter monotonic sums" `Quick
          test_counter_monotonic_sums_increments;
        Alcotest.test_case "frequency counts categories" `Quick
          test_frequency_counts_categories;
        Alcotest.test_case "histogram explicit buckets" `Quick
          test_histogram_aggregates_explicit_buckets;
        Alcotest.test_case "summary quantiles" `Quick
          test_summary_computes_quantiles;
        Alcotest.test_case "timer records elapsed histogram" `Quick
          test_timer_records_elapsed_histogram_on_failure;
        Alcotest.test_case "counter temporality JSON" `Quick
          test_counter_temporality_json;
        Alcotest.test_case "distribution JSON shapes" `Quick
          test_distribution_json_shapes;
        Alcotest.test_case "monotonic counter aggregation no negative overflow"
          `Quick test_monotonic_counter_aggregation_does_not_overflow_negative;
        Alcotest.test_case "metric timestamp conversion no negative wrap" `Quick
          test_metric_timestamp_conversion_does_not_wrap_negative;
      ] )
end
