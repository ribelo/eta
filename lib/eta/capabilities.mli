(** Canonical capability traits shipped by Eta.

    These are small object interfaces for runtime-owned services and ordinary
    application dependency records. Eta effects do not carry a universal
    environment parameter; pass dependencies to functions in normal OCaml style
    and close over them in [Effect.sync] leaves when needed. *)

(** A clock can sleep for a duration. Every Eta runtime supplies a
    default clock backed by [Eio.Time.clock]. *)
class type clock = object
  method sleep : Duration.t -> unit
end

(** Randomness used by runtime-owned scheduling decisions such as
    {!Schedule.jittered}. This is a portable token, not an object capability,
    because object-method capabilities are nonportable across OxCaml domain
    boundaries. Portable runtimes should create one token per worker or pass
    explicit seeds from the coordinator. *)
type random : value mod portable contended

(** An optional logger. Provided as an example trait; not required. *)
class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

(** Span completion status used by {!tracer}. *)
type span_status : immutable_data = Ok | Error of string | Cancelled

(** OpenTelemetry span kind. *)
type span_kind : immutable_data = Internal | Server | Client | Producer | Consumer

(** W3C trace context plus baggage propagated across service boundaries. *)
type trace_context : immutable_data = {
  global_ trace_id : string;  (** Hex 32 chars. *)
  global_ span_id : string;  (** Hex 16 chars. *)
  trace_flags : int;  (** W3C flags byte. Bit 0 is the sampled flag. *)
  global_ trace_state : (string * string) list;
  global_ baggage : (string * string) list;
}

(** Information about an active span surfaced through {!tracer.inspect}. *)
type span_info : immutable_data = {
  global_ trace_id : string;  (** Hex 32 chars; empty if the tracer does not track. *)
  global_ span_id : string;  (** Hex 16 chars; empty if the tracer does not track. *)
  global_ name : string;
  trace_flags : int;
  global_ trace_state : (string * string) list;
  global_ baggage : (string * string) list;
}

(** A reference to another span that the current span is linked to.
    [trace_id] and [span_id] are hex strings; for links to in-process spans
    use {!tracer.inspect} to resolve them. *)
type span_link : immutable_data = {
  global_ link_trace_id : string;
  global_ link_span_id : string;
  global_ link_attrs : (string * string) list;
}

(** Severity for a {!log_record}. Maps to OTLP severityNumber. *)
type log_level : immutable_data = Trace | Debug | Info | Warn | Error | Fatal

(** A structured log record. Trace and span identifiers are populated by the
    runtime from the active span on the emitting fiber, or left empty if no
    span is active. *)
type log_record : immutable_data = {
  level : log_level;
  global_ body : string;
  ts_ms : int;
  global_ attrs : (string * string) list;
  global_ trace_id : string;
  global_ span_id : string;
}

(** Minimal tracing capability. Implementations may back this with an
    in-memory collector, OpenTelemetry, or a noop sink. *)
class type tracer = object
  method with_fiber_context : 'a. (unit -> 'a) -> 'a
  method begin_span :
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
  method end_span : span_id:int -> status:span_status -> ended_ms:int -> unit
  method add_attr : key:string -> value:string -> unit
  method add_attr_to : span_id:int -> key:string -> value:string -> unit
  method add_event :
    span_id:int ->
    name:string ->
    ts_ms:int ->
    attrs:(string * string) list ->
    unit
  method add_link : span_link -> unit
  method add_link_to : span_id:int -> span_link -> unit
  method inspect : span_id:int -> span_info option
end

(** Logging capability. Implementations may back this with an in-memory
    collector, an OTLP exporter, or a noop sink. The runtime fills
    {!log_record.trace_id} and {!log_record.span_id} from the active span
    automatically before calling {!logger.log}. *)
class type logger = object
  method log : log_record -> unit
end

(** Counters and gauges for the metrics signal. Implementations may
    accumulate in memory or stream to an OTLP exporter. *)
type metric_kind : immutable_data =
  | Counter_cumulative  (** latest cumulative value for the export window *)
  | Counter_monotonic  (** monotonic increment summed within the export window *)
  | Gauge

type metric_value : immutable_data = Int of int | Float of float

class type meter = object
  method record :
    name:string ->
    description:string ->
    unit_:string ->
    kind:metric_kind ->
    attrs:(string * string) list ->
    value:metric_value ->
    ts_ms:int ->
    unit
end

(** Bridge an [Eio.Time.clock] into the [clock] trait. *)
val clock_of_eio :
  [> float Eio.Time.clock_ty ] Eio.Std.r -> clock

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
