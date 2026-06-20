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
(** Create a thread-safe in-memory logger. *)

val noop : Capabilities.logger
val as_capability : in_memory -> Capabilities.logger
val dump : in_memory -> record list
(** Return a synchronized snapshot of records in insertion order. *)

val format_pretty : record -> string
(** Render a record for human terminal inspection. *)

val format_logfmt : record -> string
(** Render a record as one logfmt line. Raises [Invalid_argument] if an
    attribute key cannot be represented as a logfmt label. *)

val format_json : record -> string
(** Render a record as one JSON object on a single line. *)

val with_min_level : level -> Capabilities.logger -> Capabilities.logger
(** Drop records below the given severity threshold. *)

val console_pretty :
  ?stdout:(string -> unit) ->
  ?stderr:(string -> unit) ->
  ?min_level:level ->
  unit ->
  Capabilities.logger
(** Console sink using {!format_pretty}. [Error] and [Fatal] records go to
    [stderr]; all other levels go to [stdout]. *)

val console_logfmt :
  ?stdout:(string -> unit) ->
  ?stderr:(string -> unit) ->
  ?min_level:level ->
  unit ->
  Capabilities.logger
(** Console sink using {!format_logfmt}. [Error] and [Fatal] records go to
    [stderr]; all other levels go to [stdout]. *)

val console_json :
  ?stdout:(string -> unit) ->
  ?stderr:(string -> unit) ->
  ?min_level:level ->
  unit ->
  Capabilities.logger
(** Console sink using {!format_json}. [Error] and [Fatal] records go to
    [stderr]; all other levels go to [stdout]. *)
