(** HTTP/2 per-stream lifecycle state.

    This layer owns eta-http's public stream lifetime around the lower-level
    HTTP/2 connection state machine. Remotely reset streams continue to occupy
    admission until the caller releases the response body. *)

type status = Active | Remote_reset | Complete | Released

type stream

type stats = {
  active : int;
  cancelled : int;
  inflight : int;
  live : int;
  opened : int;
  completed : int;
  local_resets : int;
  remote_resets : int;
  admission_rejected : int;
  max_inflight : int;
  max_concurrent : int;
}

type release = Queue_rst | No_rst

type t

val create : max_concurrent:int -> t
val open_stream : t -> tag:int -> (stream, unit) result
val id : stream -> int
val tag : stream -> int
val status : stream -> status
val is_client_stream_id : int -> bool
val find : t -> int -> stream option
val mark_remote_reset : t -> int -> unit
val mark_complete : t -> stream -> unit
val release : t -> stream -> release
val close : t -> unit
val stats : t -> stats
