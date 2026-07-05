type 'start demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : (unit -> unit) list;
}

type 'operation node = {
  timer_snapshot :
    Eta_signal_timer_policy.snapshot Eta_signal_transaction.staged;
  mutable timer_staged_refresh_token : int;
  timer_runtime_contract : Eta.Runtime_contract.t;
  timer_refresh_when_inactive : bool;
  timer_refresh_operation : 'operation option;
  timer_start : 'err. 'operation node -> (unit, 'err) Eta.Effect.t;
}

type 'operation start = {
  run : 'err. 'operation node -> (unit, 'err) Eta.Effect.t;
}

let create_node ~runtime_contract ~refresh_when_inactive
    ~refresh_operation ~start =
  {
    timer_snapshot =
      Eta_signal_transaction.create_staged
        Eta_signal_timer_policy.initial_snapshot;
    timer_staged_refresh_token = -1;
    timer_runtime_contract = runtime_contract;
    timer_refresh_when_inactive = refresh_when_inactive;
    timer_refresh_operation = refresh_operation;
    timer_start = start.run;
  }

let snapshot_cell timer = timer.timer_snapshot
let staged_refresh_token timer = timer.timer_staged_refresh_token

let set_staged_refresh_token timer token =
  timer.timer_staged_refresh_token <- token

let runtime_contract timer = timer.timer_runtime_contract
let refresh_when_inactive timer = timer.timer_refresh_when_inactive
let refresh_operation timer = timer.timer_refresh_operation
let start_effect timer = timer.timer_start timer

type ('timer, 'effect) start_attempt = {
  attempt_timer : 'timer;
  attempt_effect : 'effect;
}

type 'timer state_port = {
  state_effective : 'timer -> Eta_signal_timer_policy.state;
  state_current : 'timer -> Eta_signal_timer_policy.state;
  state_set_current : 'timer -> Eta_signal_timer_policy.state -> unit;
}

type daemon_state_access = {
  daemon_with_state :
    'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

type 'timer daemon_update = {
  daemon_update :
    'error.
    'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
}

type daemon_hooks = {
  daemon_after_due_read_before_commit :
    'error. unit -> (unit, 'error) Eta.Effect.t;
  daemon_after_update_constructed_before_run :
    'error. unit -> (unit, 'error) Eta.Effect.t;
}

type ('id, 'necessary, 'runtime, 'timer, 'effect, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_effective_state : 'timer -> Eta_signal_timer_policy.state;
  demand_current_state : 'timer -> Eta_signal_timer_policy.state;
  demand_set_current_state : 'timer -> Eta_signal_timer_policy.state -> unit;
  demand_start_effect : 'timer -> 'effect;
}

type ('capability, 'error) demand_effect_access = {
  demand_with_access :
    'a.
    ('capability -> ('a, 'error) result) ->
    ('a, 'error) Eta.Effect.t;
}

type ('capability, 'start, 'error) demand_effect_port = {
  demand_acquire :
    Eta.Runtime_contract.t ->
    'capability ->
    ('start demand_effects, 'error) result;
  demand_rollback_unclaimed :
    'capability -> 'start list -> ((unit -> unit) list, 'error) result;
  demand_run_cancel_hooks :
    (unit -> unit) list -> (unit, 'error) Eta.Effect.t;
  demand_run_start_attempts :
    'start list -> (unit, 'error) Eta.Effect.t;
}

let start_attempt ~timer ~effect =
  { attempt_timer = timer; attempt_effect = effect }

let start_attempt_effect attempt =
  attempt.attempt_effect

let start_attempt_effects attempts =
  List.map start_attempt_effect attempts

let apply_start_plan ~set_current_state ~start_effect timer plan =
  set_current_state timer plan.Eta_signal_timer_policy.start_state;
  start_attempt ~timer ~effect:(start_effect timer)

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

let rollback_unclaimed_start_attempts ~advance_generation port attempts =
  List.concat_map
    (fun attempt ->
      rollback_unclaimed_start ~advance_generation port attempt.attempt_timer)
    attempts

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
          ~start_effect:port.demand_start_effect;
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

let refresh_demand_effect access port =
  Eta_signal_timer_adapter.refresh_demand
    {
      Eta_signal_timer_adapter.with_access =
        (fun f -> access.demand_with_access f);
    }
    {
      Eta_signal_timer_adapter.acquire_demand =
        (fun runtime_contract capability ->
          match port.demand_acquire runtime_contract capability with
          | Error _ as error -> error
          | Ok effects ->
              Ok
                ( effects.demand_start_attempts,
                  effects.demand_cancel_hooks ));
      rollback_unclaimed_starts = port.demand_rollback_unclaimed;
      run_cancel_hooks = port.demand_run_cancel_hooks;
      run_start_attempts = port.demand_run_start_attempts;
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

let daemon_exit = function
  | Eta.Exit.Ok _ -> Eta_signal_timer_policy.Daemon_ok
  | Eta.Exit.Error _ -> Eta_signal_timer_policy.Daemon_error

let start_daemon ~advance_generation access port timer update hooks
    ~generation ~interval_ms ~update_on_start ~catch_up_policy =
  let with_state f = access.daemon_with_state f in
  let cleanup_after_exit ~generation exit =
    with_state (fun () ->
        cleanup_after_exit ~advance_generation port timer ~generation
          (daemon_exit exit))
  in
  let cleanup_failed_start ~generation exit =
    with_state (fun () ->
        cleanup_failed_start ~advance_generation port timer ~generation
          (daemon_exit exit))
  in
  let after_update_state ~generation =
    with_state (fun () -> after_update_state port timer ~generation)
  in
  let loop_callbacks =
    {
      Eta_signal_timer_adapter.read_next_due =
        (fun ~generation ~fallback ->
          with_state (fun () ->
              read_next_due port timer ~generation ~fallback));
      advance_next_due =
        (fun ~generation ~expected ~next_due_ms ->
          with_state (fun () ->
              advance_next_due port timer ~generation ~expected
                ~next_due_ms));
      after_update_state;
      finish_saturated =
        (fun ~generation ->
          with_state (fun () ->
              finish_saturated ~advance_generation port timer ~generation));
      construct_update =
        (fun ~generation ~missed ->
          update.daemon_update timer ~generation ~missed);
      after_due_read_before_commit =
        hooks.daemon_after_due_read_before_commit;
      after_update_constructed_before_run =
        hooks.daemon_after_update_constructed_before_run;
    }
  in
  let start_callbacks =
    {
      Eta_signal_timer_adapter.begin_start =
        (fun ~generation ->
          with_state (fun () -> begin_start port timer ~generation));
      set_next_due =
        (fun ~generation ~next_due_ms ->
          with_state (fun () ->
              set_next_due port timer ~generation ~next_due_ms));
      after_start_update = after_update_state;
      construct_start_update =
        (fun ~generation ~missed ->
          update.daemon_update timer ~generation ~missed);
      install_cancel =
        (fun ~generation ~cancel ->
          with_state (fun () ->
              install_cancel port timer ~generation ~cancel));
      cleanup_after_exit;
      cleanup_failed_start;
    }
  in
  Eta_signal_timer_adapter.start start_callbacks loop_callbacks ~generation
    ~interval_ms ~update_on_start ~catch_up_policy

let create_daemon_node ~runtime_contract ~refresh_when_inactive
    ~refresh_operation ~advance_generation access port update hooks
    ~interval_ms ~update_on_start ~catch_up_policy =
  create_node ~runtime_contract ~refresh_when_inactive ~refresh_operation
    ~start:
      {
        run =
          (fun timer ->
            let generation =
              Eta_signal_timer_policy.state_generation
                (port.state_current timer)
            in
            start_daemon ~advance_generation access port timer update hooks
              ~generation ~interval_ms ~update_on_start ~catch_up_policy);
      }
