type 'start demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : (unit -> unit) list;
}

let demand_effects ~start_attempts ~cancel_hooks =
  {
    demand_start_attempts = start_attempts;
    demand_cancel_hooks = cancel_hooks;
  }

let demand_effects_plan effects ~plan =
  plan ~start_attempts:effects.demand_start_attempts
    ~cancel_hooks:effects.demand_cancel_hooks

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

let start (type operation)
    ~(run : 'err. operation node -> (unit, 'err) Eta.Effect.t) =
  { run }

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

let can_refresh_on_demand ~token ~current_snapshot ~effective_state timer =
  Eta_signal_timer_policy.can_refresh_on_demand
    ~refresh_operation:(Option.is_some timer.timer_refresh_operation)
    ~current_token:
      (Eta_signal_timer_policy.snapshot_on_demand_refresh_token
         current_snapshot)
    ~staged_token:timer.timer_staged_refresh_token ~token
    ~refresh_when_inactive:timer.timer_refresh_when_inactive
    ~active:(Eta_signal_timer_policy.state_active effective_state)
    ~finished:(Eta_signal_timer_policy.state_finished effective_state)

type ('timer, 'effect) start_attempt = {
  attempt_timer : 'timer;
  attempt_effect : 'effect;
}

type 'timer state_port = {
  state_effective : 'timer -> Eta_signal_timer_policy.state;
  state_current : 'timer -> Eta_signal_timer_policy.state;
  state_set_current : 'timer -> Eta_signal_timer_policy.state -> unit;
}

let state_port ~effective ~current ~set_current =
  {
    state_effective = effective;
    state_current = current;
    state_set_current = set_current;
  }

type daemon_state_access = {
  daemon_with_state :
    'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

let daemon_state_access
    ~(with_state :
       'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t) =
  { daemon_with_state = with_state }

type 'timer daemon_update = {
  daemon_update :
    'error.
    'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
}

let daemon_update (type timer)
    ~(update :
       'error.
       timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t)
    =
  { daemon_update = update }

type daemon_hooks = {
  daemon_after_due_read_before_commit :
    'error. unit -> (unit, 'error) Eta.Effect.t;
  daemon_after_update_constructed_before_run :
    'error. unit -> (unit, 'error) Eta.Effect.t;
}

let daemon_hooks
    ~(after_due_read_before_commit :
       'error. unit -> (unit, 'error) Eta.Effect.t)
    ~(after_update_constructed_before_run :
       'error. unit -> (unit, 'error) Eta.Effect.t) =
  {
    daemon_after_due_read_before_commit = after_due_read_before_commit;
    daemon_after_update_constructed_before_run =
      after_update_constructed_before_run;
  }

type 'timer daemon_context = {
  daemon_advance_generation : int -> int;
  daemon_state_access : daemon_state_access;
  daemon_state : 'timer state_port;
  daemon_update : 'timer daemon_update;
  daemon_hooks : daemon_hooks;
}

let daemon_context ~advance_generation ~state_access ~state ~update ~hooks =
  {
    daemon_advance_generation = advance_generation;
    daemon_state_access = state_access;
    daemon_state = state;
    daemon_update = update;
    daemon_hooks = hooks;
  }

type ('id, 'necessary, 'runtime, 'timer, 'effect, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_state : 'timer state_port;
  demand_start_effect : 'timer -> 'effect;
}

let demand_port ~collect_necessary ~collect_timers ~is_necessary
    ~validate_runtime ~state ~start_effect =
  {
    demand_collect_necessary = collect_necessary;
    demand_collect_timers = collect_timers;
    demand_is_necessary = is_necessary;
    demand_validate_runtime = validate_runtime;
    demand_state = state;
    demand_start_effect = start_effect;
  }

type ('id, 'necessary, 'operation, 'runtime, 'error) node_demand_plan = {
  node_demand_necessary : 'necessary;
  node_demand_timers : ('id * 'operation node) list;
  node_demand_is_necessary : 'necessary -> 'id -> bool;
  node_demand_validate_runtime :
    'runtime -> 'operation node -> (unit, 'error) result;
  node_demand_state : 'operation node state_port;
}

let node_demand_plan ~necessary ~timers ~is_necessary ~validate_runtime
    ~state =
  {
    node_demand_necessary = necessary;
    node_demand_timers = timers;
    node_demand_is_necessary = is_necessary;
    node_demand_validate_runtime = validate_runtime;
    node_demand_state = state;
  }

type ('capability, 'error) demand_effect_access = {
  demand_with_access :
    'a.
    ('capability -> ('a, 'error) result) ->
    ('a, 'error) Eta.Effect.t;
}

let demand_effect_access (type capability error)
    ~(with_access :
       'a.
       (capability -> ('a, error) result) -> ('a, error) Eta.Effect.t) =
  { demand_with_access = with_access }

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

let demand_effect_port ~acquire ~rollback_unclaimed ~run_cancel_hooks
    ~run_start_attempts =
  {
    demand_acquire = acquire;
    demand_rollback_unclaimed = rollback_unclaimed;
    demand_run_cancel_hooks = run_cancel_hooks;
    demand_run_start_attempts = run_start_attempts;
  }

type ('capability, 'id, 'necessary, 'operation, 'error)
     node_demand_effect_port = {
  node_demand_effect_plan :
    Eta.Runtime_contract.t ->
    'capability ->
    ( 'id,
      'necessary,
      'operation,
      Eta.Runtime_contract.t,
      'error )
    node_demand_plan;
}

let node_demand_effect_port ~plan =
  { node_demand_effect_plan = plan }

let start_attempt ~timer ~effect =
  { attempt_timer = timer; attempt_effect = effect }

let start_attempt_effect attempt =
  attempt.attempt_effect

let start_attempt_effects attempts =
  List.map start_attempt_effect attempts

let apply_start_plan ~set_current_state ~start_effect timer plan =
  Eta_signal_timer_policy.start_plan_result plan
    ~plan:(fun ~state ~generation:_ ->
      set_current_state timer state;
      start_attempt ~timer ~effect:(start_effect timer))

let apply_stop_plan port timer plan =
  Eta_signal_timer_policy.stop_plan_result plan
    ~plan:(fun ~state ~cancel_hooks ->
      port.state_set_current timer state;
      cancel_hooks)

let mark_unneeded ~advance_generation ~cancel_running port timer =
  match
    Eta_signal_timer_policy.stop ~advance_generation ~cancel_running
      (port.state_current timer)
  with
  | None -> []
  | Some plan -> apply_stop_plan port timer plan

let mark_node_unneeded = mark_unneeded

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
    Eta_signal_timer_policy.demand_context
      ~necessary:(port.demand_is_necessary necessary)
      ~validate:(port.demand_validate_runtime runtime)
      ~effective_state:port.demand_state.state_effective
      ~current_state:port.demand_state.state_current
      ~start:
        (apply_start_plan
           ~set_current_state:port.demand_state.state_set_current
           ~start_effect:port.demand_start_effect)
      ~stop:(apply_stop_plan port.demand_state)
  in
  match
    Eta_signal_timer_policy.demand_effects ~advance_generation ~cancel_running
      context resources
  with
  | Error _ as error -> error
  | Ok effects ->
      Eta_signal_timer_policy.demand_effects_result effects
        ~plan:(fun ~start_attempts ~cancel_hooks ->
          Ok (demand_effects ~start_attempts ~cancel_hooks))

let refresh_node_demand_plan ~advance_generation ~cancel_running plan runtime =
  refresh_demand ~advance_generation ~cancel_running
    (demand_port
       ~collect_necessary:(fun () -> plan.node_demand_necessary)
       ~collect_timers:(fun () -> plan.node_demand_timers)
       ~is_necessary:plan.node_demand_is_necessary
       ~validate_runtime:plan.node_demand_validate_runtime
       ~state:plan.node_demand_state ~start_effect)
    runtime

let refresh_demand_effect access port =
  Eta_signal_timer_adapter.refresh_demand
    (Eta_signal_timer_adapter.access ~with_access:(fun f ->
         access.demand_with_access f))
    (Eta_signal_timer_adapter.demand_callbacks
       ~acquire_demand:(fun runtime_contract capability ->
         match port.demand_acquire runtime_contract capability with
         | Error _ as error -> error
         | Ok effects ->
             demand_effects_plan effects ~plan:(fun ~start_attempts
                 ~cancel_hooks -> Ok (start_attempts, cancel_hooks)))
       ~rollback_unclaimed_starts:port.demand_rollback_unclaimed
       ~run_cancel_hooks:port.demand_run_cancel_hooks
       ~run_start_attempts:port.demand_run_start_attempts)

let refresh_node_demand_effect ~advance_generation access port =
  let active_plan = ref None in
  refresh_demand_effect access
    (demand_effect_port
       ~acquire:(fun runtime capability ->
          let plan = port.node_demand_effect_plan runtime capability in
          active_plan := Some plan;
          refresh_node_demand_plan ~advance_generation
            ~cancel_running:true plan runtime)
       ~rollback_unclaimed:(fun _capability attempts ->
          match !active_plan with
          | None -> Ok []
          | Some plan ->
              active_plan := None;
              Ok
                (rollback_unclaimed_start_attempts ~advance_generation
                   plan.node_demand_state attempts))
       ~run_cancel_hooks:(fun hooks ->
         Eta_signal_cleanup.run_hooks hooks |> Eta.Effect.uninterruptible)
       ~run_start_attempts:(fun attempts ->
         Eta.Effect.concat (start_attempt_effects attempts)))

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

let start_daemon context timer ~generation ~interval_ms ~update_on_start
    ~catch_up_policy =
  let advance_generation = context.daemon_advance_generation in
  let port = context.daemon_state in
  let update = context.daemon_update in
  let hooks = context.daemon_hooks in
  let with_state f = context.daemon_state_access.daemon_with_state f in
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
    Eta_signal_timer_adapter.callbacks
      ~read_next_due:(fun ~generation ~fallback ->
        with_state (fun () ->
            read_next_due port timer ~generation ~fallback))
      ~advance_next_due:(fun ~generation ~expected ~next_due_ms ->
        with_state (fun () ->
            advance_next_due port timer ~generation ~expected ~next_due_ms))
      ~after_update_state
      ~finish_saturated:(fun ~generation ->
        with_state (fun () ->
            finish_saturated ~advance_generation port timer ~generation))
      ~construct_update:(fun ~generation ~missed ->
        update.daemon_update timer ~generation ~missed)
      ~after_due_read_before_commit:hooks.daemon_after_due_read_before_commit
      ~after_update_constructed_before_run:
        hooks.daemon_after_update_constructed_before_run
  in
  let start_callbacks =
    Eta_signal_timer_adapter.start_callbacks
      ~begin_start:(fun ~generation ->
        with_state (fun () -> begin_start port timer ~generation))
      ~set_next_due:(fun ~generation ~next_due_ms ->
        with_state (fun () ->
            set_next_due port timer ~generation ~next_due_ms))
      ~after_start_update:after_update_state
      ~construct_start_update:(fun ~generation ~missed ->
        update.daemon_update timer ~generation ~missed)
      ~install_cancel:(fun ~generation ~cancel ->
        with_state (fun () ->
            install_cancel port timer ~generation ~cancel))
      ~cleanup_after_exit ~cleanup_failed_start
  in
  Eta_signal_timer_adapter.start start_callbacks loop_callbacks ~generation
    ~interval_ms ~update_on_start ~catch_up_policy

let create_daemon_node ~runtime_contract ~refresh_when_inactive
    ~refresh_operation context ~interval_ms ~update_on_start
    ~catch_up_policy =
  create_node ~runtime_contract ~refresh_when_inactive ~refresh_operation
    ~start:
      (start ~run:(fun timer ->
           let generation =
             Eta_signal_timer_policy.state_generation
               (context.daemon_state.state_current timer)
           in
           start_daemon context timer ~generation ~interval_ms
             ~update_on_start ~catch_up_policy))
