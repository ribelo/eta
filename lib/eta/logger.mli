(** Application-level logging surface. Implementations live behind
    {!Capabilities.logger}; the runtime fills [trace_id] / [span_id] from
    the active span automatically when interpreting {!Effect.log}. *)

type level = Capabilities.log_level =
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal

type record : immutable_data = Capabilities.log_record = {
  level : level;
  global_ body : string;
  ts_ms : int;
  global_ attrs : (string * string) list;
  global_ trace_id : string;
  global_ span_id : string;
}

type in_memory

val in_memory : unit -> in_memory
(** Create a thread-safe in-memory logger. *)

val noop : Capabilities.logger
val as_capability : in_memory -> Capabilities.logger
val dump : in_memory -> record list
(** Return a synchronized snapshot of records in insertion order. *)
