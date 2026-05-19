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

type record = Capabilities.log_record = {
  level : level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

type in_memory

val in_memory : unit -> in_memory
val noop : Capabilities.logger
val as_capability : in_memory -> Capabilities.logger
val dump : in_memory -> record list
