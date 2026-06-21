class type clock = object
  method sleep : Duration.t -> unit
end

module P_atomic = Atomic

type random = { seed : int P_atomic.t } [@@unboxed]

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

type metric_number = Int of int | Float of float
type histogram_config = { boundaries : float list }

type summary_config = {
  quantiles : float list;
  max_age : Duration.t;
  max_size : int;
}

type metric_kind =
  | Counter of { monotonic : bool }
  | Gauge
  | Frequency
  | Histogram of histogram_config
  | Summary of summary_config

type metric_value = Number of metric_number | Category of string

type metric_point = {
  name : string;
  description : string;
  unit_ : string;
  kind : metric_kind;
  attrs : (string * string) list;
  value : metric_value;
  ts_ms : int;
}

class type tracer = object
  method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a
  method begin_span :
    Runtime_contract.t ->
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
  method end_span :
    Runtime_contract.t -> span_id:int -> status:span_status -> ended_ms:int -> unit
  method add_attr : Runtime_contract.t -> key:string -> value:string -> unit
  method add_attr_to :
    Runtime_contract.t -> span_id:int -> key:string -> value:string -> unit
  method add_event :
    Runtime_contract.t ->
    span_id:int ->
    name:string ->
    ts_ms:int ->
    attrs:(string * string) list ->
    unit
  method add_link : Runtime_contract.t -> span_link -> unit
  method add_link_to : Runtime_contract.t -> span_id:int -> span_link -> unit
  method inspect : Runtime_contract.t -> span_id:int -> span_info option
end

class type logger = object
  method log : log_record -> unit
end

class type meter = object
  method record : metric_point -> unit
end

let random_mask = max_int
let random_multiplier = 1_752_450_205_419_405_101
let random_increment = 1_442_695_040_888_963_407
let random_float_denominator = 9_007_199_254_740_992.0

let random_of_seed seed = { seed = P_atomic.make (seed land random_mask) }

let random_set_seed random seed =
  P_atomic.set random.seed (seed land random_mask)

let random_default () = random_of_seed 0x5eed5

let next_seed seed =
  ((seed * random_multiplier) + random_increment) land random_mask

let rec advance_random random =
  let seed = P_atomic.get random.seed in
  let next = next_seed seed in
  if P_atomic.compare_and_set random.seed seed next then next
  else advance_random random

let random_float random bound =
  if bound <= 0.0 then 0.0
  else
    let seed = advance_random random in
    bound *. (float_of_int (seed lsr 9) /. random_float_denominator)
