type child_registration = {
  id : int;
  cancel_child : unit -> unit;
}

type ('s, !'err) supervisor = {
  sw : Eio.Switch.t;
  max_failures : int option;
  failures : 'err Cause.t list Atomic.t;
  failure_count : int Atomic.t;
  next_child_id : int Atomic.t;
  (* Live child cancellation hooks only; child fibers unregister on settlement
     so long-lived supervisor scopes do not retain completed children. *)
  children : child_registration list Atomic.t;
}

type ('s, !'err, !'a) child = {
  promise : ('a, 'err Cause.t) result Eio.Promise.t;
  cancel : unit -> unit;
}
