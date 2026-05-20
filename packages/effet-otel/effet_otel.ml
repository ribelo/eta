(* effet-otel: OTLP/JSON over HTTP/1.1 exporter for Effet's tracer, logger,
   and meter capabilities.

   Hand-rolled HTTP/1.1 over Eio TCP keeps the dependency closure to
   {effet, eio, yojson}. The exporter accumulates spans, log records, and
   metric points on three Eio streams; one background fiber per signal
   drains its queue, builds an OTLP/JSON [Yojson.Safe.t] tree, and POSTs
   it to the configured endpoint. *)

(* ------------------------------------------------------------------ *)
(* Hex helpers                                                        *)
(* ------------------------------------------------------------------ *)

let hex_of_bytes b =
  let buf = Buffer.create (2 * Bytes.length b) in
  Bytes.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    b;
  Buffer.contents buf

let random_bytes rng n =
  let b = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set b i (Char.chr (Random.State.int rng 256))
  done;
  b

(* ------------------------------------------------------------------ *)
(* OTLP/JSON helpers (yojson-based)                                   *)
(* ------------------------------------------------------------------ *)

type yj = Yojson.Safe.t

let attr_value_string s : yj = `Assoc [ ("stringValue", `String s) ]

let attrs_json (attrs : (string * string) list) : yj =
  `List
    (List.map
       (fun (k, v) ->
         `Assoc [ ("key", `String k); ("value", attr_value_string v) ])
       attrs)

let str_int n = `String (string_of_int n)

(* ------------------------------------------------------------------ *)
(* Span record (one collected span, ready to encode)                  *)
(* ------------------------------------------------------------------ *)

type span = {
  trace_id : string; (* 32 hex chars *)
  span_id : string; (* 16 hex chars *)
  parent_span_id : string option;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
  name : string;
  kind : Effet.Capabilities.span_kind;
  start_unix_ns : int;
  mutable end_unix_ns : int;
  mutable attrs : (string * string) list;
  mutable events : (string * int * (string * string) list) list;
  mutable links : Effet.Capabilities.span_link list;
  mutable status_code : int; (* 0 unset, 1 ok, 2 error *)
  mutable status_message : string;
}

let event_json (name, ts_ns, attrs) : yj =
  `Assoc
    [
      ("name", `String name);
      ("timeUnixNano", str_int ts_ns);
      ("attributes", attrs_json attrs);
    ]

let link_json (l : Effet.Capabilities.span_link) : yj =
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
  | Effet.Capabilities.Internal -> 1
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

(* ------------------------------------------------------------------ *)
(* OTLP/JSON encoders for logs                                        *)
(* ------------------------------------------------------------------ *)

let severity_number = function
  | Effet.Capabilities.Trace -> 1
  | Debug -> 5
  | Info -> 9
  | Warn -> 13
  | Error -> 17
  | Fatal -> 21

let severity_text = function
  | Effet.Capabilities.Trace -> "TRACE"
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
  | Fatal -> "FATAL"

let log_json (r : Effet.Capabilities.log_record) : yj =
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

(* ------------------------------------------------------------------ *)
(* OTLP/JSON encoders for metrics                                     *)
(* ------------------------------------------------------------------ *)

module Metric_key = struct
  type t = {
    name : string;
    description : string;
    unit_ : string;
    kind : Effet.Capabilities.metric_kind;
    attrs : (string * string) list;
  }

  let normalize (p : Effet.Meter.point) =
    {
      name = p.name;
      description = p.description;
      unit_ = p.unit_;
      kind = p.kind;
      attrs = List.sort compare p.attrs;
    }
end

let aggregate_points (points : Effet.Meter.point list) =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (p : Effet.Meter.point) ->
      let key = Metric_key.normalize p in
      let ts_ns = p.ts_ms * 1_000_000 in
      match Hashtbl.find_opt table key with
      | None -> Hashtbl.add table key (p.value, ts_ns, ts_ns)
      | Some (acc, start_ts, _end_ts) ->
          let new_v =
            match p.kind with
            | Effet.Capabilities.Gauge -> p.value
            | Counter_cumulative | Counter_monotonic -> (
                match (acc, p.value) with
                | Effet.Capabilities.Int a, Effet.Capabilities.Int b ->
                    Effet.Capabilities.Int (a + b)
                | Float a, Float b -> Float (a +. b)
                | Int a, Float b -> Float (float_of_int a +. b)
                | Float a, Int b -> Float (a +. float_of_int b))
          in
          Hashtbl.replace table key (new_v, start_ts, ts_ns))
    points;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []

let value_field (v : Effet.Capabilities.metric_value) =
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
            ("aggregationTemporality", `Int 2);
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
  let aggregated = aggregate_points points in
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

(* ------------------------------------------------------------------ *)
(* HTTP/1.1 POST over Eio TCP                                         *)
(* ------------------------------------------------------------------ *)

let post_json ~sw ~net ~host ~port ~path body =
  let body_len = String.length body in
  let request =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      path host port body_len body
  in
  Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net
  @@ fun flow ->
  Eio.Flow.copy_string request flow;
  (try Eio.Flow.shutdown flow `Send with _ -> ());
  let buf = Eio.Buf_read.of_flow ~max_size:65536 flow in
  let _ = sw in
  match Eio.Buf_read.line buf with
  | exception End_of_file -> Error "no response"
  | status_line -> (
      match String.split_on_char ' ' status_line with
      | _ :: code :: _ when code = "200" || code = "202" -> Ok ()
      | _ -> Error status_line)

(* ------------------------------------------------------------------ *)
(* Exporter state                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  net : [ `Generic ] Eio.Net.ty Eio.Std.r;
  clock : float Eio.Time.clock_ty Eio.Std.r;
  host : string;
  port : int;
  traces_path : string;
  logs_path : string;
  metrics_path : string;
  resource_attrs : (string * string) list;
  scope_name : string;
  queue : span Eio.Stream.t;
  log_queue : Effet.Capabilities.log_record Eio.Stream.t;
  metric_queue : Effet.Meter.point Eio.Stream.t;
  mutable next_handle : int;
  table : (int, span) Hashtbl.t;
  rng : Random.State.t;
  flush : unit Eio.Promise.t * unit Eio.Promise.u;
  mutable in_flight : int Atomic.t;
  mutable on_error : string -> unit;
  mutable on_send : path:string -> body:string -> unit;
}

let now_ns t =
  let secs = Eio.Time.now t.clock in
  int_of_float (secs *. 1_000_000_000.0)

(* ------------------------------------------------------------------ *)
(* Background exporter fibers                                         *)
(* ------------------------------------------------------------------ *)

let try_post t ~path ~body ~n =
  (try t.on_send ~path ~body with _ -> ());
  let result =
    try
      Eio.Switch.run @@ fun sw ->
      post_json ~sw ~net:t.net ~host:t.host ~port:t.port ~path body
    with exn -> Error (Printexc.to_string exn)
  in
  (match result with
  | Ok () -> ()
  | Error msg -> (try t.on_error msg with _ -> ()));
  for _ = 1 to n do
    Atomic.decr t.in_flight
  done

let exporter_loop t =
  let rec drain_more acc remaining =
    if remaining = 0 then List.rev acc
    else
      match Eio.Stream.take_nonblocking t.queue with
      | Some s -> drain_more (s :: acc) (remaining - 1)
      | None -> List.rev acc
  in
  while true do
    let first = Eio.Stream.take t.queue in
    let batch = first :: drain_more [] 31 in
    let body =
      encode_traces_request ~resource_attrs:t.resource_attrs
        ~scope_name:t.scope_name batch
    in
    try_post t ~path:t.traces_path ~body ~n:(List.length batch)
  done

let logs_loop t =
  let rec drain_more acc remaining =
    if remaining = 0 then List.rev acc
    else
      match Eio.Stream.take_nonblocking t.log_queue with
      | Some r -> drain_more (r :: acc) (remaining - 1)
      | None -> List.rev acc
  in
  while true do
    let first = Eio.Stream.take t.log_queue in
    let batch = first :: drain_more [] 63 in
    let body =
      encode_logs_request ~resource_attrs:t.resource_attrs
        ~scope_name:t.scope_name batch
    in
    try_post t ~path:t.logs_path ~body ~n:(List.length batch)
  done

let metrics_loop t =
  let rec drain_more acc remaining =
    if remaining = 0 then List.rev acc
    else
      match Eio.Stream.take_nonblocking t.metric_queue with
      | Some p -> drain_more (p :: acc) (remaining - 1)
      | None -> List.rev acc
  in
  while true do
    let first = Eio.Stream.take t.metric_queue in
    let batch = first :: drain_more [] 127 in
    let body =
      encode_metrics_request ~resource_attrs:t.resource_attrs
        ~scope_name:t.scope_name batch
    in
    try_post t ~path:t.metrics_path ~body ~n:(List.length batch)
  done

(* ------------------------------------------------------------------ *)
(* Tracer methods                                                     *)
(* ------------------------------------------------------------------ *)

let resolve_parent t = function
  | None, None ->
      (hex_of_bytes (random_bytes t.rng 16), None, 1, [], [])
  | _, Some (ctx : Effet.Capabilities.trace_context) ->
      ( ctx.trace_id,
        Some ctx.span_id,
        ctx.trace_flags,
        ctx.trace_state,
        ctx.baggage )
  | Some p_handle, None -> (
      match Hashtbl.find_opt t.table p_handle with
      | Some p ->
          (p.trace_id, Some p.span_id, p.trace_flags, p.trace_state, p.baggage)
      | None -> (hex_of_bytes (random_bytes t.rng 16), None, 1, [], []))

let begin_span t ?parent_id ?external_parent ?(kind = Effet.Capabilities.Internal)
    ~name ~started_ms:_ () =
  let trace_id, parent_span_id, trace_flags, trace_state, baggage =
    resolve_parent t (parent_id, external_parent)
  in
  let span_id = hex_of_bytes (random_bytes t.rng 8) in
  let start_unix_ns = now_ns t in
  let s =
    {
      trace_id;
      span_id;
      parent_span_id;
      trace_flags;
      trace_state;
      baggage;
      name;
      kind;
      start_unix_ns;
      end_unix_ns = start_unix_ns;
      attrs = [];
      events = [];
      links = [];
      status_code = 0;
      status_message = "";
    }
  in
  let handle = t.next_handle in
  t.next_handle <- handle + 1;
  Hashtbl.replace t.table handle s;
  handle

let map_status (st : Effet.Capabilities.span_status) =
  match st with
  | Effet.Capabilities.Ok -> (1, "")
  | Effet.Capabilities.Error msg -> (2, msg)
  | Effet.Capabilities.Cancelled -> (2, "cancelled")

let end_span t ~span_id ~status ~ended_ms:_ =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      Hashtbl.remove t.table span_id;
      s.end_unix_ns <- now_ns t;
      let code, message = map_status status in
      s.status_code <- code;
      s.status_message <- message;
      Atomic.incr t.in_flight;
      Eio.Stream.add t.queue s

let pick_latest_open t =
  let target = ref None in
  Hashtbl.iter
    (fun h s ->
      match !target with
      | None -> target := Some (h, s)
      | Some (h', _) when h > h' -> target := Some (h, s)
      | _ -> ())
    t.table;
  !target

let add_attr t ~key ~value =
  match pick_latest_open t with
  | Some (_, s) -> s.attrs <- (key, value) :: s.attrs
  | None -> ()

let add_event t ~span_id ~name ~ts_ms ~attrs =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      let ts_ns = if ts_ms = 0 then now_ns t else ts_ms * 1_000_000 in
      s.events <- (name, ts_ns, attrs) :: s.events

let add_link t link =
  match pick_latest_open t with
  | Some (_, s) -> s.links <- link :: s.links
  | None -> ()

let inspect t ~span_id : Effet.Capabilities.span_info option =
  match Hashtbl.find_opt t.table span_id with
  | Some s ->
      Some
        {
          Effet.Capabilities.trace_id = s.trace_id;
          span_id = s.span_id;
          name = s.name;
          trace_flags = s.trace_flags;
          trace_state = s.trace_state;
          baggage = s.baggage;
        }
  | None -> None

(* ------------------------------------------------------------------ *)
(* Public constructor                                                 *)
(* ------------------------------------------------------------------ *)

let create ~sw ~net ~clock ?(host = "127.0.0.1") ?(port = 4318)
    ?(traces_path = "/v1/traces") ?(logs_path = "/v1/logs")
    ?(metrics_path = "/v1/metrics") ?(service_name = "effet")
    ?service_version ?(resource_attrs = []) ?(scope_name = "effet") ?on_error
    ?on_send () =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Std.r) in
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let on_error =
    Option.value on_error ~default:(fun msg ->
        prerr_endline ("[effet-otel] export failed: " ^ msg))
  in
  let on_send = Option.value on_send ~default:(fun ~path:_ ~body:_ -> ()) in
  let resource_attrs =
    let base = [ ("service.name", service_name) ] in
    let base =
      match service_version with
      | Some v -> base @ [ ("service.version", v) ]
      | None -> base
    in
    base @ resource_attrs
  in
  let rng = Random.State.make_self_init () in
  let t =
    {
      net;
      clock;
      host;
      port;
      traces_path;
      logs_path;
      metrics_path;
      resource_attrs;
      scope_name;
      queue = Eio.Stream.create 1024;
      log_queue = Eio.Stream.create 1024;
      metric_queue = Eio.Stream.create 1024;
      next_handle = 1;
      table = Hashtbl.create 64;
      rng;
      flush = Eio.Promise.create ();
      in_flight = Atomic.make 0;
      on_error;
      on_send;
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try exporter_loop t with _ -> ());
      `Stop_daemon);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try logs_loop t with _ -> ());
      `Stop_daemon);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try metrics_loop t with _ -> ());
      `Stop_daemon);
  t

let tracer t : Effet.Capabilities.tracer =
  object
    method begin_span ?parent_id ?external_parent ?kind ~name ~started_ms () =
      begin_span t ?parent_id ?external_parent ?kind ~name ~started_ms ()

    method end_span ~span_id ~status ~ended_ms =
      end_span t ~span_id ~status ~ended_ms

    method add_attr ~key ~value = add_attr t ~key ~value
    method add_event ~span_id ~name ~ts_ms ~attrs =
      add_event t ~span_id ~name ~ts_ms ~attrs
    method add_link link = add_link t link
    method inspect ~span_id = inspect t ~span_id
  end

let logger t : Effet.Capabilities.logger =
  object
    method log r =
      Atomic.incr t.in_flight;
      Eio.Stream.add t.log_queue r
  end

let meter t : Effet.Capabilities.meter =
  object
    method record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms =
      let p =
        {
          Effet.Meter.name;
          description;
          unit_;
          kind;
          attrs;
          value;
          ts_ms;
        }
      in
      Atomic.incr t.in_flight;
      Eio.Stream.add t.metric_queue p
  end

let flush ?(timeout_s = 5.0) t =
  let deadline = Eio.Time.now t.clock +. timeout_s in
  let rec wait () =
    if Atomic.get t.in_flight = 0 then ()
    else if Eio.Time.now t.clock > deadline then ()
    else begin
      Eio.Time.sleep t.clock 0.005;
      wait ()
    end
  in
  wait ()

module Internal = struct
  type nonrec span = span = {
    trace_id : string;
    span_id : string;
    parent_span_id : string option;
    trace_flags : int;
    trace_state : (string * string) list;
    baggage : (string * string) list;
    name : string;
    kind : Effet.Capabilities.span_kind;
    start_unix_ns : int;
    mutable end_unix_ns : int;
    mutable attrs : (string * string) list;
    mutable events : (string * int * (string * string) list) list;
    mutable links : Effet.Capabilities.span_link list;
    mutable status_code : int;
    mutable status_message : string;
  }

  let encode_traces_request = encode_traces_request
  let encode_logs_request = encode_logs_request
  let encode_metrics_request = encode_metrics_request
end
