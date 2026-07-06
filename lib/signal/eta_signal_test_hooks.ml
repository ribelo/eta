module Effect = Eta.Effect

type hook =
  | After_observer_delivery_claim
  | After_observer_activation_before_return
  | After_graph_lane_acquired

type action = { run : 'err. unit -> (unit, 'err) Effect.t }

type t = {
  after_observer_delivery_claim : action ref;
  after_observer_activation_before_return : action ref;
  after_graph_lane_acquired : action ref;
  timer_runtime_mismatch_hook : (unit -> unit) ref;
}

let noop = { run = (fun () -> Effect.unit) }

let create () =
  {
    after_observer_delivery_claim = ref noop;
    after_observer_activation_before_return = ref noop;
    after_graph_lane_acquired = ref noop;
    timer_runtime_mismatch_hook = ref (fun () -> ());
  }

let slot state = function
  | After_observer_delivery_claim -> state.after_observer_delivery_claim
  | After_observer_activation_before_return ->
      state.after_observer_activation_before_return
  | After_graph_lane_acquired -> state.after_graph_lane_acquired

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
    ];
  state.timer_runtime_mismatch_hook := (fun () -> ())

let run state hook =
  let slot = slot state hook in
  (!slot).run ()

let set_timer_runtime_mismatch_hook state hook =
  state.timer_runtime_mismatch_hook := hook

let run_timer_runtime_mismatch_hook state =
  !(state.timer_runtime_mismatch_hook) ()
