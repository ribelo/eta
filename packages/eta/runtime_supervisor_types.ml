type ('s, !'err) supervisor = {
  sw : Eio.Switch.t;
  max_failures : int option;
  failures : 'err Cause.t list Atomic.t;
  failure_count : int Atomic.t;
  children : (unit -> unit) list Atomic.t;
}

type ('s, !'err, !'a) child = {
  promise : ('a, 'err Cause.t) result Eio.Promise.t;
  cancel : unit -> unit;
}
