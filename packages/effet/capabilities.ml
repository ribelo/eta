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

let clock_of_eio (c : _ Eio.Std.r) : clock =
  let c = (c :> float Eio.Time.clock_ty Eio.Std.r) in
  object
    method sleep d = Eio.Time.sleep c (Duration.to_seconds_float d)
  end
