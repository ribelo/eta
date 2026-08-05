(** Physical transaction identity and typed staged cells. *)

type id

type planning
type sealed
type committed

type (+'phase, 'error) t
type 'a staged
type workspace

type current_writer

val initialize_current : current_writer
val source_publication : current_writer
val observer_publication : current_writer
val timer_lifecycle : current_writer

val create_staged : 'a -> 'a staged
val current : 'a staged -> 'a
val publish_current : current_writer -> 'a staged -> 'a -> unit

val create_workspace : unit -> workspace
val begin_planning : workspace -> (planning, 'error) t
val release_workspace : workspace -> (_, _) t -> unit
val id : (_, _) t -> id
val equal_id : id -> id -> bool

val read : (_, _) t -> 'a staged -> 'a
val stage : (planning, 'error) t -> 'a staged -> 'a -> unit
val staged : (_, _) t -> 'a staged -> bool
val discard : (planning, 'error) t -> 'a staged -> unit

val seal :
  (planning, 'error) t ->
  (unit -> (unit, 'error) result) ->
  ((sealed, 'error) t, 'error) result
(** Complete fallible validation. Failure leaves committed cells unchanged and
    keeps the transaction in planning. Success returns the only phase accepted
    by [commit]. *)

val commit : (sealed, 'error) t -> (committed, 'error) t
(** Publish staged cells. This function is total after [seal]. *)

val rollback : (_, 'error) t -> unit
