type 'start demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : (unit -> unit) list;
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

let apply_stop_plan ~set_current_state timer plan =
  set_current_state timer plan.Eta_signal_timer_policy.stop_state;
  plan.Eta_signal_timer_policy.stop_cancel_hooks

let mark_unneeded ~advance_generation ~cancel_running ~current_state
    ~set_current_state timer =
  match
    Eta_signal_timer_policy.stop ~advance_generation ~cancel_running
      (current_state timer)
  with
  | None -> []
  | Some plan -> apply_stop_plan ~set_current_state timer plan

let rollback_unclaimed_start ~advance_generation ~current_state
    ~set_current_state timer =
  if Eta_signal_timer_policy.state_starting (current_state timer) then
    mark_unneeded ~advance_generation ~cancel_running:true ~current_state
      ~set_current_state timer
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
        apply_stop_plan ~set_current_state:port.demand_set_current_state;
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
