type status = Capabilities.span_status = Ok | Error of string | Cancelled
type kind = Capabilities.span_kind = Internal | Server | Client | Producer | Consumer

type event = {
  ev_name : string;
  ev_ts_ms : int;
  ev_attrs : (string * string) list;
}

type link = Capabilities.span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

type span = {
  span_id : int;
  parent_id : int option;
  name : string;
  attrs : (string * string) list;
  events : event list;
  links : link list;
  kind : kind;
  status : status;
  started_ms : int;
  ended_ms : int;
  trace_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
  external_parent : Capabilities.trace_context option;
}

type in_memory

val in_memory : unit -> in_memory
val with_fiber_context : (unit -> 'a) -> 'a
val noop : Capabilities.tracer
val as_capability : in_memory -> Capabilities.tracer
val dump : in_memory -> span list
val retain_recent : in_memory -> max:int -> unit
