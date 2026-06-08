type level = Info | Warn | Error
type path = Handler | Fiber_local_fallback | Domain_local_fallback

type record = {
  level : level;
  body : string;
  path : path;
  domain_id : int;
}

type sink

exception Not_configured

val create_sink : unit -> sink
val dump : sink -> record list
val clear : sink -> unit
val info : string -> unit

module Runtime : sig
  val run : sink -> (unit -> 'a) -> 'a
  val run_no_eio : sink -> (unit -> 'a) -> 'a
  val both : (unit -> unit) -> (unit -> unit) -> unit
  val spawn_domain : (unit -> 'a) -> 'a Domain.t
end
