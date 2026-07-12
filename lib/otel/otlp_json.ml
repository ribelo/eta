type yj = Yojson.Safe.t

let array_map (f) values =
  let rec loop acc = function
    | [] -> `List (List.rev acc)
    | value :: rest -> loop (f value :: acc) rest
  in
  loop [] values

let attr_value_string s : yj = `Assoc [ ("stringValue", `String s) ]

let attrs_json (attrs : (string * string) list) : yj =
  array_map
    (fun (k, v) ->
      `Assoc [ ("key", `String k); ("value", attr_value_string v) ])
    attrs

let str_int n = `String (string_of_int n)

type span = {
  trace_id : string;
  span_id : string;
  parent_span_id : string option;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
  name : string;
  kind : Eta.Capabilities.span_kind;
  start_unix_ns : int;
  mutable end_unix_ns : int;
  mutable attrs : (string * string) list;
  mutable events : (string * int * (string * string) list) list;
  mutable links : Eta.Capabilities.span_link list;
  mutable status_code : int;
  mutable status_message : string;
}

let event_json (name, ts_ns, attrs) : yj =
  `Assoc
    [
      ("name", `String name);
      ("timeUnixNano", str_int ts_ns);
      ("attributes", attrs_json attrs);
    ]

let link_json (l : Eta.Capabilities.span_link) : yj =
  let fields =
    match l.link_attrs with
    | [] ->
        [
          ("traceId", `String l.link_trace_id);
          ("spanId", `String l.link_span_id);
        ]
    | attrs ->
        [
          ("traceId", `String l.link_trace_id);
          ("spanId", `String l.link_span_id);
          ("attributes", attrs_json attrs);
        ]
  in
  `Assoc fields

let status_json code message : yj option =
  if code = 0 then None
  else if message = "" then Some (`Assoc [ ("code", `Int code) ])
  else
    Some (`Assoc [ ("code", `Int code); ("message", `String message) ])

let span_kind_int = function
  | Eta.Capabilities.Internal -> 1
  | Server -> 2
  | Client -> 3
  | Producer -> 4
  | Consumer -> 5

let span_json (s : span) : yj =
  let fields =
    match status_json s.status_code s.status_message with
    | None -> []
    | Some j -> [ ("status", j) ]
  in
  let fields =
    match s.links with
    | [] -> fields
    | links -> ("links", array_map link_json links) :: fields
  in
  let fields =
    match s.events with
    | [] -> fields
    | events -> ("events", array_map event_json events) :: fields
  in
  let fields =
    match s.trace_state with
    | [] -> fields
    | xs ->
        ( "traceState",
          `String (String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) xs))
        )
        :: fields
  in
  let fields =
    ("attributes", attrs_json s.attrs)
    :: ("endTimeUnixNano", str_int s.end_unix_ns)
    :: ("startTimeUnixNano", str_int s.start_unix_ns)
    :: ("kind", `Int (span_kind_int s.kind))
    :: ("name", `String s.name)
    :: fields
  in
  let fields =
    match s.parent_span_id with
    | Some p -> ("parentSpanId", `String p) :: fields
    | None -> fields
  in
  `Assoc
    (("traceId", `String s.trace_id) :: ("spanId", `String s.span_id)
    :: fields)

let resource_json resource_attrs : yj =
  `Assoc [ ("attributes", attrs_json resource_attrs) ]

let scope_json scope_name : yj = `Assoc [ ("name", `String scope_name) ]

let encode_otlp_request ~resource_attrs ~scope_name ~wrapper_key ~scope_key
    ~records_key encode_item items =
  let payload : yj =
    `Assoc
      [
        ( wrapper_key,
          `List
            [
              `Assoc
                [
                  ("resource", resource_json resource_attrs);
                  ( scope_key,
                    `List
                      [
                        `Assoc
                          [
                            ("scope", scope_json scope_name);
                            (records_key, array_map encode_item items);
                          ];
                      ] );
                ];
            ] );
      ]
  in
  Yojson.Safe.to_string payload

let encode_traces_request ~resource_attrs ~scope_name spans =
  encode_otlp_request ~resource_attrs ~scope_name ~wrapper_key:"resourceSpans"
    ~scope_key:"scopeSpans" ~records_key:"spans" span_json spans

let severity_number = function
  | Eta.Capabilities.Trace -> 1
  | Debug -> 5
  | Info -> 9
  | Warn -> 13
  | Error -> 17
  | Fatal -> 21

let severity_text = function
  | Eta.Capabilities.Trace -> "TRACE"
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
  | Fatal -> "FATAL"

let log_json (r : Eta.Capabilities.log_record) : yj =
  let ts_ns = Metric_aggregation.ms_to_ns_saturating r.ts_ms in
  let fields =
    if r.span_id = "" then [] else [ ("spanId", `String r.span_id) ]
  in
  let fields =
    if r.trace_id = "" then fields else ("traceId", `String r.trace_id) :: fields
  in
  `Assoc
    (("timeUnixNano", str_int ts_ns)
    :: ("observedTimeUnixNano", str_int ts_ns)
    :: ("severityNumber", `Int (severity_number r.level))
    :: ("severityText", `String (severity_text r.level))
    :: ("body", `Assoc [ ("stringValue", `String r.body) ])
    :: ("attributes", attrs_json r.attrs)
    :: fields)

let encode_logs_request ~resource_attrs ~scope_name records =
  encode_otlp_request ~resource_attrs ~scope_name ~wrapper_key:"resourceLogs"
    ~scope_key:"scopeLogs" ~records_key:"logRecords" log_json records

module Metric_aggregation = Metric_aggregation
module Metric_key = Metric_aggregation.Metric_key

let value_field (v : Eta.Capabilities.metric_number) =
  match v with
  | Int n -> ("asInt", `String (string_of_int n))
  | Float f -> ("asDouble", `Float f)

let number_data_point_json (key : Metric_key.t) value start_ts end_ts : yj =
  `Assoc
    [
      ("attributes", attrs_json key.attrs);
      ("startTimeUnixNano", str_int start_ts);
      ("timeUnixNano", str_int end_ts);
      value_field value;
    ]

let number_data_points_json key value start_ts end_ts =
  `List [ number_data_point_json key value start_ts end_ts ]

let count_json count = `String (string_of_int count)

let finite_bound_json boundary = `Float boundary

let[@inline always] add_min_max fields ~min ~max =
  let fields =
    match min with None -> fields | Some value -> ("min", `Float value) :: fields
  in
  match max with
  | None -> fields
  | Some value -> ("max", `Float value) :: fields

let histogram_data_point_json key
    (state : Metric_aggregation.histogram_state) start_ts end_ts =
  let bounds, counts =
    List.fold_right
      (fun (boundary, count) (bounds, counts) ->
        let bounds = if boundary = infinity then bounds else boundary :: bounds in
        (bounds, count_json count :: counts))
      state.buckets ([], [])
  in
  let fields =
    [
      ("attributes", attrs_json key.Metric_key.attrs);
      ("startTimeUnixNano", str_int start_ts);
      ("timeUnixNano", str_int end_ts);
      ("count", count_json state.count);
      ("sum", `Float state.sum);
      ("bucketCounts", `List counts);
      ("explicitBounds", `List (List.map finite_bound_json bounds));
    ]
  in
  `Assoc (add_min_max fields ~min:state.min ~max:state.max)

let quantile_value_json (quantile, value) : yj =
  `Assoc [ ("quantile", `Float quantile); ("value", `Float value) ]

let summary_data_point_json key (state : Metric_aggregation.summary_state)
    start_ts end_ts =
  let fields =
    [
      ("attributes", attrs_json key.Metric_key.attrs);
      ("startTimeUnixNano", str_int start_ts);
      ("timeUnixNano", str_int end_ts);
      ("count", count_json state.count);
      ("sum", `Float state.sum);
      ("quantileValues", array_map quantile_value_json state.quantiles);
    ]
  in
  `Assoc (add_min_max fields ~min:state.min ~max:state.max)

let frequency_data_points_json key counts start_ts end_ts =
  counts
  |> array_map (fun (category, count) ->
         let attrs = ("value", category) :: key.Metric_key.attrs in
         `Assoc
           [
             ("attributes", attrs_json attrs);
             ("startTimeUnixNano", str_int start_ts);
             ("timeUnixNano", str_int end_ts);
             ("asInt", `String (string_of_int count));
           ])

let metric_json (key : Metric_key.t) point : yj =
  let value, start_ts, end_ts = point in
  let body : yj =
    match (key.kind, value) with
    | Gauge, Metric_aggregation.Gauge value ->
        `Assoc [ ("dataPoints", number_data_points_json key value start_ts end_ts) ]
    | Counter { monotonic = false }, Metric_aggregation.Sum value ->
        `Assoc
          [
            ("dataPoints", number_data_points_json key value start_ts end_ts);
            ("aggregationTemporality", `Int 2);
            ("isMonotonic", `Bool false);
          ]
    | Counter { monotonic = true }, Metric_aggregation.Sum value ->
        `Assoc
          [
            ("dataPoints", number_data_points_json key value start_ts end_ts);
            ("aggregationTemporality", `Int 1);
            ("isMonotonic", `Bool true);
          ]
    | Frequency, Metric_aggregation.Frequency counts ->
        `Assoc [ ("dataPoints", frequency_data_points_json key counts start_ts end_ts) ]
    | Histogram _, Metric_aggregation.Histogram state ->
        `Assoc
          [
            ("dataPoints", `List [ histogram_data_point_json key state start_ts end_ts ]);
            ("aggregationTemporality", `Int 1);
          ]
    | Summary _, Metric_aggregation.Summary state ->
        `Assoc [ ("dataPoints", `List [ summary_data_point_json key state start_ts end_ts ]) ]
    | _ -> invalid_arg "Otlp_json.metric_json: metric kind/value mismatch"
  in
  let kind_field =
    match key.kind with
    | Gauge -> "gauge"
    | Counter _ -> "sum"
    | Frequency -> "gauge"
    | Histogram _ -> "histogram"
    | Summary _ -> "summary"
  in
  `Assoc
    [
      ("name", `String key.name);
      ("description", `String key.description);
      ("unit", `String key.unit_);
      (kind_field, body);
    ]

let encode_metrics_request ~resource_attrs ~scope_name points =
  let aggregated = Metric_aggregation.aggregate_points points in
  encode_otlp_request ~resource_attrs ~scope_name ~wrapper_key:"resourceMetrics"
    ~scope_key:"scopeMetrics" ~records_key:"metrics"
    (fun (k, v) -> metric_json k v) aggregated
