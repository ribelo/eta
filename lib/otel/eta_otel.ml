(* eta-otel: OTLP/JSON exporter for Eta's tracer, logger, and meter
   capabilities.

   The exporter accumulates spans, log records, and metric points on bounded
   Eta mailboxes. Eta stream pipelines batch and merge each signal; one Eta
   runtime daemon POSTs batches through eta-http with observation suppressed so
   exporter transport does not recursively emit telemetry. *)

(* ------------------------------------------------------------------ *)
(* Hex helpers                                                        *)
(* ------------------------------------------------------------------ *)

module S = Eta_stream
module Eta_stream = S.Stream
module Mailbox = S.Mailbox
module Drain_counter = S.Drain_counter

let hex_of_bytes b =
  let len = Bytes.length b in
  let out = Bytes.create (2 * len) in
  for index = 0 to len - 1 do
    let value = Char.code (Bytes.unsafe_get b index) in
    let out_index = index * 2 in
    Bytes.unsafe_set out out_index (Eta.String_helpers.lower_hex_digit (value lsr 4));
    Bytes.unsafe_set out (out_index + 1)
      (Eta.String_helpers.lower_hex_digit (value land 0xf))
  done;
  Bytes.unsafe_to_string out

let random_bytes rng n =
  let b = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set b i (Char.chr (Stdlib.Random.State.int rng 256))
  done;
  b

module Otlp_json = Otlp_json

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
  self_metrics_path : string option;
  resource_attrs : (string * string) list;
  scope_name : string;
  headers : (string * string) list;
}

type signal_batch =
  | Trace_batch of span list
  | Log_batch of Eta.Capabilities.log_record list
  | Metric_batch of Eta.Meter.point list
  | Self_metric_batch of Eta.Meter.point list

type signal_kind = Traces | Logs | Metrics | Self_metrics

let encode_traces_request = Otlp_json.encode_traces_request
let encode_logs_request = Otlp_json.encode_logs_request
let encode_metrics_request = Otlp_json.encode_metrics_request
module Metric_key = Metric_aggregation.Metric_key
let aggregate_points = Metric_aggregation.aggregate_points
(* ------------------------------------------------------------------ *)
(* OTLP/HTTP transport                                                *)
(* ------------------------------------------------------------------ *)

let otlp_retry_status = function
  | 429 | 502 | 503 | 504 -> true
  | _ -> false

let otlp_retry_policy =
  Eta_http.Retry_policy.always ~max_attempts:3
    ~retry_status:otlp_retry_status ()

let default_otlp_headers =
  Eta_http.Core.Header.unsafe_of_list
    [ ("content-type", "application/json"); ("accept", "application/json") ]

let otlp_headers config =
  List.fold_left
    (fun headers (name, value) ->
      Eta_http.Core.Header.unsafe_add name value
        (Eta_http.Core.Header.remove name headers))
    default_otlp_headers config.headers

let otlp_url config path =
  "http://" ^ config.host ^ ":" ^ string_of_int config.port ^ path

let otlp_request config ~path ~body =
  Eta_http.Request.make ~headers:(otlp_headers config)
    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
    "POST" (otlp_url config path)

let render_http_status status body =
  let len = Bytes.length body in
  let start = ref 0 in
  while !start < len && Eta.String_helpers.is_trim_space (Bytes.unsafe_get body !start) do
    incr start
  done;
  let prefix = "HTTP " ^ string_of_int status in
  if !start = len then prefix
  else
    let stop = ref len in
    while !stop > !start && Eta.String_helpers.is_trim_space (Bytes.unsafe_get body (!stop - 1)) do
      decr stop
    done;
    let body = Bytes.sub_string body !start (!stop - !start) in
    prefix ^ ": " ^ body

(* ------------------------------------------------------------------ *)
(* Exporter state                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  http_client : Eta_http.Client.t;
  clock : Eta.Capabilities.clock;
  now_ms : unit -> int;
  config : export_config;
  queue : span Mailbox.t;
  log_queue : Eta.Capabilities.log_record Mailbox.t;
  metric_queue : Eta.Meter.point Mailbox.t;
  self_metric_queue : Eta.Meter.point Mailbox.t;
  self_tracer : Eta.Tracer.in_memory;
  flush_rt : unit Eta.Runtime.t;
  context_id : int;
  mutable next_handle : int;
  table : (int, span) Hashtbl.t;
  fallback : fiber_state;
  rng : Stdlib.Random.State.t;
  in_flight : Drain_counter.t;
  mutable on_error : string -> unit;
  mutable on_send : path:string -> body:string -> unit;
}

and fiber_state = {
  mutable stack : int list;
  mutable pending_attrs : (string * string) list;
  mutable pending_links : Eta.Capabilities.span_link list;
}

let task_context_local :
    (int, fiber_state) Hashtbl.t Eta.Runtime_contract.local =
  Eta.Runtime_contract.create_local ()

let next_context_id = ref 0

let fresh_context_id () =
  incr next_context_id;
  !next_context_id

let empty_fiber_state () = { stack = []; pending_attrs = []; pending_links = [] }

let with_task_context contract f =
  contract.Eta.Runtime_contract.local_with_binding task_context_local
    (Hashtbl.create 1) f

let task_context contract =
  contract.Eta.Runtime_contract.local_get task_context_local

let fiber_state contract t =
  match task_context contract with
  | None -> t.fallback
  | Some context -> (
      match Hashtbl.find_opt context t.context_id with
      | Some state -> state
      | None ->
          let state = empty_fiber_state () in
          Hashtbl.add context t.context_id state;
          state)

let ms_to_ns ms = Metric_aggregation.ms_to_ns_saturating ms

let now_ns t =
  ms_to_ns (t.now_ms ())

let now_ms t = t.now_ms ()

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
  | Self_metrics -> "self_metrics"

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
  let add_queue queue length dropped metrics =
    self_metric t ~name:"eta_otel.queue.depth"
      ~description:"Current eta-otel exporter queue depth" ~unit_:"item"
      ~kind:Eta.Capabilities.Gauge ~attrs:[ ("queue", queue) ]
      ~value:(Eta.Capabilities.Int length)
    :: self_metric t ~name:"eta_otel.queue.dropped"
         ~description:"Cumulative eta-otel exporter queue drops" ~unit_:"item"
         ~kind:Eta.Capabilities.Gauge ~attrs:[ ("queue", queue) ]
         ~value:(Eta.Capabilities.Int dropped)
    :: metrics
  in
  []
  |> add_queue "self_metrics" (Mailbox.length t.self_metric_queue)
       (Mailbox.dropped t.self_metric_queue)
  |> add_queue "metrics" (Mailbox.length t.metric_queue)
       (Mailbox.dropped t.metric_queue)
  |> add_queue "logs" (Mailbox.length t.log_queue) (Mailbox.dropped t.log_queue)
  |> add_queue "traces" (Mailbox.length t.queue) (Mailbox.dropped t.queue)

let self_export_metrics t signal ~batch_size =
  let signal = signal_name signal in
  let queue_metrics = self_queue_metrics t in
  self_metric t ~name:"eta_otel.export.batches"
      ~description:"Eta-otel export batch attempts" ~unit_:"batch"
      ~kind:Eta.Capabilities.Counter_monotonic ~attrs:[ ("signal", signal) ]
      ~value:(Eta.Capabilities.Int 1)
  :: self_metric t ~name:"eta_otel.export.items"
      ~description:"Eta-otel export items attempted" ~unit_:"item"
      ~kind:Eta.Capabilities.Counter_monotonic ~attrs:[ ("signal", signal) ]
      ~value:(Eta.Capabilities.Int batch_size)
  :: self_metric t ~name:"eta_otel.in_flight"
      ~description:"Current eta-otel in-flight export work" ~unit_:"item"
      ~kind:Eta.Capabilities.Gauge ~attrs:[]
      ~value:(Eta.Capabilities.Int (Drain_counter.value t.in_flight))
  :: queue_metrics

let enqueue_self_export_metrics t config signal ~batch_size =
  match config.self_metrics_path with
  | None -> Eta.Effect.unit
  | Some _ ->
      Eta.Effect.named "eta_otel.self_metrics.enqueue"
        (Eta.Effect.sync (fun () ->
             self_export_metrics t signal ~batch_size
             |> List.iter (enqueue t t.self_metric_queue)))

module Self_metrics = struct
  let on_export t config signal ~batch_size =
    match signal with
    | Traces | Logs | Metrics ->
        enqueue_self_export_metrics t config signal ~batch_size
    | Self_metrics -> Eta.Effect.unit
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
  export_body t config ~path ~body
  |> Eta.Effect.bind (fun () -> Self_metrics.on_export t config signal ~batch_size:n)

let signal_batches t =
  let traces =
    Mailbox.to_batch_stream ~max:32 t.queue
    |> Eta_stream.map (fun batch -> Trace_batch batch)
  in
  let logs =
    Mailbox.to_batch_stream ~max:64 t.log_queue
    |> Eta_stream.map (fun batch -> Log_batch batch)
  in
  let metrics =
    Mailbox.to_batch_stream ~max:128 t.metric_queue
    |> Eta_stream.map (fun batch -> Metric_batch batch)
  in
  let self_metrics =
    Mailbox.to_batch_stream ~max:128 t.self_metric_queue
    |> Eta_stream.map (fun batch -> Self_metric_batch batch)
  in
  Eta_stream.merge traces
    (Eta_stream.merge logs (Eta_stream.merge metrics self_metrics))

let signal_details config = function
  | Trace_batch batch ->
      (Traces, config.traces_path, List.length batch)
  | Log_batch batch ->
      (Logs, config.logs_path, List.length batch)
  | Metric_batch batch ->
      (Metrics, config.metrics_path, List.length batch)
  | Self_metric_batch batch -> (
      match config.self_metrics_path with
      | Some path -> (Self_metrics, path, List.length batch)
      | None ->
          invalid_arg
            "eta-otel: self metrics batch exists while self metrics are disabled")

let encode_signal_body t config = function
  | Trace_batch batch ->
      encode_traces_request ~resource_attrs:config.resource_attrs
        ~scope_name:config.scope_name batch
  | Log_batch batch ->
      encode_logs_request ~resource_attrs:config.resource_attrs
        ~scope_name:config.scope_name batch
  | Metric_batch batch ->
      encode_metrics_request ~resource_attrs:config.resource_attrs
        ~scope_name:config.scope_name batch
  | Self_metric_batch batch ->
      encode_metrics_request ~resource_attrs:config.resource_attrs
        ~scope_name:config.scope_name batch

let batch_signal_name = function
  | Trace_batch _ -> "traces"
  | Log_batch _ -> "logs"
  | Metric_batch _ -> "metrics"
  | Self_metric_batch _ -> "self_metrics"

let max_self_spans = 64

let export_signal t config signal =
  let name = batch_signal_name signal in
  let signal_kind, path, n = signal_details config signal in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
       ~release:(fun () -> decrement_in_flight t n)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.named
             ("eta_otel." ^ name ^ ".encode")
             (Eta.Effect.sync (fun () ->
                  try Ok (encode_signal_body t config signal) with
                  | exn -> Error (Printexc.to_string exn)))
           |> Eta.Effect.bind (function
                | Error msg ->
                    (* Encoding is per batch. A bad telemetry value should
                       drop that batch and release its in-flight count, not
                       terminate the shared exporter daemon for future items. *)
                    observe_error t
                      (Printf.sprintf "OTLP %s encode failed: %s" name msg)
                | Ok body ->
                    export_batch t config ~signal:signal_kind ~path ~body ~n
                    |> Eta.Effect.annotate ~key:"otel.path" ~value:path
                    |> Eta.Effect.annotate ~key:"otel.batch_size"
                         ~value:(string_of_int n)
                    |> Eta.Effect.named
                         ("eta_otel.export." ^ signal_name signal_kind))))
  |> Eta.Effect.finally
       (Eta.Effect.sync (fun () ->
            Eta.Tracer.retain_recent t.self_tracer ~max:max_self_spans))

let export_program t =
  let config = t.config in
  signal_batches t
  |> Eta_stream.flat_map_par ~max_concurrency:3 (fun signal ->
         Eta_stream.from_effect (export_signal t config signal))
  |> S.run_drain
  |> Eta.Effect.named "eta_otel.exporter"

let start_daemon rt eff =
  match Eta.Runtime.run rt (Eta.Effect.daemon eff) with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error _ -> ()

let dropped t =
  Mailbox.dropped t.queue + Mailbox.dropped t.log_queue
  + Mailbox.dropped t.metric_queue
  + Mailbox.dropped t.self_metric_queue

let in_flight t = Drain_counter.value t.in_flight

let queue_depth t =
  Mailbox.length t.queue + Mailbox.length t.log_queue
  + Mailbox.length t.metric_queue
  + Mailbox.length t.self_metric_queue

let close_mailboxes t =
  Mailbox.close t.queue;
  Mailbox.close t.log_queue;
  Mailbox.close t.metric_queue;
  Mailbox.close t.self_metric_queue

let shutdown_http_client t =
  ignore
    (Eta.Runtime.run t.flush_rt
       (Eta_http.Client.shutdown t.http_client |> Eta.Effect.ignore_errors)
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
          t.clock#sleep (duration_of_timeout_s timeout_s)))
    in
    ignore
      (Eta.Runtime.run t.flush_rt (Eta.Effect.race [ wait; timeout ])
        : (unit, unit) Eta.Exit.t);
    Eta.Tracer.retain_recent t.self_tracer ~max:max_self_spans

let shutdown ?timeout_s t =
  close_mailboxes t;
  flush ?timeout_s t;
  shutdown_http_client t

let start_exporters t ~rt =
  start_daemon rt (export_program t)

(* ------------------------------------------------------------------ *)
(* Tracer methods                                                     *)
(* ------------------------------------------------------------------ *)

let resolve_parent t ?trace_id ?(trace_flags = 1) ?(trace_state = [])
    ?(baggage = []) = function
  | None, None ->
      ( Option.value trace_id ~default:(hex_of_bytes (random_bytes t.rng 16)),
        None,
        trace_flags,
        trace_state,
        baggage )
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

let begin_span contract t ?parent_id ?external_parent ?trace_id ?trace_flags
    ?trace_state ?baggage ?(kind = Eta.Capabilities.Internal) ~name
    ~started_ms () =
  let state = fiber_state contract t in
  let parent_id =
    match parent_id with
    | Some _ as parent -> parent
    | None -> List.find_opt (fun _ -> true) state.stack
  in
  let trace_id, parent_span_id, trace_flags, trace_state, baggage =
    resolve_parent t ?trace_id ?trace_flags ?trace_state ?baggage
      (parent_id, external_parent)
  in
  let span_id = hex_of_bytes (random_bytes t.rng 8) in
  let start_unix_ns = ms_to_ns started_ms in
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
  s.attrs <- List.rev state.pending_attrs;
  s.links <- List.rev state.pending_links;
  state.pending_attrs <- [];
  state.pending_links <- [];
  state.stack <- handle :: state.stack;
  Hashtbl.replace t.table handle s;
  handle

let map_status (st : Eta.Capabilities.span_status) =
  match st with
  | Eta.Capabilities.Ok -> (1, "")
  | Eta.Capabilities.Error msg -> (2, msg)
  | Eta.Capabilities.Cancelled -> (2, "cancelled")

let end_span contract t ~span_id ~status ~ended_ms =
  let state = fiber_state contract t in
  state.stack <- List.filter (fun id -> id <> span_id) state.stack;
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      Hashtbl.remove t.table span_id;
      s.end_unix_ns <- ms_to_ns ended_ms;
      let code, message = map_status status in
      s.status_code <- code;
      s.status_message <- message;
      enqueue t t.queue s

let add_attr contract t ~key ~value =
  let state = fiber_state contract t in
  match state.stack with
  | span_id :: _ -> (
      match Hashtbl.find_opt t.table span_id with
      | Some s -> s.attrs <- (key, value) :: s.attrs
      | None -> ())
  | [] -> state.pending_attrs <- (key, value) :: state.pending_attrs

let add_attr_to t ~span_id ~key ~value =
  match Hashtbl.find_opt t.table span_id with
  | Some s -> s.attrs <- (key, value) :: s.attrs
  | None -> ()

let add_event t ~span_id ~name ~ts_ms ~attrs =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      let ts_ns = if ts_ms = 0 then now_ns t else ms_to_ns ts_ms in
      s.events <- (name, ts_ns, attrs) :: s.events

let add_link contract t link =
  let state = fiber_state contract t in
  match state.stack with
  | span_id :: _ -> (
      match Hashtbl.find_opt t.table span_id with
      | Some s -> s.links <- link :: s.links
      | None -> ())
  | [] -> state.pending_links <- link :: state.pending_links

let add_link_to t ~span_id link =
  match Hashtbl.find_opt t.table span_id with
  | Some s -> s.links <- link :: s.links
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

let debug_on_send ~path ~body =
  prerr_endline
    (Printf.sprintf "[eta-otel] POST %s (%d bytes)" path (String.length body))

type runtime_factory = Eta.Capabilities.tracer -> unit Eta.Runtime.t

let default_now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let default_clock : Eta.Capabilities.clock =
  object
    method sleep duration =
      let seconds = Eta.Duration.to_seconds_float duration in
      if seconds > 0.0 then Unix.sleepf seconds
  end

let create ~runtime_factory ?flush_runtime_factory ?http_client
    ?(clock = default_clock) ?(now_ms = default_now_ms)
    ?(host = "127.0.0.1") ?(port = 4318)
    ?(traces_path = "/v1/traces") ?(logs_path = "/v1/logs")
    ?(metrics_path = "/v1/metrics") ?self_metrics_path
    ?(disable_self_metrics = false) ?(debug = false) ?(service_name = "eta")
    ?service_version ?(resource_attrs = []) ?(scope_name = "eta")
    ?(headers = []) ?(queue_capacity = 1024) ?on_error ?on_send () =
  let self_metrics_path =
    match (disable_self_metrics, self_metrics_path) with
    | true, Some _ ->
        invalid_arg
          "Eta_otel.create: disable_self_metrics conflicts with self_metrics_path"
    | true, None -> None
    | false, Some path -> Some path
    | false, None -> Some metrics_path
  in
  let on_error =
    Option.value on_error ~default:(fun msg ->
        prerr_endline ("[eta-otel] export failed: " ^ msg))
  in
  let on_send =
    let user_on_send =
      Option.value on_send ~default:(fun ~path:_ ~body:_ -> ())
    in
    fun ~path ~body ->
      if debug then debug_on_send ~path ~body;
      user_on_send ~path ~body
  in
  let resource_attrs =
    ("service.name", service_name)
    ::
    (match service_version with
    | Some v -> ("service.version", v) :: resource_attrs
    | None -> resource_attrs)
  in
  let rng = Stdlib.Random.State.make_self_init () in
  let self_tracer = Eta.Tracer.in_memory () in
  let self_tracer_cap = Eta.Tracer.as_capability self_tracer in
  let rt = runtime_factory self_tracer_cap in
  let flush_rt : unit Eta.Runtime.t =
    match flush_runtime_factory with
    | Some make -> make self_tracer_cap
    | None -> runtime_factory self_tracer_cap
  in
  let config =
    {
      host;
      port;
      traces_path;
      logs_path;
      metrics_path;
      self_metrics_path;
      resource_attrs;
      scope_name;
      headers;
    }
  in
  let http_client =
    Option.value http_client ~default:(Eta_http.Client.make_runtime ())
  in
  let t =
    {
      http_client;
      clock;
      now_ms;
      config;
      queue = Mailbox.create ~capacity:queue_capacity ();
      log_queue = Mailbox.create ~capacity:queue_capacity ();
      metric_queue = Mailbox.create ~capacity:queue_capacity ();
      self_metric_queue = Mailbox.create ~capacity:queue_capacity ();
      self_tracer;
      flush_rt;
      context_id = fresh_context_id ();
      next_handle = 1;
      table = Hashtbl.create 64;
      fallback = empty_fiber_state ();
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
    method with_task_context :
        'a. Eta.Runtime_contract.t -> (unit -> 'a) -> 'a =
      with_task_context

    method begin_span contract ?parent_id ?external_parent ?trace_id ?trace_flags
        ?trace_state ?baggage ?kind ~name ~started_ms () =
      begin_span contract t ?parent_id ?external_parent ?trace_id ?trace_flags
        ?trace_state ?baggage ?kind ~name ~started_ms ()

    method end_span contract ~span_id ~status ~ended_ms =
      end_span contract t ~span_id ~status ~ended_ms

    method add_attr contract ~key ~value = add_attr contract t ~key ~value
    method add_attr_to _ ~span_id ~key ~value = add_attr_to t ~span_id ~key ~value
    method add_event _ ~span_id ~name ~ts_ms ~attrs =
      add_event t ~span_id ~name ~ts_ms ~attrs
    method add_link contract link = add_link contract t link
    method add_link_to _ ~span_id link = add_link_to t ~span_id link
    method inspect _ ~span_id = inspect t ~span_id
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
  let self_spans t = Eta.Tracer.dump t.self_tracer
end
