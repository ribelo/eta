type kind = Capabilities.metric_kind =
  | Counter_cumulative
  | Counter_monotonic
  | Gauge

type value = Capabilities.metric_value = Int of int | Float of float

type point = {
  name : string;
  description : string;
  unit_ : string;
  kind : kind;
  attrs : (string * string) list;
  value : value;
  ts_ms : int;
}

type in_memory = { mutex : Sync_lock.t; mutable points : point list }

let in_memory () = { mutex = Sync_lock.create (); points = [] }

let with_lock t f = Sync_lock.use t.mutex f

let push t p = with_lock t (fun () -> t.points <- p :: t.points)
let dump t = with_lock t (fun () -> List.rev t.points)

let as_capability t : Capabilities.meter =
  object
    method record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms =
      push t { name; description; unit_; kind; attrs; value; ts_ms }
  end

let noop : Capabilities.meter =
  object
    method record ~name:_ ~description:_ ~unit_:_ ~kind:_ ~attrs:_ ~value:_
        ~ts_ms:_ =
      ()
  end
