type yj = Yojson.Safe.t

let attr_value_string s : yj = `Assoc [ ("stringValue", `String s) ]

let attrs_json (attrs : (string * string) list) : yj =
  `List
    (List.map
       (fun (k, v) ->
         `Assoc [ ("key", `String k); ("value", attr_value_string v) ])
       attrs)

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
  let base =
    [
      ("traceId", `String l.link_trace_id);
      ("spanId", `String l.link_span_id);
    ]
  in
  let with_attrs =
    if l.link_attrs = [] then base
    else base @ [ ("attributes", attrs_json l.link_attrs) ]
  in
  `Assoc with_attrs

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
  let parent =
    match s.parent_span_id with
    | Some p -> [ ("parentSpanId", `String p) ]
    | None -> []
  in
  let events =
    if s.events = [] then []
    else [ ("events", `List (List.map event_json s.events)) ]
  in
  let links =
    if s.links = [] then []
    else [ ("links", `List (List.map link_json s.links)) ]
  in
  let trace_state =
    match s.trace_state with
    | [] -> []
    | xs ->
        [
          ( "traceState",
            `String
              (String.concat ","
                 (List.map (fun (k, v) -> k ^ "=" ^ v) xs)) );
        ]
  in
  let status =
    match status_json s.status_code s.status_message with
    | None -> []
    | Some j -> [ ("status", j) ]
  in
  `Assoc
    ([
       ("traceId", `String s.trace_id);
       ("spanId", `String s.span_id);
     ]
    @ parent
    @ [
        ("name", `String s.name);
        ("kind", `Int (span_kind_int s.kind));
        ("startTimeUnixNano", str_int s.start_unix_ns);
        ("endTimeUnixNano", str_int s.end_unix_ns);
        ("attributes", attrs_json s.attrs);
      ]
    @ trace_state @ events @ links @ status)

let resource_json resource_attrs : yj =
  `Assoc [ ("attributes", attrs_json resource_attrs) ]

let scope_json scope_name : yj = `Assoc [ ("name", `String scope_name) ]

let encode_traces_request ~resource_attrs ~scope_name spans =
  let payload : yj =
    `Assoc
      [
        ( "resourceSpans",
          `List
            [
              `Assoc
                [
                  ("resource", resource_json resource_attrs);
                  ( "scopeSpans",
                    `List
                      [
                        `Assoc
                          [
                            ("scope", scope_json scope_name);
                            ("spans", `List (List.map span_json spans));
                          ];
                      ] );
                ];
            ] );
      ]
  in
  Yojson.Safe.to_string payload

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
  let ts_ns = r.ts_ms * 1_000_000 in
  let trace =
    if r.trace_id = "" then [] else [ ("traceId", `String r.trace_id) ]
  in
  let span =
    if r.span_id = "" then [] else [ ("spanId", `String r.span_id) ]
  in
  `Assoc
    ([
       ("timeUnixNano", str_int ts_ns);
       ("observedTimeUnixNano", str_int ts_ns);
       ("severityNumber", `Int (severity_number r.level));
       ("severityText", `String (severity_text r.level));
       ("body", `Assoc [ ("stringValue", `String r.body) ]);
       ("attributes", attrs_json r.attrs);
     ]
    @ trace @ span)

let encode_logs_request ~resource_attrs ~scope_name records =
  let payload : yj =
    `Assoc
      [
        ( "resourceLogs",
          `List
            [
              `Assoc
                [
                  ("resource", resource_json resource_attrs);
                  ( "scopeLogs",
                    `List
                      [
                        `Assoc
                          [
                            ("scope", scope_json scope_name);
                            ("logRecords", `List (List.map log_json records));
                          ];
                      ] );
                ];
            ] );
      ]
  in
  Yojson.Safe.to_string payload

module Metric_aggregation = Metric_aggregation
module Metric_key = Metric_aggregation.Metric_key

let value_field (v : Eta.Capabilities.metric_value) =
  match v with
  | Int n -> ("asInt", `String (string_of_int n))
  | Float f -> ("asDouble", `Float f)

let data_point_json (key : Metric_key.t) (value, start_ts, end_ts) : yj =
  `Assoc
    [
      ("attributes", attrs_json key.attrs);
      ("startTimeUnixNano", str_int start_ts);
      ("timeUnixNano", str_int end_ts);
      value_field value;
    ]

let metric_json (key : Metric_key.t) point : yj =
  let body : yj =
    match key.kind with
    | Gauge -> `Assoc [ ("dataPoints", `List [ data_point_json key point ]) ]
    | Counter_cumulative ->
        `Assoc
          [
            ("dataPoints", `List [ data_point_json key point ]);
            ("aggregationTemporality", `Int 1);
            ("isMonotonic", `Bool false);
          ]
    | Counter_monotonic ->
        `Assoc
          [
            ("dataPoints", `List [ data_point_json key point ]);
            ("aggregationTemporality", `Int 2);
            ("isMonotonic", `Bool true);
          ]
  in
  let kind_field =
    match key.kind with
    | Gauge -> "gauge"
    | Counter_cumulative | Counter_monotonic -> "sum"
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
  let payload : yj =
    `Assoc
      [
        ( "resourceMetrics",
          `List
            [
              `Assoc
                [
                  ("resource", resource_json resource_attrs);
                  ( "scopeMetrics",
                    `List
                      [
                        `Assoc
                          [
                            ("scope", scope_json scope_name);
                            ( "metrics",
                              `List
                                (List.map
                                   (fun (k, v) -> metric_json k v)
                                   aggregated) );
                          ];
                      ] );
                ];
            ] );
      ]
  in
  Yojson.Safe.to_string payload
