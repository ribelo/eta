module Adapter = struct
  open Eta

  module Timer_policy = Eta_signal_timer_policy

  exception Timer_cancelled

  type continue =
    [ `Continue
    | `Stop
    ]

  type advance =
    [ `Advanced
    | `Stale
    | `Stop
    ]

  type ('capability, 'error) access = {
    with_access :
      'a. ('capability -> ('a, 'error) result) -> ('a, 'error) Effect.t;
  }

  type ('capability, 'error) access_runner = {
    run_access :
      'a. ('capability -> ('a, 'error) result) -> ('a, 'error) Eta.Effect.t;
  }

  let access ~(with_access : ('capability, 'error) access_runner) =
    { with_access = with_access.run_access }

  type 'error loop_due_plan = {
    read_next_due :
      generation:int -> fallback:int -> (int option, 'error) Effect.t;
    advance_next_due :
      generation:int ->
      expected:int ->
      next_due_ms:int ->
      (advance, 'error) Effect.t;
    after_due_read_before_commit : unit -> (unit, 'error) Effect.t;
  }

  let loop_due_plan ~read_next_due ~advance_next_due
      ~after_due_read_before_commit =
    {
      read_next_due;
      advance_next_due;
      after_due_read_before_commit;
    }

  type 'error loop_update_plan = {
    after_update_state : generation:int -> (continue, 'error) Effect.t;
    construct_update :
      generation:int -> missed:int -> (unit, 'error) Effect.t;
    after_update_constructed_before_run : unit -> (unit, 'error) Effect.t;
  }

  let loop_update_plan ~after_update_state ~construct_update
      ~after_update_constructed_before_run =
    {
      after_update_state;
      construct_update;
      after_update_constructed_before_run;
    }

  type 'error loop_finish_plan = {
    finish_saturated : generation:int -> (unit, 'error) Effect.t;
  }

  let loop_finish_plan ~finish_saturated = { finish_saturated }

  type 'error loop_plan = {
    loop_due_plan : 'error loop_due_plan;
    loop_update_plan : 'error loop_update_plan;
    loop_finish_plan : 'error loop_finish_plan;
  }

  let loop_plan ~due ~updates ~finish =
    {
      loop_due_plan = due;
      loop_update_plan = updates;
      loop_finish_plan = finish;
    }

  type 'error start_gate_plan = {
    begin_start : generation:int -> (continue, 'error) Effect.t;
    set_next_due :
      generation:int -> next_due_ms:int -> (continue, 'error) Effect.t;
  }

  let start_gate_plan ~begin_start ~set_next_due =
    { begin_start; set_next_due }

  type 'error start_update_plan = {
    after_start_update : generation:int -> (continue, 'error) Effect.t;
    construct_start_update :
      generation:int -> missed:int -> (unit, 'error) Effect.t;
  }

  let start_update_plan ~construct_start_update ~after_start_update =
    { after_start_update; construct_start_update }

  type 'error start_daemon_plan = {
    install_cancel :
      generation:int -> cancel:(unit -> unit) -> (continue, 'error) Effect.t;
    cleanup_after_exit :
      generation:int -> (unit, 'error) Exit.t -> (unit, 'error) Effect.t;
    cleanup_failed_start :
      generation:int -> (unit, 'error) Exit.t -> (unit, 'error) Effect.t;
  }

  let start_daemon_plan ~install_cancel ~cleanup_after_exit
      ~cleanup_failed_start =
    {
      install_cancel;
      cleanup_after_exit;
      cleanup_failed_start;
    }

  type 'error start_plan = {
    start_gate_plan : 'error start_gate_plan;
    start_update_plan : 'error start_update_plan;
    start_daemon_plan : 'error start_daemon_plan;
  }

  let start_plan ~gate ~update ~daemon =
    {
      start_gate_plan = gate;
      start_update_plan = update;
      start_daemon_plan = daemon;
    }

  type ('attempt, 'cancel_hook) demand_claim = {
    claim_start_attempts : 'attempt list;
    claim_cancel_hooks : 'cancel_hook list;
  }

  let demand_claim ~start_attempts ~cancel_hooks =
    { claim_start_attempts = start_attempts; claim_cancel_hooks = cancel_hooks }

  type ('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan = {
    demand_acquire :
      Eta.Runtime_contract.t ->
      'capability ->
      (('attempt, 'cancel_hook) demand_claim, 'error) result;
    demand_rollback_unclaimed :
      'capability -> 'attempt list -> ('cancel_hook list, 'error) result;
  }

  let demand_claim_plan ~acquire ~rollback_unclaimed =
    {
      demand_acquire = acquire;
      demand_rollback_unclaimed = rollback_unclaimed;
    }

  type ('attempt, 'cancel_hook, 'error) demand_effect_plan = {
    run_cancel_hooks : 'cancel_hook list -> (unit, 'error) Effect.t;
    run_start_attempts : 'attempt list -> (unit, 'error) Effect.t;
  }

  let demand_effect_plan ~run_cancel_hooks ~run_start_attempts =
    { run_cancel_hooks; run_start_attempts }

  type ('capability, 'attempt, 'cancel_hook, 'error) demand_plan = {
    demand_claim_plan :
      ('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan;
    demand_effect_plan : ('attempt, 'cancel_hook, 'error) demand_effect_plan;
  }

  let demand_plan ~claim ~effects =
    { demand_claim_plan = claim; demand_effect_plan = effects }

  let run_cancellable ~install_cancel ~loop =
    Effect.Expert.make ~capabilities:[ `Concurrency ]
      ~leaf_name:"eta_signal.timer" @@ fun context ->
    let contract = Effect.Expert.contract context in
    let cancelled_exit = function
      | Exit.Error cause when Cause.is_interrupt_only cause -> Exit.Ok ()
      | exit -> exit
    in
    try
      contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
      let cancel () =
        contract.Runtime_contract.cancel cancel_context Timer_cancelled
      in
      match Effect.Expert.eval context (install_cancel ~cancel) with
      | Exit.Error _ as error -> error
      | Exit.Ok `Stop -> Exit.Ok ()
      | Exit.Ok `Continue -> Effect.Expert.eval context loop |> cancelled_exit
    with exn ->
      if Option.is_some (contract.Runtime_contract.cancellation_reason exn) then
        Exit.Ok ()
      else Effect.Expert.exit_of_exn context exn

  let current_runtime_contract () =
    Effect.Expert.make ~capabilities:[] ~leaf_name:"eta_signal.timer.demand.runtime_contract"
      (fun context -> Exit.Ok (Effect.Expert.contract context))

  let run_pending_cancel_hooks effects hooks_ref =
    match !hooks_ref with
    | [] -> Effect.unit
    | hooks ->
        effects.run_cancel_hooks hooks
        |> Effect.on_exit (fun _exit ->
               Effect.sync (fun () -> hooks_ref := []))

  let acquire_demand access claim runtime_contract =
    access.with_access (fun capability ->
        claim.demand_acquire runtime_contract capability)

  let rollback_unclaimed_starts access claim effects start_attempts =
    let open Syntax in
    let* cancel_hooks =
      access.with_access (fun capability ->
          claim.demand_rollback_unclaimed capability start_attempts)
    in
    effects.run_cancel_hooks cancel_hooks

  let refresh_demand access plan =
    let open Syntax in
    let claim = plan.demand_claim_plan in
    let effects = plan.demand_effect_plan in
    let* runtime_contract = current_runtime_contract () in
    Effect.acquire_use_release
      ~acquire:
        (acquire_demand access claim runtime_contract
        |> Effect.map (fun demand ->
               (demand.claim_start_attempts, ref demand.claim_cancel_hooks)))
      ~release:(fun (start_attempts, cancel_hooks_ref) ->
        let* () =
          rollback_unclaimed_starts access claim effects start_attempts
        in
        run_pending_cancel_hooks effects cancel_hooks_ref)
      (fun (start_attempts, cancel_hooks_ref) ->
        let* () = run_pending_cancel_hooks effects cancel_hooks_ref in
        effects.run_start_attempts start_attempts)

  let rec run_update_batch updates generation remaining ~missed =
    let open Syntax in
    if remaining <= 0 then Effect.pure `Continue
    else
      let* status = updates.after_update_state ~generation in
      match status with
      | `Stop -> Effect.pure `Stop
      | `Continue ->
          let* update =
            Effect.sync (fun () ->
                updates.construct_update ~generation ~missed)
          in
          let* () = updates.after_update_constructed_before_run () in
          let* () = update in
          run_update_batch updates generation (remaining - 1) ~missed

  let rec run_updates updates generation remaining ~missed =
    let open Syntax in
    match Timer_policy.update_batch ~remaining with
    | None -> Effect.unit
    | Some batch ->
        Timer_policy.update_batch_result batch
          ~plan:(fun ~count ~remaining ~yield ->
            let* status = run_update_batch updates generation count ~missed in
            match status with
            | `Stop -> Effect.unit
            | `Continue ->
                if not yield then Effect.unit
                else
                  let* () = Effect.yield in
                  run_updates updates generation remaining ~missed)

  let rec run_loop plan ~generation ~interval_ms ~next_due_ms
      ~catch_up_policy =
    let open Syntax in
    let due = plan.loop_due_plan in
    let updates = plan.loop_update_plan in
    let finish = plan.loop_finish_plan in
    let* next_due = due.read_next_due ~generation ~fallback:next_due_ms in
    match next_due with
    | None -> Effect.unit
    | Some next_due_ms ->
        let* now_ms = Effect.now_ms in
        let delay_ms = Timer_policy.sleep_delay_ms ~now_ms ~next_due_ms in
        let* () = Effect.sleep (Duration.ms delay_ms) in
        let* next_due = due.read_next_due ~generation ~fallback:next_due_ms in
        (match next_due with
        | None -> Effect.unit
        | Some due_ms ->
            let* now_ms = Effect.now_ms in
            let wake =
              Timer_policy.daemon_wake_plan ~catch_up_policy ~interval_ms
                ~next_due_ms:due_ms ~now_ms
            in
            Timer_policy.wake_plan_result wake
              ~plan:
                (fun ~next_due_ms ~saturated_due ~update_count
                     ~update_missed ->
                  let continue () =
                    run_loop plan ~generation ~interval_ms ~next_due_ms
                      ~catch_up_policy
                  in
                  let* () = due.after_due_read_before_commit () in
                  let* advance =
                    due.advance_next_due ~generation ~expected:due_ms
                      ~next_due_ms
                  in
                  match advance with
                  | `Stop -> Effect.unit
                  | `Stale -> continue ()
                  | `Advanced ->
                      let* () =
                        run_updates updates generation update_count
                          ~missed:update_missed
                      in
                      let* () =
                        if saturated_due then
                          finish.finish_saturated ~generation
                        else Effect.unit
                      in
                      let* status = updates.after_update_state ~generation in
                      match status with
                      | `Continue -> continue ()
                      | `Stop -> Effect.unit))

  let start plan loop_plan ~generation ~interval_ms
      ~update_on_start ~catch_up_policy =
    let open Syntax in
    let gate = plan.start_gate_plan in
    let update = plan.start_update_plan in
    let daemon = plan.start_daemon_plan in
    let start_loop () =
      let* now_ms = Effect.now_ms in
      let next_due_ms =
        Timer_policy.initial_next_due_ms ~now_ms ~interval_ms
      in
      let* status = gate.set_next_due ~generation ~next_due_ms in
      match status with
      | `Stop -> Effect.unit
      | `Continue ->
          Effect.daemon
            (run_cancellable
               ~install_cancel:(fun ~cancel ->
                 daemon.install_cancel ~generation ~cancel)
               ~loop:
                 (run_loop loop_plan ~generation ~interval_ms ~next_due_ms
                    ~catch_up_policy
                 |> Effect.on_exit
                      (daemon.cleanup_after_exit ~generation)))
    in
    let start () =
      if update_on_start then
        let* () = update.construct_start_update ~generation ~missed:1 in
        let* status = update.after_start_update ~generation in
        match status with
        | `Continue -> start_loop ()
        | `Stop -> Effect.unit
      else start_loop ()
    in
    let* status = gate.begin_start ~generation in
    match status with
    | `Stop -> Effect.unit
    | `Continue ->
        start () |> Effect.on_exit (daemon.cleanup_failed_start ~generation)
end

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

type 'operation node_runner = {
  run_node : 'err. 'operation node -> (unit, 'err) Eta.Effect.t;
}

type 'operation start = {
  run : 'err. 'operation node -> (unit, 'err) Eta.Effect.t;
}

let start ~(run : 'operation node_runner) = { run = run.run_node }

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
let start_effect timer = timer.timer_start timer

let validate_runtime ~runtime_mismatch runtime_contract timer =
  match
    Eta_signal_timer_policy.validate_runtime
      ~same_runtime:Eta.Runtime_contract.same_runtime
      ~expected:timer.timer_runtime_contract ~actual:runtime_contract
  with
  | Ok () -> Ok ()
  | Error `Runtime_mismatch -> Error (runtime_mismatch runtime_contract timer)

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

let refresh_node_on_demand ~runtime_mismatch ~current_snapshot
    ~effective_state ~remember ~run_operation context timer =
  match
    validate_runtime ~runtime_mismatch
      (Eta_signal_timer_policy.refresh_runtime_contract context)
      timer
  with
  | Error _ as error -> error
  | Ok () -> (
      let token = Eta_signal_timer_policy.refresh_token context in
      if
        can_refresh_on_demand ~token
          ~current_snapshot:(current_snapshot timer)
          ~effective_state:(effective_state timer)
          timer
      then (
        remember timer;
        match timer.timer_refresh_operation with
        | None -> Ok ()
        | Some operation ->
            let now_ms =
              Eta_signal_timer_policy.refresh_sample_now_ms context
            in
            run_operation timer ~now_ms operation;
            Ok ())
      else Ok ())

type ('timer, 'eff) start_attempt = {
  attempt_timer : 'timer;
  attempt_effect : 'eff;
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

type state_runner = {
  run_state : 'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

type daemon_state_access = {
  daemon_with_state :
    'a 'error. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

let daemon_state_access ~(with_state : state_runner) =
  { daemon_with_state = with_state.run_state }

type 'timer update_runner = {
  run_update :
    'error. 'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
}

type 'timer daemon_update = {
  daemon_update :
    'error.
    'timer -> generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
}

let daemon_update ~(update : 'timer update_runner) =
  { daemon_update = update.run_update }

type hook_runner = {
  run_hook : 'error. unit -> (unit, 'error) Eta.Effect.t;
}

type daemon_hooks = {
  daemon_after_due_read_before_commit :
    'error. unit -> (unit, 'error) Eta.Effect.t;
  daemon_after_update_constructed_before_run :
    'error. unit -> (unit, 'error) Eta.Effect.t;
}

let daemon_hooks ~(after_due_read_before_commit : hook_runner)
    ~(after_update_constructed_before_run : hook_runner) =
  {
    daemon_after_due_read_before_commit =
      after_due_read_before_commit.run_hook;
    daemon_after_update_constructed_before_run =
      after_update_constructed_before_run.run_hook;
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

type ('id, 'necessary, 'runtime, 'timer, 'eff, 'error) demand_port = {
  demand_collect_necessary : unit -> 'necessary;
  demand_collect_timers : unit -> ('id * 'timer) list;
  demand_is_necessary : 'necessary -> 'id -> bool;
  demand_validate_runtime : 'runtime -> 'timer -> (unit, 'error) result;
  demand_state : 'timer state_port;
  demand_start_effect : 'timer -> 'eff;
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

type ('id, 'operation, 'error) node_demand_plan = {
  node_demand_timers : ('id * 'operation node) list;
  node_demand_is_necessary : 'id -> bool;
  node_demand_runtime_mismatch :
    Eta.Runtime_contract.t -> 'operation node -> 'error;
  node_demand_state : 'operation node state_port;
}

let node_demand_plan ~timers ~is_necessary ~runtime_mismatch ~state =
  {
    node_demand_timers = timers;
    node_demand_is_necessary = is_necessary;
    node_demand_runtime_mismatch = runtime_mismatch;
    node_demand_state = state;
  }

type ('capability, 'error) access_runner = {
  run_access :
    'a. ('capability -> ('a, 'error) result) -> ('a, 'error) Eta.Effect.t;
}

type ('capability, 'error) demand_effect_access = {
  demand_with_access :
    'a.
    ('capability -> ('a, 'error) result) ->
    ('a, 'error) Eta.Effect.t;
}

let demand_effect_access
    ~(with_access : ('capability, 'error) access_runner) =
  { demand_with_access = with_access.run_access }

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

type ('capability, 'id, 'operation, 'error) node_demand_effect_port = {
  node_demand_effect_plan :
    Eta.Runtime_contract.t ->
    'capability ->
    ('id, 'operation, 'error) node_demand_plan;
}

let node_demand_effect_port ~plan =
  { node_demand_effect_plan = plan }

type ('capability, 'id, 'operation, 'error) node_demand_refresh = {
  refresh_advance_generation : int -> int;
  refresh_access : ('capability, 'error) demand_effect_access;
  refresh_demand :
    ('capability, 'id, 'operation, 'error) node_demand_effect_port;
}

let node_demand_refresh ~advance_generation ~access ~demand =
  {
    refresh_advance_generation = advance_generation;
    refresh_access = access;
    refresh_demand = demand;
  }

let start_attempt ~timer ~eff =
  { attempt_timer = timer; attempt_effect = eff }

let start_attempt_effect attempt =
  attempt.attempt_effect

let start_attempt_effects attempts =
  List.map start_attempt_effect attempts

let apply_start_plan ~set_current_state ~start_effect timer plan =
  Eta_signal_timer_policy.start_plan_result plan
    ~plan:(fun ~state ~generation:_ ~cancel_hooks ->
      set_current_state timer state;
      (start_attempt ~timer ~eff:(start_effect timer), cancel_hooks))

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

let preflight_start ~advance_generation port timer =
  Eta_signal_timer_policy.preflight_start ~advance_generation
    ~effective_state:(port.state_effective timer)
    ~current_state:(port.state_current timer)

let preflight_stop ~advance_generation port timer =
  Eta_signal_timer_policy.preflight_stop ~advance_generation
    ~effective_state:(port.state_effective timer)
    ~current_state:(port.state_current timer)

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
       ~collect_necessary:(fun () -> ())
       ~collect_timers:(fun () -> plan.node_demand_timers)
       ~is_necessary:(fun () id -> plan.node_demand_is_necessary id)
       ~validate_runtime:
         (validate_runtime
            ~runtime_mismatch:plan.node_demand_runtime_mismatch)
       ~state:plan.node_demand_state ~start_effect)
    runtime

let refresh_demand_effect access port =
  let claim =
    Adapter.demand_claim_plan
      ~acquire:(fun runtime_contract capability ->
        match port.demand_acquire runtime_contract capability with
        | Error _ as error -> error
        | Ok effects ->
            demand_effects_plan effects ~plan:(fun ~start_attempts
                ~cancel_hooks ->
              Ok
                (Adapter.demand_claim ~start_attempts
                   ~cancel_hooks)))
      ~rollback_unclaimed:port.demand_rollback_unclaimed
  in
  let effects =
    Adapter.demand_effect_plan
      ~run_cancel_hooks:port.demand_run_cancel_hooks
      ~run_start_attempts:port.demand_run_start_attempts
  in
  Adapter.refresh_demand
    (Adapter.access
       ~with_access:{ run_access = (fun f -> access.demand_with_access f) })
    (Adapter.demand_plan ~claim ~effects)

let run_node_demand_refresh refresh =
  let active_plan = ref None in
  refresh_demand_effect refresh.refresh_access
    (demand_effect_port
       ~acquire:(fun runtime capability ->
          let port = refresh.refresh_demand in
          let plan = port.node_demand_effect_plan runtime capability in
          active_plan := Some plan;
          refresh_node_demand_plan
            ~advance_generation:refresh.refresh_advance_generation
            ~cancel_running:true plan runtime)
       ~rollback_unclaimed:(fun _capability attempts ->
          match !active_plan with
          | None -> Ok []
          | Some plan ->
              active_plan := None;
              Ok
                (rollback_unclaimed_start_attempts
                   ~advance_generation:refresh.refresh_advance_generation
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

let finish_node ~advance_generation port timer =
  let plan =
    Eta_signal_timer_policy.finish ~advance_generation
      (port.state_current timer)
  in
  Eta_signal_timer_policy.finish_plan_result plan
    ~plan:(fun ~state ~cancel_hooks:_ -> port.state_set_current timer state)

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
  let loop_due =
    Adapter.loop_due_plan
      ~read_next_due:(fun ~generation ~fallback ->
        with_state (fun () ->
            read_next_due port timer ~generation ~fallback))
      ~advance_next_due:(fun ~generation ~expected ~next_due_ms ->
        with_state (fun () ->
            advance_next_due port timer ~generation ~expected ~next_due_ms))
      ~after_due_read_before_commit:hooks.daemon_after_due_read_before_commit
  in
  let loop_updates =
    Adapter.loop_update_plan
      ~after_update_state
      ~construct_update:(fun ~generation ~missed ->
        update.daemon_update timer ~generation ~missed)
      ~after_update_constructed_before_run:
        hooks.daemon_after_update_constructed_before_run
  in
  let loop_finish =
    Adapter.loop_finish_plan
      ~finish_saturated:(fun ~generation ->
        with_state (fun () ->
            finish_saturated ~advance_generation port timer ~generation))
  in
  let loop_plan =
    Adapter.loop_plan ~due:loop_due ~updates:loop_updates
      ~finish:loop_finish
  in
  let start_gate =
    Adapter.start_gate_plan
      ~begin_start:(fun ~generation ->
        with_state (fun () -> begin_start port timer ~generation))
      ~set_next_due:(fun ~generation ~next_due_ms ->
        with_state (fun () ->
            set_next_due port timer ~generation ~next_due_ms))
  in
  let start_update =
    Adapter.start_update_plan
      ~construct_start_update:(fun ~generation ~missed ->
        update.daemon_update timer ~generation ~missed)
      ~after_start_update:after_update_state
  in
  let start_daemon =
    Adapter.start_daemon_plan
      ~install_cancel:(fun ~generation ~cancel ->
        with_state (fun () ->
            install_cancel port timer ~generation ~cancel))
      ~cleanup_after_exit ~cleanup_failed_start
  in
  let start_plan =
    Adapter.start_plan ~gate:start_gate
      ~update:start_update ~daemon:start_daemon
  in
  Adapter.start start_plan loop_plan ~generation
    ~interval_ms ~update_on_start ~catch_up_policy

let create_daemon_node ~runtime_contract ~refresh_when_inactive
    ~refresh_operation context ~interval_ms ~update_on_start
    ~catch_up_policy =
  create_node ~runtime_contract ~refresh_when_inactive ~refresh_operation
    ~start:
      (start
         ~run:
           { run_node =
             (fun timer ->
               let generation =
                 Eta_signal_timer_policy.state_generation
                   (context.daemon_state.state_current timer)
               in
               start_daemon context timer ~generation ~interval_ms
                 ~update_on_start ~catch_up_policy)
           })
