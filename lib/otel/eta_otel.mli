(** OTLP/JSON exporter for Eta's tracer, logger, and meter capabilities.

    The exporter accumulates spans, log records, and metric points on bounded
    Eta mailboxes. Eta stream pipelines batch and merge the signal streams; one
    Eta runtime daemon POSTs them through eta-http to the configured
    endpoints. *)

type t

type runtime_factory = Eta.Capabilities.tracer -> unit Eta.Runtime.t
(** Build an Eta runtime for exporter-owned work using the supplied exporter
    self-tracer. Backend packages own the concrete runtime construction. *)

val create :
  runtime_factory:runtime_factory ->
  ?flush_runtime_factory:runtime_factory ->
  ?http_client:Eta_http.Client.t ->
  ?clock:Eta.Capabilities.clock ->
  ?host:string ->
  ?port:int ->
  ?traces_path:string ->
  ?logs_path:string ->
  ?metrics_path:string ->
  ?self_metrics_path:string ->
  ?disable_self_metrics:bool ->
  ?debug:bool ->
  ?service_name:string ->
  ?service_version:string ->
  ?resource_attrs:(string * string) list ->
  ?scope_name:string ->
  ?headers:(string * string) list ->
  ?queue_capacity:int ->
  ?on_error:(string -> unit) ->
  ?on_send:(path:string -> body:string -> unit) ->
  unit ->
  t
(** Construct an exporter. One Eta runtime daemon, built by [runtime_factory],
    consumes merged signal batches. [flush_runtime_factory] defaults to
    [runtime_factory] and is used for blocking [flush] and [shutdown].
    [http_client] defaults to {!Eta_http.Client.make_runtime}, so the exporter
    uses the current runtime's eta-http service unless a caller supplies a
    dedicated client. [clock] is the one monotonic clock pair used for exporter
    timestamps and waits; its [now_ms] is elapsed runtime time, not wall time.
    The default uses the platform monotonic clock. [queue_capacity] bounds each
    signal mailbox and defaults to 1024. [headers] are merged into every
    outbound OTLP/HTTP request.

    Self-metrics are exported to [self_metrics_path], which defaults to
    [metrics_path]. Set [disable_self_metrics] to [true] when the collector does
    not accept OTLP metrics; the application meter returned by {!meter} remains
    enabled. Supplying both [disable_self_metrics=true] and [self_metrics_path]
    raises [Invalid_argument].

    [debug=true] prints one line to stderr before every OTLP POST. Use [on_send]
    when tests or local tools need the full request body.

    Defaults: host="127.0.0.1", port=4318, traces_path="/v1/traces",
    logs_path="/v1/logs", metrics_path="/v1/metrics", service_name="eta". *)

val tracer : t -> Eta.Capabilities.tracer
(** Tracer adapter for Eta runtime constructors. *)

val logger : t -> Eta.Capabilities.logger
(** Logger adapter for Eta runtime constructors. *)

val meter : t -> Eta.Capabilities.meter
(** Meter adapter for Eta runtime constructors. Counter, gauge, frequency,
    histogram, and summary observations are aggregated by metric identity and
    attribute set within each batch. *)

module Cause_json : sig
  (** Structured JSON encoding of portable causes for sinks. *)

  val to_yojson :
    ('err -> Yojson.Safe.t) -> 'err Eta.Cause.Portable.t -> Yojson.Safe.t
  (** Encode a portable cause as a JSON tree. Node kinds: [fail], [die],
      [interrupt], [sequential], [concurrent], [finalizer], [suppressed].
      Anonymous interrupt [id] is [null]; defect [backtrace], [span], and
      [annotations] fields appear only when present. *)

  val to_string :
    ('err -> Yojson.Safe.t) -> 'err Eta.Cause.Portable.t -> string
  (** Compact single-line JSON rendering of {!to_yojson}. *)
end

module Terminal : sig
  (** Human-readable terminal/debug telemetry exporter.

      This exporter is separate from the OTLP HTTP exporter. It writes completed
      spans and metric points as deterministic single-line records suitable for
      local debugging and tests. Successful spans and metrics go to [stdout];
      failed or cancelled spans go to [stderr]. *)

  type t

  val create :
    ?stdout:(string -> unit) ->
    ?stderr:(string -> unit) ->
    unit ->
    t
  (** Create a terminal exporter. The default outputs append a newline and
      flush [stdout] / [stderr]. *)

  val tracer : t -> Eta.Capabilities.tracer
  (** Tracer adapter for Eta runtime constructors. *)

  val meter : t -> Eta.Capabilities.meter
  (** Meter adapter for Eta runtime constructors. *)
end

val flush : ?timeout_s:float -> t -> unit
(** Block until all in-flight signals are drained or [timeout_s] elapses. *)

val shutdown : ?timeout_s:float -> t -> unit
(** Close signal mailboxes and block until already accepted signals are drained
    or [timeout_s] elapses. Signals submitted after shutdown are dropped. *)

val dropped : t -> int
(** Number of accepted signals later dropped because a bounded exporter mailbox
    was full or closed. This includes trace, log, metric, and exporter
    self-metric mailboxes. *)

val in_flight : t -> int
(** Number of accepted signals not yet drained by the exporter. *)

val queue_depth : t -> int
(** Current total number of queued trace, log, metric, and self-metric signals. *)

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

type histogram_state = {
  count : int;
  sum : float;
  min : float option;
  max : float option;
  buckets : (float * int) list;
}

type summary_state = {
  count : int;
  sum : float;
  min : float option;
  max : float option;
  quantiles : (float * float) list;
}

type aggregate_value =
  | Sum of Eta.Capabilities.metric_number
  | Gauge of Eta.Capabilities.metric_number
  | Frequency of (string * int) list
  | Histogram of histogram_state
  | Summary of summary_state

val aggregate_points :
  Eta.Meter.point list ->
  (Metric_key.t * (aggregate_value * int * int)) list
(** Aggregate raw meter points by [(name, kind, attrs, description, unit_)].
    Gauges and cumulative counters keep the latest numeric value, monotonic
    counters sum increments, frequencies count categories, histograms aggregate
    explicit buckets, and summaries compute configured quantiles. The returned
    int pair is [(start_ts_ns, end_ts_ns)]. *)

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

  val self_spans : t -> Eta.Tracer.span list
  (** Exporter-internal Eta spans. These are recorded with an in-memory tracer
      owned by the exporter and are never sent through the OTLP sink. *)
end
(** Encoder surface for tests and benchmarks. It deliberately excludes network
    export so encoder cost can be measured without collector availability. *)
