(** Counters and gauges. Implementations live behind {!Capabilities.meter};
    the runtime forwards {!Effect.metric_update} calls into the active meter
    on the runtime. *)

type kind = Capabilities.metric_kind =
  | Counter_cumulative
  | Counter_monotonic
  | Gauge

type value = Capabilities.metric_value = Int of int | Float of float

type point : immutable_data = {
  name : string;
  description : string;
  unit_ : string;
  kind : kind;
  attrs : (string * string) list;
  value : value;
  ts_ms : int;
}

type in_memory

val in_memory : unit -> in_memory
(** Create a thread-safe in-memory meter. *)

val noop : Capabilities.meter
val as_capability : in_memory -> Capabilities.meter
val dump : in_memory -> point list
(** Return a synchronized snapshot of points in insertion order. *)
