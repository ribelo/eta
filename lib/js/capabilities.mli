(** Canonical capability traits shipped by eta_js. *)

class type clock = object
  method sleep : Duration.t -> unit
end

type random

class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

type span_status = Ok | Error of string | Cancelled
type span_kind = Internal | Server | Client | Producer | Consumer

type trace_context = {
  trace_id : string;
  span_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

type span_info = {
  trace_id : string;
  span_id : string;
  name : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

type span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

type log_level = Trace | Debug | Info | Warn | Error | Fatal

type log_record = {
  level : log_level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

type metric_kind =
  | Counter_cumulative
  | Counter_monotonic
  | Gauge

type metric_value = Int of int | Float of float

type runtime

class type tracer = object
  method with_task_context : 'a. runtime -> (unit -> 'a) -> 'a
  method begin_span :
    runtime ->
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
  method end_span : runtime -> span_id:int -> status:span_status -> ended_ms:int -> unit
  method add_attr : runtime -> key:string -> value:string -> unit
  method add_attr_to : runtime -> span_id:int -> key:string -> value:string -> unit
  method add_event :
    runtime ->
    span_id:int ->
    name:string ->
    ts_ms:int ->
    attrs:(string * string) list ->
    unit
  method add_link : runtime -> span_link -> unit
  method add_link_to : runtime -> span_id:int -> span_link -> unit
  method inspect : runtime -> span_id:int -> span_info option
end

class type logger = object
  method log : log_record -> unit
end

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

val random_of_seed : int -> random
val random_set_seed : random -> int -> unit
val random_default : unit -> random
val random_float : random -> float -> float
