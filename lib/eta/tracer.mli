type status = Capabilities.span_status = Ok | Error of string | Cancelled
type kind = Capabilities.span_kind = Internal | Server | Client | Producer | Consumer

type event : immutable_data = {
  global_ ev_name : string;
  ev_ts_ms : int;
  global_ ev_attrs : (string * string) list;
}

type link = Capabilities.span_link = {
  global_ link_trace_id : string;
  global_ link_span_id : string;
  global_ link_attrs : (string * string) list;
}

type span : immutable_data = {
  span_id : int;
  parent_id : int option;
  global_ name : string;
  global_ attrs : (string * string) list;
  global_ events : event list;
  global_ links : link list;
  kind : kind;
  status : status;
  started_ms : int;
  ended_ms : int;
  global_ trace_id : string;
  trace_flags : int;
  global_ trace_state : (string * string) list;
  global_ baggage : (string * string) list;
  global_ external_parent : Capabilities.trace_context option;
}

type in_memory

val in_memory : unit -> in_memory
val with_fiber_context : (unit -> 'a) -> 'a
val noop : Capabilities.tracer
val as_capability : in_memory -> Capabilities.tracer
val dump : in_memory -> span list
val retain_recent : in_memory -> max:int -> unit
