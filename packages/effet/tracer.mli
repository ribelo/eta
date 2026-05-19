type status = Capabilities.span_status = Ok | Error of string | Cancelled

type span = {
  span_id : int;
  parent_id : int option;
  name : string;
  attrs : (string * string) list;
  status : status;
  started_ms : int;
  ended_ms : int;
}

type in_memory

val in_memory : unit -> in_memory
val noop : Capabilities.tracer
val as_capability : in_memory -> Capabilities.tracer
val dump : in_memory -> span list

