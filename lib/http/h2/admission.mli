(** HTTP/2 stream admission counter.

    Remotely reset streams remain admitted until local response-body release
    observes and releases their permit. This preserves the H-D1
    ACTIVE+CANCELLED invariant used to cap churn attacks. *)

type t

type permit

type stats = {
  active : int;
  cancelled : int;
  inflight : int;
  opened : int;
  completed : int;
  local_resets : int;
  remote_resets : int;
  admission_rejected : int;
  max_inflight : int;
  max_concurrent : int;
}

type release = Queue_rst | No_rst

val create : max_concurrent:int -> t
val try_acquire : t -> (permit, unit) result
val stream_id : permit -> int
val mark_remote_reset : t -> permit -> unit
val mark_complete : t -> permit -> unit
val release : t -> permit -> release
val close : t -> unit
val stats : t -> stats
