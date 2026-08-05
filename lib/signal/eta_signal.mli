(** Incremental-style reactive signals for Eta.

    Each functor application owns one graph. Signals describe graph structure;
    observer handles are the public read surface for stabilized derived values.

    Cutoffs default to {!Cutoff.phys_equal} for source vars, derived signals,
    observers, and stream bridges. This is a cheap identity cutoff, not a
    structural-value cutoff.

    If the value is heap-shaped, pass [?cutoff] and publish a fresh value when
    the logical content changes. Use {!Cutoff.of_equal} or
    {!Cutoff.of_compare} for structural values. Use the physical default only
    when object identity is the value semantics, for example stable immutable
    tokens. Prefer explicit structural cutoffs for arrays, records, maps, sets,
    JSON-like trees, decoded rows, and lists rebuilt by each recomputation.

    A structural cutoff cannot recover a previous snapshot after you mutate the
    same heap object in place: the graph still holds that object as the old
    value. Treat signal payloads as immutable once published, or publish a copy.
    In the examples below, [S] is a signal module produced by {!Make} or
    {!Make_no_error}.

    Mutating a heap block in place and setting the same block is suppressed by
    the default cutoff:

    {[
      let block = [| 1 |] in
      let source = S.Var.create block in
      let _value = S.Var.watch source |> S.map (fun block -> block.(0)) in

      block.(0) <- 2;
      S.Var.set source block
      (* Same heap object, and the old snapshot was mutated too:
         no source change is published. *)
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
        |> S.map ~cutoff:(Eta_signal.Cutoff.of_equal array_equal)
             (fun value -> [| value mod 2 |])
      in
      parity
    ]}

    Common structural cutoffs:

    {[
      let int_array_cutoff =
        Eta_signal.Cutoff.of_equal (Array.equal Int.equal)
      let string_list_cutoff =
        Eta_signal.Cutoff.of_equal (List.equal String.equal)

      type user = {
        id : int;
        name : string;
      }

      let user_equal left right =
        Int.equal left.id right.id && String.equal left.name right.name
      let user_cutoff = Eta_signal.Cutoff.of_equal user_equal

      module IntMap = Map.Make (Int)
      let int_map_cutoff =
        Eta_signal.Cutoff.of_equal (IntMap.equal String.equal)

      let decoded_user_row_cutoff = user_cutoff

      type view_model = {
        title : string;
        rows : string list;
      }

      let view_model_cutoff =
        Eta_signal.Cutoff.of_equal (fun left right ->
          String.equal left.title right.title
          && List.equal String.equal left.rows right.rows)

      let view_model =
        S.Var.watch model_source
        |> S.map ~cutoff:view_model_cutoff derive_view_model
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

(** Observer callback typed failures for graph instances whose callbacks cannot
    fail. *)
module No_observer_error : sig
  type t = |

  val pp : Format.formatter -> t -> unit
end

module Cutoff : sig
  type 'a t = 'a Eta_signal_cutoff.t

  val always : 'a t
  val never : 'a t
  val phys_equal : 'a t
  val of_equal : ('a -> 'a -> bool) -> 'a t
  val of_compare : ('a -> 'a -> int) -> 'a t
end
(** Immutable candidate-suppression policies. A cutoff receives the published
    value first and the candidate second. A true result suppresses the
    candidate. [always] suppresses every candidate, [never] suppresses none,
    [phys_equal] suppresses physically equal candidates, [of_equal equal]
    suppresses when [equal published candidate] is true, and
    [of_compare compare] suppresses when [compare published candidate = 0].
    The default optional cutoff is [phys_equal]. *)

module type Package_graph = sig
  type 'a signal
  type 'a plan

  type 'a change =
    | Left of 'a
    | Right of 'a
    | Changed of 'a * 'a

  type ('key, 'data, 'map) input_ops = {
    empty : 'map;
    compare_key : 'key -> 'key -> int;
    fold_symmetric_diff :
      'acc.
      'map ->
      'map ->
      on_compare:(unit -> unit) ->
      init:'acc ->
      f:('acc -> 'key -> 'data change -> 'acc) ->
      'acc;
  }

  type ('key, 'output, 'map) output_ops = {
    empty : 'map;
    set : 'key -> 'output -> 'map -> 'map;
    remove : 'key -> 'map -> 'map;
  }

  val stable_family :
    ?data_cutoff:'data Cutoff.t ->
    input:'data_map signal ->
    input_ops:('key, 'data, 'data_map) input_ops ->
    output_ops:('key, 'output, 'output_map) output_ops ->
    build:(key:'key -> data:'data signal -> 'output signal) ->
    unit ->
    'output_map plan

  val install : 'a plan -> 'a signal
end

module Owner_transaction : sig
  type t
  type 'a cell

  val create_cell : 'a -> 'a cell
  val current : 'a cell -> 'a
  val begin_ : unit -> t
  val read : t -> 'a cell -> 'a
  val stage : t -> 'a cell -> 'a -> unit
  val commit : t -> unit
  val rollback : t -> unit
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
  (** Raised by synchronous graph construction APIs when construction violates a
      graph contract and there is no Eta effect error channel available.
      Effectful APIs such as {!Observer.observe}, {!stabilize}, and
      {!Stream.observe} convert graph failures into typed Eta failures instead.

      Synchronous graph-node construction APIs include {!Var.watch}, {!const},
      {!map}, [map2] through [map9], {!all}, {!reduce_balanced}, and {!bind}.
      They raise
      [Graph_error `Ambiguous_scope] when a new node would be created in a phase
      without an unambiguous dynamic scope, and [Graph_error `Invalid_scope]
      when wrapping an invalidated dynamic-scope node. Timer-backed graph
      operations fail with [`Runtime_mismatch] if a time node is used from a
      different Eta runtime than the one that created it. They raise
      [Graph_error (`Counter_overflow name)] if an internal monotonically
      increasing graph counter reaches [max_int]; Eta signal counters do not
      wrap. *)

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

  type keyed_stats = {
    node_count : int;
    committed_child_count : int;
    reconciliation_count : int;
    input_key_comparison_count : int;
    input_diff_event_count : int;
    child_visit_count : int;
    provisional_addition_count : int;
    committed_addition_count : int;
    committed_removal_count : int;
    reconciliation_rollback_count : int;
  }
  (** Keyed-map gauges and cumulative work counters:

      - [node_count] counts current valid keyed nodes.
      - [committed_child_count] counts their current committed children.
      - [reconciliation_count] increments when a keyed plan starts.
      - [input_key_comparison_count] counts input-key comparisons.
      - [input_diff_event_count] counts input-diff events.
      - [child_visit_count] counts children that output evaluation selects.
      - [provisional_addition_count] increments when planning registers a scope.
      - [committed_addition_count] increments when pure commit adds a child.
      - [committed_removal_count] increments when pure commit removes a child.
      - [reconciliation_rollback_count] increments when a keyed plan completes
        rollback.

      A graph without keyed nodes reports zero in every field. Invalid
      tombstones do not contribute to the gauges. The cumulative counters
      saturate at [max_int] without changing graph behavior. {!stats} then fails
      with [`Counter_overflow]. [smdiag-y97e] [smdiag-xfpv] [smdiag-19k7]
      [smdiag-z8s2] [smdiag-o22x] [smdiag-709x] [smdiag-l4ra]
      [smdiag-yqlu] [smdiag-98i1] [smdiag-ss8z] *)

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
    keyed : keyed_stats;
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
      of waiters cancelled while acquiring or owning the graph lane.

      {!stats} fails with [`Counter_overflow name] if a public diagnostic count
      has reached [max_int] and would otherwise be indistinguishable from a
      saturated approximation. *)

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

    val create : ?cutoff:'a Cutoff.t -> 'a -> 'a t
    (** Create a source variable. Without [?cutoff], source updates use
        {!Cutoff.phys_equal}.

        For arrays, records, maps, lists, decoded rows, JSON-like trees, and
        other structural values, pass [?cutoff] and publish fresh values. Setting
        the same heap object after in-place mutation is suppressed by the
        default cutoff, and even a structural cutoff cannot reconstruct the
        pre-mutation snapshot if that snapshot aliases the same object.

        Prefer making the structural cutoff explicit at the source boundary:

        {[
          let source =
            S.Var.create ~cutoff:view_model_cutoff initial_view_model
          in
          (* Later updates must publish a fresh [view_model] value. *)
          S.Var.set source next_view_model
        ]}

        [Var.create] allocates a source handle, not a graph node. Source handles
        are outside dynamic scope until passed to {!watch}; {!watch} is the
        graph construction boundary that checks the current scope.

        Raises [Graph_error] if the shared graph construction counter
        overflows; see {!exception:Graph_error}. *)

    val value : 'a t -> 'a
    (** Synchronously read the current source value, including values set since
        the last stabilization.

        Raises [Graph_error `Ambiguous_scope] during pure graph recomputation.
        Use {!watch} and explicit signal combinators to declare dependencies
        instead of reading source variables from [map] or [bind] callbacks. *)

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
      ?cutoff:'a Cutoff.t ->
      'a signal ->
      ('a update -> (unit, observer_error) Eta.Effect.t) ->
      ('a t, graph_error) Eta.Effect.t
    (** Create a lifecycle handle for observing [signal]. Registering an
        observer does not run its callback; the first explicit stabilization
        initializes observed values and callbacks run after a consistent
        snapshot is published. If an observer is disposed before its callback is
        delivered, the collected callback is skipped.

        Without [?cutoff], observer callback emission uses {!Cutoff.phys_equal}.
        The observer's current value still advances to the latest stabilized
        value when a callback is suppressed. Pass [?cutoff] for structural
        observer values when callbacks must represent logical content changes
        rather than heap identity changes:

        {[
          S.Observer.observe ~cutoff:view_model_cutoff view_model_signal
            handle_view_model_update
        ]}

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

    val dispose : 'a t -> (unit, graph_error) Eta.Effect.t
    (** Dispose an observer lifecycle handle. Disposal is idempotent. Pending
        callbacks collected for the observer are skipped, and demand-owned
        timer cleanup is refreshed before the effect returns.

        Timer demand-cleanup graph failures such as [`Runtime_mismatch] are
        preserved in the typed error channel. The observer lifecycle state is
        still changed before timer cleanup runs. Disposal-hook defects remain
        Eta defects or finalizer diagnostics. *)
  end

  module Package : Package_graph with type 'a signal = 'a signal

  val const : 'a -> 'a signal
  (** Constant signal. A constant has no later candidate and therefore has no
      cutoff.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val map : ?cutoff:'b Cutoff.t -> ('a -> 'b) -> 'a signal -> 'b signal
  (** Map one dependency. Without [?cutoff], the derived-value cutoff is
      {!Cutoff.phys_equal}. Freshly allocated but structurally equal values are
      therefore treated as changes unless a structural cutoff is supplied.
      Pass [?cutoff] when [f] returns arrays, records, maps, lists, JSON-like
      trees, decoded rows, or other freshly rebuilt structural values. Prefer
      immutable/copy-on-write results; mutating a previously published result in
      place mutates the cached old value too.

      For derived view/state values, bias toward an explicit structural cutoff:

      {[
        let view_model =
          model_signal
          |> S.map ~cutoff:view_model_cutoff derive_view_model
      ]}

      The mapping function must be pure and total. Eta may evaluate pure graph
      closures during a stabilization that later rolls back because another
      node fails; side effects in mapping functions are therefore outside the
      signal contract.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val map2 :
    ?cutoff:'c Cutoff.t ->
    ('a -> 'b -> 'c) ->
    'a signal ->
    'b signal ->
    'c signal
  (** Map two dependencies. Without [?cutoff], the derived-value cutoff is
      {!Cutoff.phys_equal}. The same default applies to [map3] through [map9].
      Mapping functions must be pure and total; see {!map}.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val map3 :
    ?cutoff:'d Cutoff.t ->
    ('a -> 'b -> 'c -> 'd) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal

  val map4 :
    ?cutoff:'e Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal

  val map5 :
    ?cutoff:'f Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal

  val map6 :
    ?cutoff:'g Cutoff.t ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g) ->
    'a signal ->
    'b signal ->
    'c signal ->
    'd signal ->
    'e signal ->
    'f signal ->
    'g signal

  val map7 :
    ?cutoff:'h Cutoff.t ->
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
    ?cutoff:'i Cutoff.t ->
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
    ?cutoff:'j Cutoff.t ->
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

  val reduce_balanced :
    ?cutoff:'a Cutoff.t ->
    identity:'a ->
    combine:('a -> 'a -> 'a) ->
    'a signal array ->
    'a signal
  (** Reduce signals with a balanced tree. [combine] must be associative at the
      observation boundary, and [identity] must be its left and right identity.
      Construction copies the input array. Reduction preserves array order, and
      empty input publishes [identity]. Initial evaluation takes O(n)
      combination work; one changed child takes O(log(n + 1)) combination work.
      The final cutoff applies only to aggregate publication. Internal tree
      cells do not suppress candidates.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val all : ?cutoff:'a list Cutoff.t -> 'a signal list -> 'a list signal
  (** Collect a list of signals. Without [?cutoff], the list cutoff is
      {!Cutoff.phys_equal}. Pass
      [~cutoff:(Eta_signal.Cutoff.of_equal (List.equal element_equal))] when
      list contents define the logical value; otherwise each freshly allocated
      list is a change by identity.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val bind : ?cutoff:'b Cutoff.t -> 'a signal -> ('a -> 'b signal) -> 'b signal
  (** Dynamically select a signal from the current value of another signal.
      Nodes created by an inactive branch are invalidated when that branch is
      replaced; observing a captured inactive-branch node fails with
      [`Invalid_scope].

      The selector function must be pure and total. Eta may evaluate pure graph
      closures during a stabilization that later rolls back because another
      node fails; side effects in selectors are therefore outside the signal
      contract.

      Without [?cutoff], the selected output cutoff is {!Cutoff.phys_equal}.
      Pass [?cutoff] when selected branch outputs are structural values such as
      arrays, records, maps, lists, decoded rows, JSON-like trees, or freshly
      rebuilt immutable trees.

      Raises [Graph_error] on graph construction failures; see
      {!exception:Graph_error}. *)

  val stabilize : (unit, stabilize_error) Eta.Effect.t
  (** Run one explicit stabilization.

      Pure graph recomputation is transactional: graph failures before snapshot
      commit leave the previous stabilized snapshot in place and keep source
      updates retryable. Once a pure snapshot commits, observer current values
      and pending callback deliveries are published before timer lifecycle
      refresh, disposal cleanup, and observer callbacks run.

      Fails with [`Counter_overflow name] if an internal stabilization,
      generation, version, or timer token counter reaches [max_int]. These
      counters are monotonic and do not wrap. Overflow is treated as a graph
      failure before any partial snapshot is published.

      Failures after that commit point, including observer callback failures,
      timer start/stop lifecycle defects, disposal-hook failures, or
      interruption, do not roll back the committed snapshot. Undelivered
      observer callbacks keep the observer's delivery cursor pending. A later
      stabilization retries delivery against the latest stabilized value, so
      intermediate failed blips are coalesced: if the value has returned to the
      observer's last successfully delivered value, the pending delivery is
      acknowledged without running a callback. Disposal or dynamic-scope
      invalidation still skips pending callbacks. *)

  val stats : unit -> (stats, graph_error) Eta.Effect.t

  val to_dot : ?options:dot_options -> unit -> (string, 'err) Eta.Effect.t
  (** Return a read-only DOT dump. The default is necessary-only for compact
      demand debugging. Use [dot_scope = `All_valid] to include retained valid
      nodes that are not currently necessary, or [`All_including_invalid] to
      include invalid-node tombstones and invalid observer handles still
      retained for diagnostics. The metadata flags add observer, timer,
      dirty/queued, dependency/dependent edge counts, typed graph identity
      labels, and dynamic-scope state to the dump. If an invalid observer's
      signal tombstone has been evicted from the bounded diagnostic index, the
      observer label includes [missing_observed_signal_id] with the original
      signal id.

      The scope selection includes keyed owners and children. Keyed owner labels
      use [keyed_mapi]. State metadata includes the committed-child count and the
      requested scope. Invalid keyed tombstones stay bounded. The dump does not
      contain keys, data, child outputs, user closures, logs, journals, or action
      history. The read does not change graph behavior, identities, counters, or
      pending work. [smdiag-lb9n] [smdiag-1pr6] [smdiag-oqvr]
      [smdiag-3hlp] *)

  module Time : sig
    (** Time nodes are demand-owned source-updating effects. They never call
        {!stabilize}; observers see timer changes only after explicit
        stabilization.

        Signal time is measured by Eta's monotonic runtime clock, not by
        wall/civil time. Each stabilization samples that clock at most once for
        timer-source coalescing, when the first timer source is pulled; the
        same sample is shared by every timer source refreshed in that
        stabilization. Before stabilization observes time nodes, [now] and
        [deadline] nodes coalesce to that clock-derived value, and [interval]
        nodes advance the counter arithmetically to the final saturated value
        for the same sample.

        [step] and [step_replay] keep user code out of stabilization: [f]
        runs only in the demand-owned timer daemon. A stabilization that runs
        before the daemon resumes can therefore observe the last
        daemon-published step value while [interval] has already caught up for
        the same clock sample. *)

    type monotonic_time
    (** Runtime monotonic timestamp. Values are comparable only inside the Eta
        runtime clock that produced them; they are not wall/civil time. *)

    val to_ms : monotonic_time -> int
    (** Return the runtime-clock millisecond value for display, metrics, or
        persistence. Do not feed wall-clock integers back into signal timers;
        use {!add}, {!after}, or a timestamp read from {!now}. *)

    val add :
      monotonic_time ->
      Eta.Duration.t ->
      (monotonic_time, [> `Deadline_overflow | `Past_deadline ]) result
    (** [add timestamp duration] returns the monotonic timestamp [duration]
        after [timestamp]. It fails with [`Past_deadline] for non-positive
        durations and [`Deadline_overflow] when the sum cannot be represented. *)

    val now :
      every:Eta.Duration.t ->
      unit ->
      (monotonic_time signal, time_error) Eta.Effect.t
    (** Signal containing the runtime monotonic timestamp. The timer source
        updates the signal at [every] while the signal is necessary. It does
        not call {!stabilize}. Use {!to_ms} only when an integer representation
        is needed at the edge. *)

    val deadline :
      every:Eta.Duration.t ->
      monotonic_time ->
      (bool signal, time_error) Eta.Effect.t
    (** [deadline ~every timestamp] becomes [true] after the monotonic runtime
        clock reaches [timestamp]. [timestamp] must be in the future on that
        clock when the signal is created. It fails with [`Runtime_mismatch] if
        [timestamp] came from a different Eta runtime. Prefer {!after} for
        ordinary relative one-shot deadlines. *)

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
      (missed:int -> 'a -> 'a) ->
      ('a signal, time_error) Eta.Effect.t
    (** Step a value once per timer-daemon wake, passing the number of elapsed
        cadences as [missed].

        Clock-jump catch-up is bounded: a large clock jump runs [f] once with a
        large [missed] value instead of replaying [f] once per cadence.
        [missed] saturates at [max_int].
        Unlike [now], [deadline], and [interval], [step] does not run catch-up
        from stabilization; a
        stabilization that runs before the daemon resumes observes the last
        daemon-published step value.

        [f] runs in the demand-owned timer daemon, not during stabilization. If
        [f] raises, Eta reports the defect through daemon diagnostics with
        [eta_signal.time.step] context; it is not delivered as a [stabilize]
        failure. The failed daemon cleans up timer state so later demand can
        restart it. *)

    val step_replay :
      every:Eta.Duration.t ->
      initial:'a ->
      ('a -> 'a) ->
      ('a signal, time_error) Eta.Effect.t
    (** Step a value with a pure total function after each [every] interval
        while necessary.

        Clock-jump catch-up replays [f] once per awakened cadence after the
        timer daemon wakes. This is exact replay, not a coalescing policy, so a
        very large clock jump or long process suspension can perform
        correspondingly large cooperative catch-up work. Prefer {!step} for
        virtual-clock tests and production timers unless exact per-cadence
        replay is explicitly required.

        Like [step], [f] runs in the demand-owned timer daemon, not during
        stabilization. If [f] raises, Eta reports the defect through daemon
        diagnostics with [eta_signal.time.step_replay] context; it is not
        delivered as a [stabilize] failure. *)
  end

  module Stream : sig
    val observe :
      ?capacity:int ->
      ?on_drop:('a update -> unit) ->
      ?cutoff:'a Cutoff.t ->
      'a signal ->
      ('a observer * ('a update, graph_error) Eta_stream.Stream.t, stream_error)
      Eta.Effect.t
    (** [observe ?capacity signal] creates an observer and a stream of observer
        updates. [capacity] defaults to [1024] and bounds the bridge queue.
        Without [?cutoff], stream update emission uses {!Cutoff.phys_equal} as
        its observer cutoff. Pass [?cutoff] when stream consumers must receive
        updates only for structural value changes. This is especially important
        for streams of arrays, records, maps, lists, decoded rows, or JSON-like
        trees, where allocating a fresh but equal value would otherwise emit.
        For example:

        {[
          S.Stream.observe ~cutoff:view_model_cutoff view_model_signal
        ]}

        Publication from stabilization is nonblocking: when the bridge already
        has [capacity] buffered updates, the newest stream update is dropped
        and stabilization continues. A later delivered change may therefore
        report an [old_value] that was not itself delivered through the stream.
        Pass [?on_drop] to observe each dropped update; the hook runs
        synchronously during observer delivery and should be reserved for
        counters, metrics, or lightweight logging. If the hook raises, Eta logs
        [eta_signal.stream.on_drop_failure], still acknowledges the drop, and
        continues stabilization. The failed hook is not retried.

        Disposing the returned observer cleanly closes the stream queue.
        Buffered updates drain before the stream ends. Early stream consumers
        such as {!Eta_stream.Stream.take} do not dispose the observer; the
        returned observer remains the lifecycle handle. Graph operations on that
        observer remain restricted to the graph owner domain. The stream is
        backed by a cross-domain {!Eta.Queue.t} and may be consumed from another
        Eta runtime or domain. The queue does not copy update payloads; callers
        must ensure values are safe for cross-domain use.

        Fails with [`Invalid_capacity] when [capacity <= 0]. *)

    val with_observed :
      ?capacity:int ->
      ?on_drop:('a update -> unit) ->
      ?cutoff:'a Cutoff.t ->
      'a signal ->
      (('a update, graph_error) Eta_stream.Stream.t ->
      ('b, stream_error) Eta.Effect.t) ->
      ('b, stream_error) Eta.Effect.t
    (** [with_observed ?capacity signal f] creates a stream observer, runs [f]
        with the update stream, and disposes the observer when [f] exits on
        success, typed failure, defect, or cancellation.

        This is the safe default for bounded stream-consumer workflows because
        the observer is the graph-demand handle. When [f] stops early, returns
        a value, or fails, Eta still disposes the observer and closes the
        stream after buffered updates drain. Use {!observe} directly when the
        observer lifetime intentionally outlives the consumer effect, or when a
        wider workflow also needs non-stream Eta operations in the same error
        channel.

        Cleanup uses {!Observer.dispose}; disposal cleanup failures are
        reported through Eta's resource semantics. *)
  end
end

module Make_no_error () : module type of Make (No_observer_error) ()
(** [Make_no_error ()] is [Make (No_observer_error) ()]. Use it for pure signal
    graphs and observer callbacks that cannot fail with a typed application
    error. Use {!Make} when observer callbacks need their own typed failure
    channel. *)
