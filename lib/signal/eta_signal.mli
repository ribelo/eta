(** Incremental-style reactive signals for Eta.

    Each functor application owns one graph. Signals describe graph structure;
    observer handles are the public read surface for stabilized derived values.

    Equality cutoffs default to physical equality [( == )] for source vars,
    derived signals, observers, and stream bridges. That keeps the default
    cheap, but callers that publish mutable values or allocate fresh structural
    values should usually supply [?equal]. In the examples below, [S] is a
    signal module produced by {!Make}.

    Mutating a heap block in place and setting the same block is suppressed by
    the default cutoff:

    {[
      let block = [| 1 |] in
      let source = S.Var.create block in
      let _value = S.Var.watch source |> S.map (fun block -> block.(0)) in

      block.(0) <- 2;
      S.Var.set source block
      (* Same heap object: no source change is published. *)
    ]}

    Freshly allocated but structurally equal values are changes by default:

    {[
      let _parity =
        S.Var.watch source |> S.map (fun value -> [| value mod 2 |])
      in

      S.Var.set source 2
      (* If the previous source value was 0, [parity] emits a change because
         the two arrays are different heap objects. *)
    ]}

    Provide a structural cutoff when structural equality is the desired
    behavior:

    {[
      let array_equal left right =
        Array.length left = Array.length right
        && Array.for_all2 Int.equal left right
      in
      let parity =
        S.Var.watch source
        |> S.map ~equal:array_equal (fun value -> [| value mod 2 |])
      in
      parity
    ]}

    A graph is single-domain: create and use all vars, signals, observers, and
    stabilization effects from the domain that applied the functor. Effectful
    graph operations acquire the graph lane to serialize Eta fibers on that
    domain. Synchronous construction and read APIs are serialized only by
    same-domain cooperative execution: they do not yield, do not acquire the
    graph lane, and must remain free of Eta effect boundaries while mutating
    graph state. The graph lane is not a multi-domain mutex. Signal APIs raise
    [Invalid_argument] when called from another domain or from a runtime worker
    callback. *)

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module Make (Observer_error : Observer_error) () : sig
  type observer_error = Observer_error.t

  type graph_error =
    [ `Ambiguous_scope
    | `Cycle
    | `Invalid_scope
    | `Reentrant_stabilization
    | `Reentrant_update ]

  exception Graph_error of graph_error
  (** Raised by synchronous graph construction APIs when construction violates a
      graph contract and there is no Eta effect error channel available.
      Effectful APIs such as {!Observer.observe}, {!stabilize}, and
      {!Stream.observe} convert graph failures into typed Eta failures instead.

      Synchronous construction APIs include {!Var.watch}, {!const}, {!map},
      [map2] through [map9], {!both}, {!all}, and {!bind}. They raise
      [Graph_error `Ambiguous_scope] when a new node would be created in a phase
      without an unambiguous dynamic scope, and [Graph_error `Invalid_scope]
      when wrapping an invalidated dynamic-scope node. *)

  type observer_read_error =
    [ `Disposed_observer
    | `Invalid_scope
    | `No_current_value
    | `Uninitialized_observer ]

  type stabilize_error = [ graph_error | `Observer_error of observer_error ]

  type time_error =
    [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]
  type stream_error = [ graph_error | `Invalid_capacity ]

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
    pure_snapshot_commit_count : int;
    callback_delivery_count : int;
    total_node_count : int;
    active_observer_count : int;
    invalid_observer_count : int;
    necessary_node_count : int;
    dead_node_count : int;
    live_dirty_node_count : int;
    recompute_count : int;
    dynamic_scope_invalidations : int;
    nodes_became_necessary : int;
    nodes_became_unnecessary : int;
    stream_bridge_drop_count : int;
    lane_waiter_count : int;
    lane_cancelled_waiter_count : int;
  }
  (** Read-only graph counters for diagnostics.

      [pure_snapshot_commit_count] advances when a pure graph snapshot commits.
      [callback_delivery_count] advances only after all observer callbacks for a
      stabilization are delivered successfully. [invalid_observer_count] counts
      observer handles invalidated by dynamic-scope replacement and not yet
      disposed. [live_dirty_node_count] counts valid dirty nodes;
      [dead_node_count] counts invalid nodes retained in the bounded diagnostic
      tombstone index. [stream_bridge_drop_count] counts lossy
      {!Stream.observe} bridge updates that were acknowledged as dropped.
      [lane_waiter_count] is the number of graph-lane waiters queued behind the
      running stats read; [lane_cancelled_waiter_count] is the cumulative count
      of waiters cancelled while acquiring or owning the graph lane. *)

  type dot_scope = [ `Necessary | `All_valid | `All_including_invalid ]

  type dot_options = {
    dot_scope : dot_scope;
    dot_observers : bool;
    dot_timers : bool;
    dot_state : bool;
    dot_dynamic_scopes : bool;
  }

  val default_dot_options : dot_options
  (** Necessary-only graph dump without extra metadata. *)

  val pp_graph_error : Format.formatter -> graph_error -> unit
  val pp_observer_read_error : Format.formatter -> observer_read_error -> unit
  val pp_stabilize_error : Format.formatter -> stabilize_error -> unit
  val pp_time_error : Format.formatter -> time_error -> unit
  val pp_stream_error : Format.formatter -> stream_error -> unit

  module Var : sig
    type 'a t = 'a var

    val create : ?equal:('a -> 'a -> bool) -> 'a -> 'a t
    (** Create a source variable. Without [?equal], source updates use
        physical equality as their cutoff. *)

    val value : 'a t -> 'a
    (** Synchronously read the current source value, including values set since
        the last stabilization. *)

    val watch : 'a t -> 'a signal
    (** Synchronously create a signal for this source variable.

        Raises [Graph_error] on graph construction failures; see
        {!exception:Graph_error}. *)

    val set : 'a t -> 'a -> (unit, [> `Reentrant_update ] as 'err) Eta.Effect.t
    (** Set the source value. Sets performed from observer callbacks are
        accepted, but are published by a later explicit stabilization rather
        than by the currently running observer phase.

        Fails with [`Reentrant_update] if an effectful update currently owns
        this variable. *)

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
    (** Create a lifecycle handle for observing [signal]. Registering an
        observer does not run its callback; the first explicit stabilization
        initializes observed values and callbacks run after a consistent
        snapshot is published. If an observer is disposed before its callback is
        delivered, the collected callback is skipped.

        Without [?equal], observer callback emission uses physical equality as
        its cutoff. The observer's current value still advances to the latest
        stabilized value when a callback is suppressed.

        Callback typed failures must be returned by the effect, for example
        with [Eta.Effect.fail err]; those failures are reported by
        {!stabilize} as [`Observer_error err]. Ordinary exceptions raised while
        constructing the callback effect, or defects raised by the returned
        effect, are Eta defects, not typed observer errors. [Graph_error]
        raised from graph APIs remains a typed graph failure. *)

    val read : 'a t -> ('a, observer_read_error) Eta.Effect.t
    (** Read the last stabilized observed value. This is the primary value-read
        surface for derived values and reports invalid observer state through
        typed Eta failures.

        Returns [`Invalid_scope] when the observer was invalidated because its
        dynamic-scope signal was replaced. *)

    val unsafe_read_exn : 'a t -> 'a
    (** Synchronous read for tests and debugging. Raises when the observer is
        disposed or not initialized; normal consumers should prefer {!read}. *)

    val dispose : 'a t -> (unit, 'err) Eta.Effect.t
  end

  val const : ?equal:('a -> 'a -> bool) -> 'a -> 'a signal
  (** Constant signal. Without [?equal], the signal cutoff is physical equality.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val map : ?equal:('b -> 'b -> bool) -> ('a -> 'b) -> 'a signal -> 'b signal
  (** Map one dependency. Without [?equal], the derived-value cutoff is physical
      equality. Freshly allocated but structurally equal values are therefore
      treated as changes unless a structural [?equal] is supplied.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val map2 :
    ?equal:('c -> 'c -> bool) ->
    ('a -> 'b -> 'c) ->
    'a signal ->
    'b signal ->
    'c signal
  (** Map two dependencies. Without [?equal], the derived-value cutoff is
      physical equality. The same default applies to [map3] through [map9] and
      {!both}.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

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
  (** Collect a list of signals. Without [?equal], the list cutoff is physical
      equality.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val bind : ?equal:('b -> 'b -> bool) -> 'a signal -> ('a -> 'b signal) -> 'b signal
  (** Dynamically select a signal from the current value of another signal.
      Nodes created by an inactive branch are invalidated when that branch is
      replaced; observing a captured inactive-branch node fails with
      [`Invalid_scope].

      Without [?equal], the selected output cutoff is physical equality.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val stabilize : (unit, stabilize_error) Eta.Effect.t
  (** Run one explicit stabilization.

      Pure graph recomputation is transactional: graph failures before snapshot
      commit leave the previous stabilized snapshot in place and keep source
      updates retryable. Once a pure snapshot commits, observer current values
      and pending callback deliveries are published before timer lifecycle
      refresh, disposal cleanup, and observer callbacks run.

      Failures after that commit point, including observer callback failures,
      timer start/stop lifecycle defects, disposal-hook failures, or
      interruption, do not roll back the committed snapshot. Undelivered
      observer callbacks keep the observer's delivery cursor pending. A later
      stabilization retries delivery against the latest stabilized value, so
      intermediate failed blips are coalesced: if the value has returned to the
      observer's last successfully delivered value, the pending delivery is
      acknowledged without running a callback. Disposal or dynamic-scope
      invalidation still skips pending callbacks. *)

  val stats : unit -> (stats, 'err) Eta.Effect.t

  val to_dot : ?options:dot_options -> unit -> (string, 'err) Eta.Effect.t
  (** Return a read-only DOT dump. The default is necessary-only for compact
      demand debugging. Use [dot_scope = `All_valid] to include retained valid
      nodes that are not currently necessary, or [`All_including_invalid] to
      include invalid-node tombstones and invalid observer handles still
      retained for diagnostics. The metadata flags add observer, timer,
      dirty/queued, dependency/dependent edge counts, typed graph identity
      labels, and dynamic-scope state to the dump. *)

  module Time : sig
    (** Time nodes are demand-owned source-updating effects. They never call
        {!stabilize}; observers see timer changes only after explicit
        stabilization.

        Signal time is measured by Eta's monotonic runtime clock, not by
        wall/civil time. When a runtime-clock jump wakes several elapsed
        cadences, deadline and now nodes coalesce to the final clock-derived
        value, and interval nodes advance the counter arithmetically to the
        final saturated value before the next stabilization observes it.
        [step] nodes replay one source update per awakened cadence; large
        [step] catch-up runs yield cooperatively between internal batches. *)

    val now :
      every:Eta.Duration.t -> unit -> (int signal, time_error) Eta.Effect.t
    (** Signal containing the runtime clock in milliseconds. The timer source
        updates the signal at [every] while the signal is necessary. It does
        not call {!stabilize}. *)

    val deadline :
      every:Eta.Duration.t ->
      int ->
      (bool signal, time_error) Eta.Effect.t
    (** [deadline ~every deadline_ms] becomes [true] after the monotonic
        runtime clock reaches [deadline_ms]. [deadline_ms] must be in the
        future on that clock when the signal is created. *)

    val after :
      every:Eta.Duration.t ->
      Eta.Duration.t ->
      (bool signal, time_error) Eta.Effect.t
    (** [after ~every duration] is a relative one-shot deadline. It fails with
        [`Deadline_overflow] when the current runtime time plus [duration]
        cannot be represented. *)

    val interval : Eta.Duration.t -> (int signal, time_error) Eta.Effect.t
    (** Tick counter that increments after each [interval] while necessary.
        Clock-jump catch-up advances the counter arithmetically rather than by
        replaying every internal increment. The counter saturates at
        [max_int]. *)

    val step :
      every:Eta.Duration.t ->
      initial:'a ->
      ('a -> 'a) ->
      ('a signal, time_error) Eta.Effect.t
    (** Step a value with a pure total function after each [every] interval
        while necessary.

        Clock-jump catch-up replays [f] once per awakened cadence, so very
        large jumps can perform correspondingly large cooperative catch-up
        work.

        [f] runs in the demand-owned timer daemon, not during stabilization. If
        [f] raises, Eta reports the defect through daemon diagnostics with
        [eta_signal.time.step] context; it is not delivered as a [stabilize]
        failure. The failed daemon cleans up timer state so later demand can
        restart it. *)
  end

  module Stream : sig
    val observe :
      ?capacity:int ->
      ?on_drop:('a update -> unit) ->
      ?equal:('a -> 'a -> bool) ->
      'a signal ->
      ('a observer * ('a update, graph_error) Eta_stream.Stream.t, stream_error)
      Eta.Effect.t
    (** [observe ?capacity signal] creates an observer and a stream of observer
        updates. [capacity] defaults to [1024] and bounds the bridge queue.
        Without [?equal], stream update emission uses physical equality as its
        observer cutoff.

        Publication from stabilization is nonblocking: when the bridge already
        has [capacity] buffered updates, the newest stream update is dropped
        and stabilization continues. A later delivered change may therefore
        report an [old_value] that was not itself delivered through the stream.
        Pass [?on_drop] to observe each dropped update; the hook runs
        synchronously during observer delivery and should be reserved for
        counters, metrics, or lightweight logging. If the hook raises,
        stabilization fails with that defect, and the update can be retried by
        the next stabilization.

        Disposing the returned observer cleanly closes the stream queue.
        Buffered updates drain before the stream ends. Early stream consumers
        such as {!Eta_stream.Stream.take} do not dispose the observer; the
        returned observer remains the lifecycle handle. The returned stream is
        part of the same graph-domain contract and must be consumed on the
        graph owner domain.

        Fails with [`Invalid_capacity] when [capacity <= 0]. *)
  end
end
