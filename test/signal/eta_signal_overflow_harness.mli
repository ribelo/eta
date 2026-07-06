module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module Make (Observer_error : Observer_error) () : sig
  type observer_error = Observer_error.t

  type graph_error =
    [ `Ambiguous_scope
    | `Counter_overflow of string
    | `Cycle
    | `Invalid_scope
    | `Reentrant_stabilization
    | `Runtime_mismatch
    | `Reentrant_update ]

  exception Graph_error of graph_error

  type observer_read_error =
    [ `Disposed_observer
    | `Invalid_scope
    | `No_current_value
    | `Uninitialized_observer ]

  type stabilize_error = [ graph_error | `Observer_error of observer_error ]

  type time_error =
    [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]

  type 'a var
  type 'a signal
  type 'a observer
  type stats

  type 'a update =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  module Var : sig
    type 'a t = 'a var

    val create : ?equal:('a -> 'a -> bool) -> 'a -> 'a t
    val watch : 'a t -> 'a signal
    val set : 'a t -> 'a -> (unit, [> `Reentrant_update ]) Eta.Effect.t
  end

  module Observer : sig
    type 'a t = 'a observer

    val observe :
      ?equal:('a -> 'a -> bool) ->
      'a signal ->
      ('a update -> (unit, observer_error) Eta.Effect.t) ->
      ('a t, graph_error) Eta.Effect.t

    val read : 'a t -> ('a, observer_read_error) Eta.Effect.t
    val dispose : 'a t -> (unit, graph_error) Eta.Effect.t
  end

  val const : ?equal:('a -> 'a -> bool) -> 'a -> 'a signal

  val bind :
    ?equal:('b -> 'b -> bool) -> 'a signal -> ('a -> 'b signal) -> 'b signal

  val stabilize : (unit, stabilize_error) Eta.Effect.t
  val stats : unit -> (stats, graph_error) Eta.Effect.t

  module Time : sig
    val interval : Eta.Duration.t -> (int signal, time_error) Eta.Effect.t
  end

  module Overflow : sig
    type stats_counter_target =
      | Pure_snapshot_commit_count
      | Callback_delivery_count
      | Recompute_count
      | Dynamic_scope_invalidations
      | Nodes_became_necessary
      | Nodes_became_unnecessary
      | Stream_bridge_drop_count

    val stats_counter :
      name:string -> int -> (int, [> `Counter_overflow of string ]) result

    val set_signal_version : 'a signal -> int -> unit
    val set_timer_generation : int signal -> int -> unit
    val set_next_node_id : int -> (unit, 'err) Eta.Effect.t
    val set_generation : int -> (unit, 'err) Eta.Effect.t
    val set_next_timer_refresh_token : int -> (unit, 'err) Eta.Effect.t
    val set_stats_counter :
      stats_counter_target -> int -> (unit, 'err) Eta.Effect.t

    val registration_cleanup_on_error :
      cleanup:(unit -> (unit, graph_error) Eta.Effect.t) ->
      ('a, graph_error) Eta.Effect.t ->
      ('a, graph_error) Eta.Effect.t
  end
end
