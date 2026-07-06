module Effect = Eta.Effect

type hook =
  | After_observer_delivery_claim
  | After_observer_activation_before_return
  | After_graph_lane_acquired
  | After_stream_try_send_before_ack
  | After_stream_drop_before_ack
  | After_timer_due_read_before_commit
  | After_timer_update_constructed_before_run

type stats_count =
  | Stats_total_node_count
  | Stats_necessary_node_count
  | Stats_dead_node_count
  | Stats_lane_cancelled_waiter_count

type action = { run : 'err. unit -> (unit, 'err) Effect.t }

type t = {
  after_observer_delivery_claim : action ref;
  after_observer_activation_before_return : action ref;
  after_graph_lane_acquired : action ref;
  after_stream_try_send_before_ack : action ref;
  after_stream_drop_before_ack : action ref;
  after_timer_due_read_before_commit : action ref;
  after_timer_update_constructed_before_run : action ref;
  total_node_count_override : int option ref;
  necessary_node_count_override : int option ref;
  dead_node_count_override : int option ref;
  lane_cancelled_waiter_count_override : int option ref;
  timer_runtime_mismatch_hook : (unit -> unit) ref;
}

let noop = { run = (fun () -> Effect.unit) }

let create () =
  {
    after_observer_delivery_claim = ref noop;
    after_observer_activation_before_return = ref noop;
    after_graph_lane_acquired = ref noop;
    after_stream_try_send_before_ack = ref noop;
    after_stream_drop_before_ack = ref noop;
    after_timer_due_read_before_commit = ref noop;
    after_timer_update_constructed_before_run = ref noop;
    total_node_count_override = ref None;
    necessary_node_count_override = ref None;
    dead_node_count_override = ref None;
    lane_cancelled_waiter_count_override = ref None;
    timer_runtime_mismatch_hook = ref (fun () -> ());
  }

let slot state = function
  | After_observer_delivery_claim -> state.after_observer_delivery_claim
  | After_observer_activation_before_return ->
      state.after_observer_activation_before_return
  | After_graph_lane_acquired -> state.after_graph_lane_acquired
  | After_stream_try_send_before_ack -> state.after_stream_try_send_before_ack
  | After_stream_drop_before_ack -> state.after_stream_drop_before_ack
  | After_timer_due_read_before_commit ->
      state.after_timer_due_read_before_commit
  | After_timer_update_constructed_before_run ->
      state.after_timer_update_constructed_before_run

let stats_count_slot state = function
  | Stats_total_node_count -> state.total_node_count_override
  | Stats_necessary_node_count -> state.necessary_node_count_override
  | Stats_dead_node_count -> state.dead_node_count_override
  | Stats_lane_cancelled_waiter_count ->
      state.lane_cancelled_waiter_count_override

let with_hook state hook action f =
  let slot = slot state hook in
  let previous = !slot in
  slot := action;
  Fun.protect ~finally:(fun () -> slot := previous) f

let clear state =
  List.iter
    (fun hook ->
      let slot = slot state hook in
      slot := noop)
    [
      After_observer_delivery_claim;
      After_observer_activation_before_return;
      After_graph_lane_acquired;
      After_stream_try_send_before_ack;
      After_stream_drop_before_ack;
      After_timer_due_read_before_commit;
      After_timer_update_constructed_before_run;
    ];
  state.total_node_count_override := None;
  state.necessary_node_count_override := None;
  state.dead_node_count_override := None;
  state.lane_cancelled_waiter_count_override := None;
  state.timer_runtime_mismatch_hook := (fun () -> ())

let run state hook =
  let slot = slot state hook in
  (!slot).run ()

let set_stats_count_override state count value =
  stats_count_slot state count := value

let stats_count_override state count = !(stats_count_slot state count)

let set_timer_runtime_mismatch_hook state hook =
  state.timer_runtime_mismatch_hook := hook

let run_timer_runtime_mismatch_hook state =
  !(state.timer_runtime_mismatch_hook) ()
