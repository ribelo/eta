class type clock = object
  method sleep : Duration.t -> unit
end

class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

type span_status = Ok | Error of string | Cancelled

type span_info = {
  trace_id : string;
  span_id : string;
  name : string;
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

let clock_of_eio (c : _ Eio.Std.r) : clock =
  let c = (c :> float Eio.Time.clock_ty Eio.Std.r) in
  object
    method sleep d = Eio.Time.sleep c (Duration.to_seconds_float d)
  end
