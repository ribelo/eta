type ('start, 'hook) demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : 'hook list;
}

type ('id, 'necessary, 'runtime, 'timer, 'start, 'hook, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_plan_start : 'timer -> Eta_signal_timer_policy.start_plan -> 'start;
  demand_plan_stop :
    'timer -> Eta_signal_timer_policy.stop_plan -> 'hook list;
}

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
      demand_plan_start = port.demand_plan_start;
      demand_plan_stop = port.demand_plan_stop;
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
