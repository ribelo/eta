(** Incremental-style reactive signals for Eta.

    Each functor application owns one graph. Signals describe graph structure;
    observer handles are the public read surface for stabilized derived values. *)

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module Make (Observer_error : Observer_error) : sig
  type observer_error = Observer_error.t

  type graph_error =
    [ `Ambiguous_scope
    | `Cycle
    | `Invalid_scope
    | `Reentrant_stabilization
    | `Reentrant_update ]

  type observer_read_error =
    [ `Disposed_observer | `No_current_value | `Uninitialized_observer ]

  type stabilize_error = [ graph_error | `Observer_error of observer_error ]

  type time_error = [ `Invalid_interval | `Past_deadline ]

  type 'a var
  type 'a signal
  type 'a observer

  type 'a update =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  type stats = {
    stabilization_count : int;
    active_observer_count : int;
    necessary_node_count : int;
    stale_node_count : int;
    recompute_count : int;
    dynamic_scope_invalidations : int;
    nodes_became_necessary : int;
    nodes_became_unnecessary : int;
  }

  val pp_graph_error : Format.formatter -> graph_error -> unit
  val pp_observer_read_error : Format.formatter -> observer_read_error -> unit
  val pp_stabilize_error : Format.formatter -> stabilize_error -> unit
  val pp_time_error : Format.formatter -> time_error -> unit

  module Var : sig
    type 'a t = 'a var

    val create : ?equal:('a -> 'a -> bool) -> 'a -> 'a t
    val value : 'a t -> 'a
    val watch : 'a t -> 'a signal
    val set : 'a t -> 'a -> (unit, 'err) Eta.Effect.t

    val update_effect :
      'a t ->
      ('a -> ('a, 'err) Eta.Effect.t) ->
      ('a, [> `Reentrant_update ] as 'err) Eta.Effect.t
  end

  module Observer : sig
    type 'a t = 'a observer

    val observe :
      ?equal:('a -> 'a -> bool) ->
      'a signal ->
      ('a update -> (unit, observer_error) Eta.Effect.t) ->
      ('a t, graph_error) Eta.Effect.t

    val read : 'a t -> ('a, observer_read_error) Eta.Effect.t
    val unsafe_read_exn : 'a t -> 'a
    val dispose : 'a t -> (unit, 'err) Eta.Effect.t
  end

  val const : ?equal:('a -> 'a -> bool) -> 'a -> 'a signal
  val map : ?equal:('b -> 'b -> bool) -> ('a -> 'b) -> 'a signal -> 'b signal

  val map2 :
    ?equal:('c -> 'c -> bool) ->
    ('a -> 'b -> 'c) ->
    'a signal ->
    'b signal ->
    'c signal

  val map3 :
    ?equal:('d -> 'd -> bool) ->
    ('a -> 'b -> 'c -> 'd) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal

  val map4 :
    ?equal:('e -> 'e -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal

  val map5 :
    ?equal:('f -> 'f -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal

  val map6 :
    ?equal:('g -> 'g -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal ->
    'g signal

  val map7 :
    ?equal:('h -> 'h -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal ->
    'g signal ->
    'h signal

  val map8 :
    ?equal:('i -> 'i -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal ->
    'g signal ->
    'h signal ->
    'i signal

  val map9 :
    ?equal:('j -> 'j -> bool) ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i -> 'j) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal ->
    'g signal ->
    'h signal ->
    'i signal ->
    'j signal

  val both : 'a signal -> 'b signal -> ('a * 'b) signal
  val all : ?equal:('a list -> 'a list -> bool) -> 'a signal list -> 'a list signal
  val bind : ?equal:('b -> 'b -> bool) -> 'a signal -> ('a -> 'b signal) -> 'b signal

  val stabilize : (unit, stabilize_error) Eta.Effect.t
  val stats : unit -> (stats, 'err) Eta.Effect.t
  val to_dot : unit -> (string, 'err) Eta.Effect.t

  module Time : sig
    val now :
      every:Eta.Duration.t -> unit -> (int signal, time_error) Eta.Effect.t
    (** Signal containing the runtime clock in milliseconds. The timer source
        updates the signal at [every] while the signal is necessary. It does
        not call {!stabilize}. *)

    val deadline :
      every:Eta.Duration.t ->
      int ->
      (bool signal, time_error) Eta.Effect.t
    (** [deadline ~every deadline_ms] becomes [true] after the runtime clock
        reaches [deadline_ms]. [deadline_ms] must be in the future when the
        signal is created. *)

    val after :
      every:Eta.Duration.t ->
      Eta.Duration.t ->
      (bool signal, time_error) Eta.Effect.t
    (** [after ~every duration] is a relative one-shot deadline. *)

    val interval : Eta.Duration.t -> (int signal, time_error) Eta.Effect.t
    (** Tick counter that increments after each [interval] while necessary. *)

    val step :
      every:Eta.Duration.t ->
      initial:'a ->
      ('a -> 'a) ->
      ('a signal, time_error) Eta.Effect.t
    (** Step a value with a pure function after each [every] interval while
        necessary. *)
  end

  module Stream : sig
    val observe :
      ?equal:('a -> 'a -> bool) ->
      'a signal ->
      ('a observer * ('a update, graph_error) Eta_stream.Stream.t, graph_error)
      Eta.Effect.t
  end
end
