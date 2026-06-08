type 'a taker = {
  scheduler : Scheduler.t;
  resume : 'a -> unit;
}

type 'a t = {
  capacity : int;
  values : 'a Stdlib.Queue.t;
  takers : 'a taker Stdlib.Queue.t;
}

let create capacity =
  if capacity <= 0 then
    invalid_arg "Eta_js.Runtime_stream.create: capacity must be > 0";
  { capacity; values = Stdlib.Queue.create (); takers = Stdlib.Queue.create () }

let add t ~scheduler:_ value =
  if not (Stdlib.Queue.is_empty t.takers) then
    let taker = Stdlib.Queue.take t.takers in
    Scheduler.enqueue taker.scheduler (fun () -> taker.resume value)
  else if Stdlib.Queue.length t.values < t.capacity then Stdlib.Queue.add value t.values
  else invalid_arg "Eta_js.Runtime_stream.add: capacity exceeded"

let take t ~scheduler resume =
  if not (Stdlib.Queue.is_empty t.values) then
    let value = Stdlib.Queue.take t.values in
    Scheduler.enqueue scheduler (fun () -> resume value)
  else Stdlib.Queue.add { scheduler; resume } t.takers

let take_nonblocking t =
  if Stdlib.Queue.is_empty t.values then None else Some (Stdlib.Queue.take t.values)

let length t = Stdlib.Queue.length t.values
let taker_count t = Stdlib.Queue.length t.takers
