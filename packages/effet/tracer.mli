type status = Capabilities.span_status = Ok | Error of string | Cancelled

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
  status : status;
  started_ms : int;
  ended_ms : int;
  trace_id : string;
  external_parent : (string * string) option;
}

type in_memory

val in_memory : unit -> in_memory
val noop : Capabilities.tracer
val as_capability : in_memory -> Capabilities.tracer
val dump : in_memory -> span list
