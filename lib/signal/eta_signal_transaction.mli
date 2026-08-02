(** Uniform staging transaction for Eta_signal internals.

    A transaction owns staged cell values until it commits or rolls back.
    Current values are not mutated before commit, and a staged cell can have
    pending state for only one transaction at a time. *)

type id

type pure
type preflighted
type committed
type observers

type (+'phase, 'error) t
type 'a staged

type current_writer

val initialize_current : current_writer
val source_publication : current_writer
val observer_publication : current_writer
val timer_lifecycle : current_writer

val create_staged : 'a -> 'a staged
val current : 'a staged -> 'a
val publish_current : current_writer -> 'a staged -> 'a -> unit
(** Publish a committed current value outside a pure transaction.

    Callers must choose a writer capability that describes why the
    non-transactional current mutation is valid. This raises
    [Invalid_argument] if the cell has a pending transaction value, because
    that would bypass pure snapshot commit/rollback ordering. *)

val begin_pure : unit -> (pure, 'error) t
val id : (_, _) t -> id
val equal_id : id -> id -> bool

val read : (_, _) t -> 'a staged -> 'a
val stage : (pure, 'error) t -> 'a staged -> 'a -> unit
val staged : (_, _) t -> 'a staged -> bool
val discard : (pure, 'error) t -> 'a staged -> unit

val preflight :
  (pure, 'error) t ->
  (unit -> (unit, 'error) result) ->
  ((preflighted, 'error) t, 'error) result
(** Runs the complete fallible preflight. Failure keeps the transaction open and
    does not publish a staged cell. Success produces the only handle accepted by
    {!commit}. [sigext-zlk8] *)

val commit : (preflighted, 'error) t -> (committed, 'error) t
(** Publishes every staged cell without calling user code or returning a failure.
    [sigext-ye7i] *)

val rollback : (pure, 'error) t -> unit
