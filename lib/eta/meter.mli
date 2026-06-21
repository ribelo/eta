(** Metric observations. Implementations live behind {!Capabilities.meter};
    the runtime forwards {!Effect.metric_update} calls into the active meter
    on the runtime. *)

type kind = Capabilities.metric_kind =
  | Counter of { monotonic : bool }
  | Gauge
  | Frequency
  | Histogram of Capabilities.histogram_config
  | Summary of Capabilities.summary_config

type number = Capabilities.metric_number = Int of int | Float of float

type value = Capabilities.metric_value =
  | Number of number
  | Category of string

type point = Capabilities.metric_point = {
    name : string;
    description : string;
    unit_ : string;
    kind : kind;
    attrs : (string * string) list;
    value : value;
    ts_ms : int;
  }

val number : number -> value
val category : string -> value

val counter : ?monotonic:bool -> unit -> kind
val gauge : kind
val frequency : kind
val histogram : boundaries:float list -> kind
val summary :
  quantiles:float list -> max_age:Duration.t -> max_size:int -> kind

type in_memory

val in_memory : unit -> in_memory
(** Create a thread-safe in-memory meter. *)

val noop : Capabilities.meter
val as_capability : in_memory -> Capabilities.meter
val dump : in_memory -> point list
(** Return a synchronized snapshot of points in insertion order. *)
