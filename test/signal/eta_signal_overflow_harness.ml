module Impl = Eta_signal_overflow_impl

module type Observer_error = Impl.Observer_error

module Make (Observer_error : Observer_error) () = struct
  module S = Impl.Make (Observer_error) ()

  type observer_error = S.observer_error

  type graph_error = S.graph_error

  exception Graph_error = S.Graph_error

  type observer_read_error = S.observer_read_error

  type stabilize_error = S.stabilize_error

  type time_error = S.time_error

  type 'a var = 'a S.var
  type 'a signal = 'a S.signal
  type 'a observer = 'a S.observer
  type stats = S.stats

  type 'a update = 'a S.update =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  module Var = struct
    type 'a t = 'a var

    let create = S.Var.create
    let watch = S.Var.watch
    let set = S.Var.set
  end

  module Observer = struct
    type 'a t = 'a observer

    let observe = S.Observer.observe
    let read = S.Observer.read
    let dispose = S.Observer.dispose
  end

  let const = S.const
  let bind = S.bind
  let stabilize = S.stabilize
  let stats = S.stats

  module Time = struct
    let interval = S.Time.interval
  end

  module Overflow = struct
    type stats_counter_target =
      | Pure_snapshot_commit_count
      | Callback_delivery_count
      | Recompute_count
      | Dynamic_scope_invalidations
      | Nodes_became_necessary
      | Nodes_became_unnecessary
      | Stream_bridge_drop_count

    let lane_depth_local : int Eta.Runtime_contract.local =
      Eta.Runtime_contract.create_local ()

    let with_lane f =
      Impl.Graph.with_lane_access S.graph
        ~leaf_name:"eta_signal_overflow_harness.graph_lane"
        ~depth_local:lane_depth_local
        ~hooks:
          (Impl.Graph.lane_hooks ~note_waiter_enqueued:ignore
             ~note_waiter_compaction:ignore)
        ~after_acquired:(fun () -> Eta.Effect.unit)
        f

    let stats_counter = Impl.Debug.stats_counter

    let set_signal_version (signal : _ S.signal) value =
      let snapshot = Impl.Transaction.current signal.S.snapshot in
      S.publish_initial_current signal.S.snapshot
        (Impl.Signal_snapshot.with_version snapshot value)

    let set_timer_generation (signal : int S.signal) generation =
      match signal.S.timer with
      | None -> invalid_arg "expected timer signal"
      | Some timer ->
          let snapshot_cell = Impl.Timer.snapshot_cell timer in
          let snapshot = Impl.Transaction.current snapshot_cell in
          S.publish_timer_current snapshot_cell
            (Impl.Timer_policy.snapshot_with_generation snapshot generation)

    let set_next_node_id value =
      with_lane (fun lane -> Impl.Graph.set_next_node_id S.graph lane value)

    let set_generation value =
      with_lane (fun lane -> Impl.Graph.set_generation S.graph lane value)

    let set_next_timer_refresh_token value =
      with_lane (fun lane ->
          Impl.Graph.set_next_timer_refresh_token S.graph lane value)

    let set_stats_counter target value =
      with_lane (fun lane ->
          match target with
          | Pure_snapshot_commit_count ->
              Impl.Graph.set_pure_snapshot_commit_count S.graph lane value
          | Callback_delivery_count ->
              Impl.Graph.set_counter S.graph lane
                Impl.Graph.Callback_delivery_count value
          | Recompute_count ->
              Impl.Graph.set_counter S.graph lane Impl.Graph.Recompute_count
                value
          | Dynamic_scope_invalidations ->
              Impl.Graph.set_counter S.graph lane
                Impl.Graph.Dynamic_scope_invalidations value
          | Nodes_became_necessary ->
              Impl.Graph.set_counter S.graph lane
                Impl.Graph.Nodes_became_necessary value
          | Nodes_became_unnecessary ->
              Impl.Graph.set_counter S.graph lane
                Impl.Graph.Nodes_became_unnecessary value
          | Stream_bridge_drop_count ->
              Impl.Graph.set_stream_bridge_metrics S.graph lane
                (Impl.Stream_bridge.create_metrics ~drop_count:value ()))
  end
end
