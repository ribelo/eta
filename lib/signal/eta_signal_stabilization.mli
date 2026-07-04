(** Stabilization phase state for Eta_signal internals. *)

type idle
type pure
type delivering

type +'state token

type state =
  | Idle
  | Pure
  | Delivering

type 'error t

val create : unit -> 'error t
val state : 'error t -> state
val is_pure : 'error t -> bool

val begin_pure :
  'error t -> (pure token, [> `Reentrant_stabilization ]) result

val transaction :
  'error t ->
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t option

val active_transaction :
  'error t ->
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t

val commit_transaction : 'error t -> (unit, 'error) result
val rollback_transaction : 'error t -> unit

val commit_to_delivering : 'error t -> pure token -> delivering token
val rollback_to_idle : 'error t -> pure token -> idle token
val finish : 'error t -> unit
