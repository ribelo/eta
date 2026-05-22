(** OTLP/JSON over HTTP/1.1 exporter for Eta's tracer, logger, and meter
    capabilities.

    Hand-rolled to keep the dependency closure to {eta, eta-stream, eio,
    eio.unix}. The exporter accumulates spans, log records, and metric points
    on bounded Eta mailboxes. Eta stream pipelines batch and merge the signal
    streams; one Eta runtime daemon POSTs them to the configured endpoints. *)

type t

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?host:string ->
  ?port:int ->
  ?traces_path:string ->
  ?logs_path:string ->
  ?metrics_path:string ->
  ?service_name:string ->
  ?service_version:string ->
  ?resource_attrs:(string * string) list ->
  ?scope_name:string ->
  ?queue_capacity:int ->
  ?on_error:(string -> unit) ->
  ?on_send:(path:string -> body:string -> unit) ->
  unit ->
  t
(** Construct an exporter. One Eta runtime daemon is started on [sw] to consume
    merged signal batches. [queue_capacity] bounds each signal mailbox and
    defaults to 1024. Defaults: host="127.0.0.1", port=4318,
    traces_path="/v1/traces", logs_path="/v1/logs",
    metrics_path="/v1/metrics", service_name="eta". *)

val tracer : t -> Eta.Capabilities.tracer
(** Tracer adapter for {!Eta.Runtime.create}. *)

val logger : t -> Eta.Capabilities.logger
(** Logger adapter for {!Eta.Runtime.create}. *)

val meter : t -> Eta.Capabilities.meter
(** Meter adapter for {!Eta.Runtime.create}. Counter values are aggregated
    by attribute set within each batch; gauges retain the latest value. *)

val flush : ?timeout_s:float -> t -> unit
(** Block until all in-flight signals are drained or [timeout_s] elapses. *)

val shutdown : ?timeout_s:float -> t -> unit
(** Close signal mailboxes and block until already accepted signals are drained
    or [timeout_s] elapses. Signals submitted after shutdown are dropped. *)

(** {1 Internals exposed for testing} *)

module Metric_key : sig
  type t = {
    name : string;
    description : string;
    unit_ : string;
    kind : Eta.Capabilities.metric_kind;
    attrs : (string * string) list;
  }
end

val aggregate_points :
  Eta.Meter.point list ->
  (Metric_key.t
  * (Eta.Capabilities.metric_value * int * int))
  list
(** Aggregate raw meter points by [(name, kind, attrs, description, unit_)].
    Gauges keep the latest value; counters sum. The returned int pair is
    [(start_ts_ns, end_ts_ns)]. *)

module Internal : sig
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

  val encode_traces_request :
    resource_attrs:(string * string) list -> scope_name:string -> span list -> string

  val encode_logs_request :
    resource_attrs:(string * string) list ->
    scope_name:string ->
    Eta.Capabilities.log_record list ->
    string

  val encode_metrics_request :
    resource_attrs:(string * string) list ->
    scope_name:string ->
    Eta.Meter.point list ->
    string

  val dropped : t -> int
  (** Number of signals dropped because a bounded mailbox was full. *)

  val self_spans : t -> Eta.Tracer.span list
  (** Exporter-internal Eta spans. These are recorded with an in-memory tracer
      owned by the exporter and are never sent through the OTLP sink. *)
end
(** Encoder surface for tests and benchmarks. It deliberately excludes network
    export so encoder cost can be measured without collector availability. *)
