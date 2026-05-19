(** Canonical capability traits shipped by Effet.

    These are object-type aliases that effect helpers can require via
    row polymorphism. An application's [env] is just an object that
    happens to have the methods these traits demand.

    Example:

    {[
      type env = <
        clock : Effet.Capabilities.clock;
        http  : my_http;
        ..
      >
    ]}

    Effect helpers then write:

    {[
      let sleep ms : (<clock : clock; ..>, _, unit) Effect.t = ...
    ]}

    and OCaml's row polymorphism composes them automatically. *)

(** A clock can sleep for a duration. Every Effet runtime supplies a
    default clock backed by [Eio.Time.clock]. *)
class type clock = object
  method sleep : Duration.t -> unit
end

(** An optional logger. Provided as an example trait; not required. *)
class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

(** Span completion status used by {!tracer}. *)
type span_status = Ok | Error of string | Cancelled

(** Information about an active span surfaced through {!tracer.inspect}. *)
type span_info = {
  trace_id : string;  (** Hex 32 chars; empty if the tracer does not track. *)
  span_id : string;  (** Hex 16 chars; empty if the tracer does not track. *)
  name : string;
}

(** A reference to another span that the current span is linked to.
    [trace_id] and [span_id] are hex strings; for links to in-process spans
    use {!tracer.inspect} to resolve them. *)
type span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

(** Minimal tracing capability. Implementations may back this with an
    in-memory collector, OpenTelemetry, or a noop sink. *)
class type tracer = object
  method begin_span :
    ?parent_id:int ->
    ?external_parent:string * string ->
    name:string ->
    started_ms:int ->
    unit -> int
  method end_span : span_id:int -> status:span_status -> ended_ms:int -> unit
  method add_attr : key:string -> value:string -> unit
  method add_event :
    span_id:int ->
    name:string ->
    ts_ms:int ->
    attrs:(string * string) list ->
    unit
  method add_link : span_link -> unit
  method inspect : span_id:int -> span_info option
end

(** Bridge an [Eio.Time.clock] into the [clock] trait. *)
val clock_of_eio :
  [> float Eio.Time.clock_ty ] Eio.Std.r -> clock
