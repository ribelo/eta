(* eta-otel: OTLP/JSON exporter for Eta's tracer, logger, and meter
   capabilities.

   The exporter accumulates spans, log records, and metric points on bounded
   Eta mailboxes. Eta stream pipelines batch and merge each signal; one Eta
   runtime daemon POSTs batches through eta-http with observation suppressed so
   exporter transport does not recursively emit telemetry. *)

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

module Otlp_json = Eta_otel_otlp_json

type span = Otlp_json.span = {
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

type signal_kind = Traces | Logs | Metrics

let encode_traces_request = Otlp_json.encode_traces_request
let encode_logs_request = Otlp_json.encode_logs_request
let encode_metrics_request = Otlp_json.encode_metrics_request
module Metric_key = Eta_otel_metric_aggregation.Metric_key
let aggregate_points = Eta_otel_metric_aggregation.aggregate_points
(* ------------------------------------------------------------------ *)
(* OTLP/HTTP transport                                                *)
(* ------------------------------------------------------------------ *)

let otlp_retry_status = function
  | 429 | 502 | 503 | 504 -> true
  | _ -> false

let otlp_retry_policy =
  Eta_http.Retry_policy.always ~max_attempts:3
    ~retry_status:otlp_retry_status ()

let otlp_headers =
  Eta_http.Core.Header.unsafe_of_list
    [ ("content-type", "application/json"); ("accept", "application/json") ]

let otlp_url config path =
  Printf.sprintf "http://%s:%d%s" config.host config.port path

let otlp_request config ~path ~body =
  Eta_http.Request.make ~headers:otlp_headers
    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
    "POST" (otlp_url config path)

let render_http_status status body =
  let body = String.trim (Bytes.to_string body) in
  if body = "" then Printf.sprintf "HTTP %d" status
  else Printf.sprintf "HTTP %d: %s" status body

(* ------------------------------------------------------------------ *)
(* Exporter state                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  http_client : Eta_http.Client.t;
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

let now_ms t =
  let secs = Eio.Time.now t.clock in
  int_of_float (secs *. 1_000.0)

(* ------------------------------------------------------------------ *)
(* Eta exporter programs                                               *)
(* ------------------------------------------------------------------ *)

let decrement_in_flight t n =
  Eta.Effect.named "eta_otel.export.decrement_in_flight" (Eta.Effect.sync (fun () ->
      Drain_counter.decr_by t.in_flight n))

let enqueue t mailbox value =
  Drain_counter.incr t.in_flight;
  match Mailbox.offer mailbox value with
  | Mailbox.Enqueued -> ()
  | Mailbox.Dropped | Mailbox.Closed ->
      Drain_counter.decr t.in_flight

let signal_name = function
  | Traces -> "traces"
  | Logs -> "logs"
  | Metrics -> "metrics"

let self_metric t ~name ~description ~unit_ ~kind ~attrs ~value =
  {
    Eta.Meter.name;
    description;
    unit_;
    kind;
    attrs;
    value;
    ts_ms = now_ms t;
  }

let self_queue_metrics t =
  [
    ("traces", Mailbox.length t.queue, Mailbox.dropped t.queue);
    ("logs", Mailbox.length t.log_queue, Mailbox.dropped t.log_queue);
    ("metrics", Mailbox.length t.metric_queue, Mailbox.dropped t.metric_queue);
  ]
  |> List.concat_map (fun (queue, length, dropped) ->
         [
           self_metric t ~name:"eta_otel.queue.depth"
             ~description:"Current eta-otel exporter queue depth" ~unit_:"item"
             ~kind:Eta.Capabilities.Gauge ~attrs:[ ("queue", queue) ]
             ~value:(Eta.Capabilities.Int length);
           self_metric t ~name:"eta_otel.queue.dropped"
             ~description:"Cumulative eta-otel exporter queue drops" ~unit_:"item"
             ~kind:Eta.Capabilities.Gauge ~attrs:[ ("queue", queue) ]
             ~value:(Eta.Capabilities.Int dropped);
         ])

let self_export_metrics t signal ~batch_size =
  let signal = signal_name signal in
  [
    self_metric t ~name:"eta_otel.export.batches"
      ~description:"Eta-otel export batch attempts" ~unit_:"batch"
      ~kind:Eta.Capabilities.Counter_monotonic ~attrs:[ ("signal", signal) ]
      ~value:(Eta.Capabilities.Int 1);
    self_metric t ~name:"eta_otel.export.items"
      ~description:"Eta-otel export items attempted" ~unit_:"item"
      ~kind:Eta.Capabilities.Counter_monotonic ~attrs:[ ("signal", signal) ]
      ~value:(Eta.Capabilities.Int batch_size);
    self_metric t ~name:"eta_otel.in_flight"
      ~description:"Current eta-otel in-flight export work" ~unit_:"item"
      ~kind:Eta.Capabilities.Gauge ~attrs:[]
      ~value:(Eta.Capabilities.Int (Drain_counter.value t.in_flight));
  ]
  @ self_queue_metrics t

let enqueue_self_export_metrics t signal ~batch_size =
  Eta.Effect.named "eta_otel.self_metrics.enqueue" (Eta.Effect.sync (fun () ->
      self_export_metrics t signal ~batch_size
      |> List.iter (enqueue t t.metric_queue)))

module Self_metrics = struct
  let on_export t signal ~batch_size =
    match signal with
    | Traces | Logs -> enqueue_self_export_metrics t signal ~batch_size
    | Metrics -> Eta.Effect.unit

  let append_to_metrics_batch t batch =
    batch @ self_export_metrics t Metrics ~batch_size:(List.length batch)
end

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
  let request = otlp_request config ~path ~body in
  Eta_http.Observability.Tracer.request_with_retry ~enabled:false
    ~policy:otlp_retry_policy t.http_client request
  |> Eta.Effect.bind (fun response ->
         Eta_http.Body.Stream.read_all response.Eta_http.Response.body
         |> Eta.Effect.map (fun body ->
                (response.Eta_http.Response.status, body)))
  |> Eta.Effect.catch (fun error ->
         Eta.Effect.fail (`Export_error (Eta_http.Error.to_string error)))
  |> Eta.Effect.bind (fun (status, body) ->
         if status = 200 || status = 202 then Eta.Effect.unit
         else Eta.Effect.fail (`Export_error (render_http_status status body)))
  |> Eta.Effect.timeout_as (Eta.Duration.seconds 6) ~on_timeout:`Timeout
  |> Eta.Effect.named "eta_otel.export.post_json"

let post_or_deadline t config ~path ~body =
  post_effect t config ~path ~body

let export_body t config ~path ~body =
  observe_send t ~path ~body
  |> Eta.Effect.bind (fun () ->
         post_or_deadline t config ~path ~body
         |> Eta.Effect.catch (fun error ->
                observe_error t (render_export_error error)))

let export_batch t config ~signal ~path ~body ~n =
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
       ~release:(fun () -> decrement_in_flight t n)
    |> Eta.Effect.bind (fun () ->
           export_body t config ~path ~body
           |> Eta.Effect.bind (fun () ->
                  Self_metrics.on_export t signal ~batch_size:n)))

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

let encode_signal t config = function
  | Trace_batch batch ->
      ( Traces,
        config.traces_path,
        List.length batch,
        encode_traces_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name batch )
  | Log_batch batch ->
      ( Logs,
        config.logs_path,
        List.length batch,
        encode_logs_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name batch )
  | Metric_batch batch ->
      ( Metrics,
        config.metrics_path,
        List.length batch,
        encode_metrics_request ~resource_attrs:config.resource_attrs
          ~scope_name:config.scope_name
          (Self_metrics.append_to_metrics_batch t batch) )

let batch_signal_name = function
  | Trace_batch _ -> "traces"
  | Log_batch _ -> "logs"
  | Metric_batch _ -> "metrics"

let export_signal t config signal =
  let name = batch_signal_name signal in
  Eta.Effect.named ("eta_otel." ^ name ^ ".encode") (Eta.Effect.sync (fun () ->
      encode_signal t config signal))
  |> Eta.Effect.bind (fun (signal, path, n, body) ->
         export_batch t config ~signal ~path ~body ~n
         |> Eta.Effect.annotate ~key:"otel.path" ~value:path
         |> Eta.Effect.annotate ~key:"otel.batch_size" ~value:(string_of_int n)
         |> Eta.Effect.named ("eta_otel.export." ^ signal_name signal))

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

let dropped t =
  Mailbox.dropped t.queue + Mailbox.dropped t.log_queue
  + Mailbox.dropped t.metric_queue

let close_mailboxes t =
  Mailbox.close t.queue;
  Mailbox.close t.log_queue;
  Mailbox.close t.metric_queue

let shutdown_http_client t =
  ignore
    (Eta.Runtime.run t.flush_rt
       (Eta_http.Client.shutdown t.http_client
       |> Eta.Effect.catch (fun _ -> Eta.Effect.unit))
      : (unit, unit) Eta.Exit.t)

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
  flush ?timeout_s t;
  shutdown_http_client t

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
  let http_client = Eta_http.Client.make_h1 ~sw ~net () in
  let config_resource = make_config_resource rt config in
  let t =
    {
      http_client;
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
