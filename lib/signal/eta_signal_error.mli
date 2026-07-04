(** Shared error variants and renderers for Eta_signal internals. *)

type graph_error =
  [ `Ambiguous_scope
  | `Counter_overflow of string
  | `Cycle
  | `Invalid_scope
  | `Reentrant_stabilization
  | `Runtime_mismatch
  | `Reentrant_update ]

type observer_read_error =
  [ `Disposed_observer
  | `Invalid_scope
  | `No_current_value
  | `Uninitialized_observer ]

type 'observer_error stabilize_error =
  [ graph_error | `Observer_error of 'observer_error ]

type time_error =
  [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]

type stream_error = [ graph_error | `Invalid_capacity ]

val pp_graph_error : Format.formatter -> graph_error -> unit
val pp_observer_read_error : Format.formatter -> observer_read_error -> unit

val pp_stabilize_error :
  (Format.formatter -> 'observer_error -> unit) ->
  Format.formatter ->
  'observer_error stabilize_error ->
  unit

val pp_time_error : Format.formatter -> time_error -> unit
val pp_stream_error : Format.formatter -> stream_error -> unit
