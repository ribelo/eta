(** OTLP/JSON over HTTP/1.1 exporter for Effet's tracer, logger, and meter
    capabilities.

    Hand-rolled to keep the dependency closure to {effet, eio, eio.unix}. The
    exporter accumulates spans, log records, and metric points on three Eio
    streams; one background fiber per signal drains its queue, encodes a
    batch as OTLP/JSON, and POSTs it to the configured endpoint. *)

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
  ?on_error:(string -> unit) ->
  ?on_send:(path:string -> body:string -> unit) ->
  unit ->
  t
(** Construct an exporter. Three background fibers are forked on [sw], one
    per signal type. Defaults: host="127.0.0.1", port=4318,
    traces_path="/v1/traces", logs_path="/v1/logs",
    metrics_path="/v1/metrics", service_name="effet". *)

val tracer : t -> Effet.Capabilities.tracer
(** Tracer adapter for {!Effet.Runtime.create}. *)

val logger : t -> Effet.Capabilities.logger
(** Logger adapter for {!Effet.Runtime.create}. *)

val meter : t -> Effet.Capabilities.meter
(** Meter adapter for {!Effet.Runtime.create}. Counter values are aggregated
    by attribute set within each batch; gauges retain the latest value. *)

val flush : ?timeout_s:float -> t -> unit
(** Block until all in-flight signals are drained or [timeout_s] elapses. *)

(** {1 Internals exposed for testing} *)

module Metric_key : sig
  type t = {
    name : string;
    description : string;
    unit_ : string;
    kind : Effet.Capabilities.metric_kind;
    attrs : (string * string) list;
  }
end

val aggregate_points :
  Effet.Meter.point list ->
  (Metric_key.t
  * (Effet.Capabilities.metric_value * int * int))
  list
(** Aggregate raw meter points by [(name, kind, attrs, description, unit_)].
    Gauges keep the latest value; counters sum. The returned int pair is
    [(start_ts_ns, end_ts_ns)]. *)
