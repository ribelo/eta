(** Uniform staging transaction for Eta_signal internals.

    A transaction owns staged cell values until it commits or rolls back.
    Current values are not mutated before commit, and a staged cell can have
    pending state for only one transaction at a time. *)

type id

type pure
type committed
type observers

type (+'phase, 'error) t
type 'a staged

val create_staged : 'a -> 'a staged
val current : 'a staged -> 'a
val set_current : 'a staged -> 'a -> unit

val begin_pure : unit -> (pure, 'error) t
val id : (_, _) t -> id
val equal_id : id -> id -> bool

val read : (_, _) t -> 'a staged -> 'a
val stage : (pure, 'error) t -> 'a staged -> 'a -> unit
val staged : (_, _) t -> 'a staged -> bool

val on_preflight :
  (pure, 'error) t -> (unit -> (unit, 'error) result) -> unit

val on_commit : (pure, 'error) t -> (unit -> unit) -> unit
val on_rollback : (pure, 'error) t -> (unit -> unit) -> unit

val preflight : (pure, 'error) t -> (unit, 'error) result
val commit : (pure, 'error) t -> ((committed, 'error) t, 'error) result
val rollback : (pure, 'error) t -> unit
