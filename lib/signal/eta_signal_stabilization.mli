(** Stabilization phase state for Eta_signal internals. *)

type idle
type pure
type delivering

type +'state token

type state =
  | Idle
  | Pure
  | Delivering

type t

val create : unit -> t
val state : t -> state
val is_pure : t -> bool

val begin_pure :
  t -> (pure token, [> `Reentrant_stabilization ]) result

val commit_to_delivering : t -> pure token -> delivering token
val rollback_to_idle : t -> pure token -> idle token
val finish : t -> unit
