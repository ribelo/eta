(** Canonical capability traits shipped by Eta.

    These are small object interfaces for runtime-owned services and ordinary
    application dependency records. Eta effects do not carry a universal
    environment parameter; pass dependencies to functions in normal OCaml style
    and close over them in [Effect.sync] leaves when needed. *)

(** One monotonic runtime-clock pair. [now_ms] is elapsed runtime time, not
    wall/civil time, and [sleep] must suspend on the same time base. Every Eta
    runtime supplies a runtime-backed default clock. *)
class type clock = object
  method now_ms : unit -> int
  method sleep : Duration.t -> unit
end

(** Randomness used by runtime-owned scheduling decisions such as
    {!Schedule.jittered}. This is a portable token, not an object capability,
    because object-method capabilities are nonportable across OxCaml domain
    boundaries. Portable runtimes should create one token per worker or pass
    explicit seeds from the coordinator. *)
type random

(** An optional logger. Provided as an example trait; not required. *)
class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

(** Span completion status used by {!tracer}. *)
type span_status = Ok | Error of string | Cancelled

(** OpenTelemetry span kind. *)
type span_kind = Internal | Server | Client | Producer | Consumer

(** W3C trace context plus baggage propagated across service boundaries. *)
type trace_context = {
  trace_id : string;  (** Hex 32 chars. *)
  span_id : string;  (** Hex 16 chars. *)
  trace_flags : int;  (** W3C flags byte. Bit 0 is the sampled flag. *)
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

(** Information about an active span surfaced through {!tracer.inspect}. *)
type span_info = {
  trace_id : string;  (** Hex 32 chars; empty if the tracer does not track. *)
  span_id : string;  (** Hex 16 chars; empty if the tracer does not track. *)
  name : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

(** A reference to another span that the current span is linked to.
    [trace_id] and [span_id] are hex strings; for links to in-process spans
    use {!tracer.inspect} to resolve them. *)
type span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

(** Severity for a {!log_record}. Maps to OTLP severityNumber. *)
type log_level = Trace | Debug | Info | Warn | Error | Fatal

(** A structured log record. Trace and span identifiers are populated by the
    runtime from the active span on the emitting fiber, or left empty if no
    span is active. *)
type log_record = {
  level : log_level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

(** Minimal tracing capability. Implementations may back this with an
    in-memory collector, OpenTelemetry, or a noop sink. *)
class type tracer = object
  method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a
  (** Establish per-fiber tracer state. Calls must be reentrant on the same
      runtime fiber and must isolate a newly forked fiber from inherited mutable
      tracer state. *)
  method begin_span :
    Runtime_contract.t ->
    ?parent_id:int ->
    ?external_parent:trace_context ->
    ?trace_id:string ->
    ?trace_flags:int ->
    ?trace_state:(string * string) list ->
    ?baggage:(string * string) list ->
    ?kind:span_kind ->
    name:string ->
    started_ms:int ->
    unit -> int
  method end_span :
    Runtime_contract.t -> span_id:int -> status:span_status -> ended_ms:int -> unit
  method add_attr : Runtime_contract.t -> key:string -> value:string -> unit
  method add_attr_to :
    Runtime_contract.t -> span_id:int -> key:string -> value:string -> unit
  method add_event :
    Runtime_contract.t ->
    span_id:int ->
    name:string ->
    ts_ms:int ->
    attrs:(string * string) list ->
    unit
  method add_link : Runtime_contract.t -> span_link -> unit
  method add_link_to : Runtime_contract.t -> span_id:int -> span_link -> unit
  method inspect : Runtime_contract.t -> span_id:int -> span_info option
end

(** Logging capability. Implementations may back this with an in-memory
    collector, an OTLP exporter, or a noop sink. The runtime fills
    {!log_record.trace_id} and {!log_record.span_id} from the active span
    automatically before calling {!logger.log}. *)
class type logger = object
  method log : log_record -> unit
end

(** Numeric metric observations. *)
type metric_number = Int of int | Float of float

(** Histogram bucket configuration. [boundaries] are explicit upper bounds. *)
type histogram_config = { boundaries : float list }

(** Summary quantile/window configuration. [quantiles] are probabilities in
    [[0,1]]. [max_age] and [max_size] describe the intended rolling window for
    producers/exporters that retain state across batches. Eta's in-process OTLP
    batch aggregator applies [max_size] within the current export batch. *)
type summary_config = {
  quantiles : float list;
  max_age : Duration.t;
  max_size : int;
}

(** Metric instrument kind. Implementations may accumulate in memory or stream
    to an OTLP exporter. *)
type metric_kind =
  | Counter of { monotonic : bool }
      (** [monotonic=true] observations are increments summed within an export
          window. [monotonic=false] observations are cumulative values and keep
          the latest value in the export window. *)
  | Gauge
  | Frequency
  | Histogram of histogram_config
  | Summary of summary_config

type metric_value =
  | Number of metric_number
  | Category of string

type metric_point = {
  name : string;
  description : string;
  unit_ : string;
  kind : metric_kind;
  attrs : (string * string) list;
  value : metric_value;
  ts_ms : int;
}

class type meter = object
  method record : metric_point -> unit
end

(** Create a portable random token from an explicit seed. *)
val random_of_seed : int -> random

(** Reset a portable random token to an explicit seed. Intended for
    deterministic test replay through eta-test. *)
val random_set_seed : random -> int -> unit

(** Deterministic fallback token. Runtimes should pass explicit seeds when
    nondeterministic jitter matters. *)
val random_default : unit -> random

(** Draw a float in [[0,bound)] from a portable random token using 53 output
    bits. *)
val random_float : random -> float -> float
