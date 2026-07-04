(** Stabilization phase state for Eta_signal internals. *)

type idle
type pure
type committed
type delivering

type ('owner, +'state) token
(** Phase token carrying the owner phantom of the stabilization state that
    created it. Runtime IDs still guard individual state instances. *)

type state =
  | Idle
  | Pure
  | Committed
  | Delivering

type ('owner, 'error) t

val create : unit -> ('owner, 'error) t
val state : (_, _) t -> state
val is_pure : (_, _) t -> bool

val begin_pure :
  ('owner, 'error) t ->
  (('owner, pure) token, [> `Reentrant_stabilization ]) result

val transaction :
  (_, 'error) t ->
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t option

val active_transaction :
  (_, 'error) t ->
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t

val commit_transaction : (_, 'error) t -> (unit, 'error) result
val rollback_transaction : (_, _) t -> unit

val commit_to_committed :
  ('owner, _) t -> ('owner, pure) token -> ('owner, committed) token

val collect_to_delivering :
  ('owner, _) t -> ('owner, committed) token -> ('owner, delivering) token

val commit_to_delivering :
  ('owner, _) t -> ('owner, pure) token -> ('owner, delivering) token

val rollback_to_idle :
  ('owner, _) t -> ('owner, pure) token -> ('owner, idle) token

val finish_delivering :
  ('owner, _) t -> ('owner, delivering) token -> ('owner, idle) token
