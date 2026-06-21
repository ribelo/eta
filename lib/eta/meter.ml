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

let number value = Number value
let category value = Category value

let counter ?(monotonic = false) () = Counter { monotonic }
let gauge = Gauge
let frequency = Frequency

let validate_boundaries boundaries =
  let rec loop = function
    | [] | [ _ ] -> ()
    | a :: (b :: _ as rest) ->
        if not (a < b) then
          invalid_arg "Meter.histogram: boundaries must be strictly ascending";
        loop rest
  in
  loop boundaries

let histogram ~boundaries =
  validate_boundaries boundaries;
  Histogram { boundaries }

let summary ~quantiles ~max_age ~max_size =
  if max_size <= 0 then invalid_arg "Meter.summary: max_size must be positive";
  List.iter
    (fun q ->
      if q < 0.0 || q > 1.0 then
        invalid_arg "Meter.summary: quantiles must be in [0,1]")
    quantiles;
  Summary { quantiles; max_age; max_size }

type in_memory = { mutex : Sync_lock.t; mutable points : point list }

let in_memory () = { mutex = Sync_lock.create (); points = [] }

let with_lock t f = Sync_lock.use t.mutex f

let push t p = with_lock t (fun () -> t.points <- p :: t.points)
let dump t = with_lock t (fun () -> List.rev t.points)

let as_capability t : Capabilities.meter =
  object
    method record point = push t point
  end

let noop : Capabilities.meter =
  object
    method record _point = ()
  end
