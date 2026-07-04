type 'start demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : (unit -> unit) list;
}

type 'timer state_port = {
  state_effective : 'timer -> Eta_signal_timer_policy.state;
  state_current : 'timer -> Eta_signal_timer_policy.state;
  state_set_current : 'timer -> Eta_signal_timer_policy.state -> unit;
}

type ('id, 'necessary, 'runtime, 'timer, 'start, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_set_current_state : 'timer -> Eta_signal_timer_policy.state -> unit;
  demand_start_attempt : 'timer -> 'start;
}

let apply_start_plan ~set_current_state ~start_attempt timer plan =
  set_current_state timer plan.Eta_signal_timer_policy.start_state;
  start_attempt timer

let apply_stop_plan port timer plan =
  port.state_set_current timer plan.Eta_signal_timer_policy.stop_state;
  plan.Eta_signal_timer_policy.stop_cancel_hooks

let mark_unneeded ~advance_generation ~cancel_running port timer =
  match
    Eta_signal_timer_policy.stop ~advance_generation ~cancel_running
      (port.state_current timer)
  with
  | None -> []
  | Some plan -> apply_stop_plan port timer plan

let rollback_unclaimed_start ~advance_generation port timer =
  if Eta_signal_timer_policy.state_starting (port.state_current timer) then
    mark_unneeded ~advance_generation ~cancel_running:true port timer
  else []

let refresh_demand ~advance_generation ~cancel_running port runtime =
  let necessary = port.demand_collect_necessary () in
  let resources =
    port.demand_collect_timers ()
    |> List.map (fun (id, timer) ->
           Eta_signal_timer_policy.demand_resource ~id timer)
  in
  let context =
    {
      Eta_signal_timer_policy.demand_resource_necessary =
        port.demand_is_necessary necessary;
      demand_resource_validate = port.demand_validate_runtime runtime;
      demand_resource_effective_state = port.demand_effective_state;
      demand_resource_current_state = port.demand_current_state;
      demand_plan_start =
        apply_start_plan ~set_current_state:port.demand_set_current_state
          ~start_attempt:port.demand_start_attempt;
      demand_plan_stop =
        apply_stop_plan
          {
            state_effective = port.demand_effective_state;
            state_current = port.demand_current_state;
            state_set_current = port.demand_set_current_state;
          };
    }
  in
  match
    Eta_signal_timer_policy.demand_effects ~advance_generation ~cancel_running
      context resources
  with
  | Error _ as error -> error
  | Ok effects ->
      Ok
        {
          demand_start_attempts =
            effects.Eta_signal_timer_policy.demand_start_attempts;
          demand_cancel_hooks =
            effects.Eta_signal_timer_policy.demand_cancel_hooks;
        }

let begin_start port timer ~generation =
  match
    Eta_signal_timer_policy.begin_start (port.state_current timer)
      ~generation
  with
  | Some state ->
      port.state_set_current timer state;
      `Continue
  | None -> `Stop

let install_cancel port timer ~generation ~cancel =
  match
    Eta_signal_timer_policy.install_cancel (port.state_current timer)
      ~generation ~cancel
  with
  | Some state ->
      port.state_set_current timer state;
      `Continue
  | None -> `Stop

let apply_cleanup ~advance_generation port timer ~generation cleanup exit =
  Option.iter
    (port.state_set_current timer)
    (cleanup ~advance_generation
       ~effective_state:(port.state_effective timer)
       ~current_state:(port.state_current timer) ~generation exit)

let cleanup_after_exit ~advance_generation port timer ~generation exit =
  apply_cleanup ~advance_generation port timer ~generation
    Eta_signal_timer_policy.cleanup_after_exit exit

let cleanup_failed_start ~advance_generation port timer ~generation exit =
  apply_cleanup ~advance_generation port timer ~generation
    Eta_signal_timer_policy.cleanup_failed_start exit

let after_update_state port timer ~generation =
  match
    Eta_signal_timer_policy.daemon_status
      (port.state_effective timer) ~generation
  with
  | Eta_signal_timer_policy.Daemon_continue -> `Continue
  | Eta_signal_timer_policy.Daemon_stop -> `Stop

let publish_if_running port timer ~generation ~publish =
  match after_update_state port timer ~generation with
  | `Continue ->
      publish ();
      `Updated
  | `Stop -> `Stopped

let read_next_due port timer ~generation ~fallback =
  Eta_signal_timer_policy.read_next_due (port.state_effective timer)
    ~generation ~fallback

let set_next_due port timer ~generation ~next_due_ms =
  match
    Eta_signal_timer_policy.set_next_due
      ~effective_state:(port.state_effective timer)
      ~current_state:(port.state_current timer)
      ~generation ~next_due_ms
  with
  | Some state ->
      port.state_set_current timer state;
      `Continue
  | None -> `Stop

let advance_next_due port timer ~generation ~expected ~next_due_ms =
  match
    Eta_signal_timer_policy.advance_next_due
      ~effective_state:(port.state_effective timer)
      ~current_state:(port.state_current timer)
      ~generation ~expected ~next_due_ms
  with
  | Eta_signal_timer_policy.Advance_next_due_update state ->
      port.state_set_current timer state;
      `Advanced
  | Eta_signal_timer_policy.Advance_next_due_stale -> `Stale
  | Eta_signal_timer_policy.Advance_next_due_stop -> `Stop

let finish_saturated ~advance_generation port timer ~generation =
  Option.iter
    (port.state_set_current timer)
    (Eta_signal_timer_policy.finish_current_daemon
       ~advance_generation
       ~effective_state:(port.state_effective timer)
       ~current_state:(port.state_current timer) ~generation)
