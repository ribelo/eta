(* eta-otel: OTLP/JSON over HTTP/1.1 exporter for Eta's tracer, logger,
   and meter capabilities.

   Hand-rolled HTTP/1.1 over Eio TCP keeps the dependency closure to
   {eta, eta-stream, eio, yojson}. The exporter accumulates spans, log
   records, and metric points on bounded Eta mailboxes; Eta stream pipelines
   batch and merge each signal and one Eta runtime daemon exports them. Raw Eio stays at the
   HTTP and clock leaves. *)

(* ------------------------------------------------------------------ *)
(* Hex helpers                                                        *)
(* ------------------------------------------------------------------ *)

module Stream = Eta_stream.Stream
module Mailbox = Eta_stream.Mailbox
module Drain_counter = Eta_stream.Drain_counter

let hex_of_bytes b =
  let buf = Buffer.create (2 * Bytes.length b) in
  Bytes.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    b;
  Buffer.contents buf

let random_bytes rng n =
  let b = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set b i (Char.chr (Stdlib.Random.State.int rng 256))
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
  kind : Eta.Capabilities.span_kind;
  start_unix_ns : int;
  mutable end_unix_ns : int;
  mutable attrs : (string * string) list;
  mutable events : (string * int * (string * string) list) list;
  mutable links : Eta.Capabilities.span_link list;
  mutable status_code : int; (* 0 unset, 1 ok, 2 error *)
  mutable status_message : string;
}

type export_config = {
  host : string;
  port : int;
  traces_path : string;
  logs_path : string;
  metrics_path : string;
  resource_attrs : (string * string) list;
  scope_name : string;
}

type signal_batch =
  | Trace_batch of span list
  | Log_batch of Eta.Capabilities.log_record list
  | Metric_batch of Eta.Meter.point list

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

(* ------------------------------------------------------------------ *)
(* OTLP/JSON encoders for logs                                        *)
(* ------------------------------------------------------------------ *)

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

(* ------------------------------------------------------------------ *)
(* OTLP/JSON encoders for metrics                                     *)
(* ------------------------------------------------------------------ *)

module Metric_key = struct
  type t = {
    name : string;
    description : string;
    unit_ : string;
    kind : Eta.Capabilities.metric_kind;
    attrs : (string * string) list;
  }

  let normalize_attrs = function
    | [] | [ _ ] as attrs -> attrs
    | attrs -> List.sort compare attrs

  let normalize (p : Eta.Meter.point) =
    {
      name = p.name;
      description = p.description;
      unit_ = p.unit_;
      kind = p.kind;
      attrs = normalize_attrs p.attrs;
    }
end

let aggregate_points (points : Eta.Meter.point list) =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (p : Eta.Meter.point) ->
      let key = Metric_key.normalize p in
      let ts_ns = p.ts_ms * 1_000_000 in
      match Hashtbl.find_opt table key with
      | None -> Hashtbl.add table key (p.value, ts_ns, ts_ns)
      | Some (acc, start_ts, _end_ts) ->
          let new_v =
            match p.kind with
            | Eta.Capabilities.Gauge -> p.value
            | Counter_cumulative | Counter_monotonic -> (
                match (acc, p.value) with
                | Eta.Capabilities.Int a, Eta.Capabilities.Int b ->
                    Eta.Capabilities.Int (a + b)
                | Float a, Float b -> Float (a +. b)
                | Int a, Float b -> Float (float_of_int a +. b)
                | Float a, Int b -> Float (a +. float_of_int b))
          in
          Hashtbl.replace table key (new_v, start_ts, ts_ns))
    points;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []

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
  eta_clock : Eta.Capabilities.clock;
  config : (export_config, [ `Config ]) Eta.Resource.t;
  queue : span Mailbox.t;
  log_queue : Eta.Capabilities.log_record Mailbox.t;
  metric_queue : Eta.Meter.point Mailbox.t;
  self_tracer : Eta.Tracer.in_memory;
  flush_rt : unit Eta.Runtime.t;
  mutable next_handle : int;
  table : (int, span) Hashtbl.t;
  rng : Stdlib.Random.State.t;
  in_flight : Drain_counter.t;
  mutable on_error : string -> unit;
  mutable on_send : path:string -> body:string -> unit;
}

let now_ns t =
  let secs = Eio.Time.now t.clock in
  int_of_float (secs *. 1_000_000_000.0)

(* ------------------------------------------------------------------ *)
(* Eta exporter programs                                               *)
(* ------------------------------------------------------------------ *)

let decrement_in_flight t n =
  Eta.Effect.named "eta_otel.export.decrement_in_flight" (Eta.Effect.sync (fun () ->
      Drain_counter.decr_by t.in_flight n))

let observe_send t ~path ~body =
  Eta.Effect.named "eta_otel.export.on_send" (Eta.Effect.sync (fun () ->
      try t.on_send ~path ~body with _ -> ()))

let observe_error t msg =
  Eta.Effect.named "eta_otel.export.on_error" (Eta.Effect.sync (fun () ->
      try t.on_error msg with _ -> ()))

let render_export_error = function
  | `Export_error msg -> msg
  | `Timeout -> "export timeout"

let post_effect t config ~path ~body =
  Eta.Effect.named "eta_otel.export.post_json" (Eta.Effect.sync (fun () ->
      try
        Eio.Switch.run @@ fun sw ->
        post_json ~sw ~net:t.net ~host:config.host ~port:config.port ~path body
      with exn -> Error (Printexc.to_string exn)))
  |> Eta.Effect.bind (function
       | Ok () -> Eta.Effect.unit
       | Error msg -> Eta.Effect.fail (`Export_error msg))

let post_or_deadline t config ~path ~body =
  let post =
    post_effect t config ~path ~body
    |> Eta.Effect.map (fun () -> `Posted)
    |> Eta.Effect.catch (fun (`Export_error msg) ->
           Eta.Effect.pure (`Post_failed msg))
  in
  let deadline =
    Eta.Effect.pure `Timed_out
    |> Eta.Effect.delay (Eta.Duration.seconds 5)
  in
  Eta.Effect.race [ post; deadline ]
  |> Eta.Effect.timeout (Eta.Duration.seconds 6)
  |> Eta.Effect.bind (function
       | `Posted -> Eta.Effect.unit
       | `Post_failed msg -> Eta.Effect.fail (`Export_error msg)
       | `Timed_out -> Eta.Effect.fail `Timeout)

let export_body t config ~path ~body =
  observe_send t ~path ~body
  |> Eta.Effect.bind (fun () ->
         post_or_deadline t config ~path ~body
         |> Eta.Effect.retry (Eta.Schedule.recurs 2) (fun _ -> true)
         |> Eta.Effect.catch (fun error ->
                observe_error t (render_export_error error)))

let export_batch t config ~path ~body ~n =
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
       ~release:(fun () -> decrement_in_flight t n)
    |> Eta.Effect.bind (fun () -> export_body t config ~path ~body))

let signal_batches t =
  let traces =
    Mailbox.to_batch_stream ~max:32 t.queue
    |> Stream.map (fun batch -> Trace_batch batch)
  in
  let logs =
    Mailbox.to_batch_stream ~max:64 t.log_queue
    |> Stream.map (fun batch -> Log_batch batch)
  in
  let metrics =
    Mailbox.to_batch_stream ~max:128 t.metric_queue
    |> Stream.map (fun batch -> Metric_batch batch)
  in
  Stream.merge traces (Stream.merge logs metrics)

let encode_signal config = function
  | Trace_batch batch ->
      ( "traces",
        config.traces_path,
        List.length batch,
        encode_traces_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name batch )
  | Log_batch batch ->
      ( "logs",
        config.logs_path,
        List.length batch,
        encode_logs_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name batch )
  | Metric_batch batch ->
      ( "metrics",
        config.metrics_path,
        List.length batch,
        encode_metrics_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name batch )

let export_signal t config signal =
  let name =
    match signal with
    | Trace_batch _ -> "traces"
    | Log_batch _ -> "logs"
    | Metric_batch _ -> "metrics"
  in
  Eta.Effect.named ("eta_otel." ^ name ^ ".encode") (Eta.Effect.sync (fun () ->
      encode_signal config signal))
  |> Eta.Effect.bind (fun (name, path, n, body) ->
         export_batch t config ~path ~body ~n
         |> Eta.Effect.annotate ~key:"otel.path" ~value:path
         |> Eta.Effect.annotate ~key:"otel.batch_size" ~value:(string_of_int n)
         |> Eta.Effect.named ("eta_otel.export." ^ name))

let export_program t =
  Eta.Resource.get t.config
  |> Eta.Effect.bind (fun config ->
         signal_batches t
         |> Stream.flat_map_par ~max_concurrency:3 (fun signal ->
                Stream.from_effect (export_signal t config signal))
         |> Eta_stream.run_drain)
  |> Eta.Effect.named "eta_otel.exporter"

let start_daemon rt effect =
  match Eta.Runtime.run rt (Eta.Effect.Private.daemon effect) with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error _ -> ()

let enqueue t mailbox value =
  Drain_counter.incr t.in_flight;
  match Mailbox.offer mailbox value with
  | Mailbox.Enqueued -> ()
  | Mailbox.Dropped | Mailbox.Closed ->
      Drain_counter.decr t.in_flight

let dropped t =
  Mailbox.dropped t.queue + Mailbox.dropped t.log_queue
  + Mailbox.dropped t.metric_queue

let close_mailboxes t =
  Mailbox.close t.queue;
  Mailbox.close t.log_queue;
  Mailbox.close t.metric_queue

let duration_of_timeout_s timeout_s =
  let ms = max 0 (int_of_float (ceil (timeout_s *. 1000.0))) in
  Eta.Duration.ms ms

let flush ?(timeout_s = 5.0) t =
  if Drain_counter.value t.in_flight = 0 then ()
  else
    let wait = Drain_counter.await_zero t.in_flight in
    let timeout =
      Eta.Effect.named "eta_otel.flush.timeout" (Eta.Effect.sync (fun () ->
          t.eta_clock#sleep (duration_of_timeout_s timeout_s)))
    in
    ignore
      (Eta.Runtime.run t.flush_rt (Eta.Effect.race [ wait; timeout ])
        : (unit, unit) Eta.Exit.t)

let shutdown ?timeout_s t =
  close_mailboxes t;
  flush ?timeout_s t

let start_exporters t ~rt =
  start_daemon rt (export_program t)

let make_config_resource rt config :
    (export_config, [ `Config ]) Eta.Resource.t =
  let load =
    Eta.Effect.named "eta_otel.config.load" (Eta.Effect.sync (fun () -> config))
    |> Eta.Effect.named "eta_otel.config"
  in
  match Eta.Runtime.run rt (Eta.Resource.manual load) with
  | Eta.Exit.Ok resource -> resource
  | Eta.Exit.Error _ -> failwith "eta-otel: config resource failed"

(* ------------------------------------------------------------------ *)
(* Tracer methods                                                     *)
(* ------------------------------------------------------------------ *)

let resolve_parent t = function
  | None, None ->
      (hex_of_bytes (random_bytes t.rng 16), None, 1, [], [])
  | _, Some (ctx : Eta.Capabilities.trace_context) ->
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

let begin_span t ?parent_id ?external_parent ?(kind = Eta.Capabilities.Internal)
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

let map_status (st : Eta.Capabilities.span_status) =
  match st with
  | Eta.Capabilities.Ok -> (1, "")
  | Eta.Capabilities.Error msg -> (2, msg)
  | Eta.Capabilities.Cancelled -> (2, "cancelled")

let end_span t ~span_id ~status ~ended_ms:_ =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      Hashtbl.remove t.table span_id;
      s.end_unix_ns <- now_ns t;
      let code, message = map_status status in
      s.status_code <- code;
      s.status_message <- message;
      enqueue t t.queue s

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

let inspect t ~span_id : Eta.Capabilities.span_info option =
  match Hashtbl.find_opt t.table span_id with
  | Some s ->
      Some
        {
          Eta.Capabilities.trace_id = s.trace_id;
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
    ?(metrics_path = "/v1/metrics") ?(service_name = "eta")
    ?service_version ?(resource_attrs = []) ?(scope_name = "eta")
    ?(queue_capacity = 1024) ?on_error ?on_send () =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Std.r) in
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let on_error =
    Option.value on_error ~default:(fun msg ->
        prerr_endline ("[eta-otel] export failed: " ^ msg))
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
  let rng = Stdlib.Random.State.make_self_init () in
  let self_tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta.Runtime.create ~sw ~clock
      ~tracer:(Eta.Tracer.as_capability self_tracer)
      ()
  in
  let flush_rt : unit Eta.Runtime.t =
    Eta.Runtime.create ~sw ~clock
      ~tracer:(Eta.Tracer.as_capability self_tracer)
      ()
  in
  let config =
    {
      host;
      port;
      traces_path;
      logs_path;
      metrics_path;
      resource_attrs;
      scope_name;
    }
  in
  let config_resource = make_config_resource rt config in
  let t =
    {
      net;
      clock;
      eta_clock = Eta.Capabilities.clock_of_eio clock;
      config = config_resource;
      queue = Mailbox.create ~capacity:queue_capacity ();
      log_queue = Mailbox.create ~capacity:queue_capacity ();
      metric_queue = Mailbox.create ~capacity:queue_capacity ();
      self_tracer;
      flush_rt;
      next_handle = 1;
      table = Hashtbl.create 64;
      rng;
      in_flight = Drain_counter.create ();
      on_error;
      on_send;
    }
  in
  start_exporters t ~rt;
  t

let tracer t : Eta.Capabilities.tracer =
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

let logger t : Eta.Capabilities.logger =
  object
    method log r = enqueue t t.log_queue r
  end

let meter t : Eta.Capabilities.meter =
  object
    method record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms =
      let p =
        {
          Eta.Meter.name;
          description;
          unit_;
          kind;
          attrs;
          value;
          ts_ms;
        }
      in
      enqueue t t.metric_queue p
  end

module Internal = struct
  type nonrec span = span = {
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

  let encode_traces_request = encode_traces_request
  let encode_logs_request = encode_logs_request
  let encode_metrics_request = encode_metrics_request
  let dropped = dropped
  let self_spans t = Eta.Tracer.dump t.self_tracer
end
