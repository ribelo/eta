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

let access :
    type capability error.
    with_access:
      ('a. (capability -> ('a, error) result) -> ('a, error) Effect.t) ->
    (capability, error) access =
 fun ~with_access -> { with_access }

type 'error callbacks = {
  read_next_due :
    generation:int -> fallback:int -> (int option, 'error) Effect.t;
  advance_next_due :
    generation:int ->
    expected:int ->
    next_due_ms:int ->
    (advance, 'error) Effect.t;
  after_update_state : generation:int -> (continue, 'error) Effect.t;
  finish_saturated : generation:int -> (unit, 'error) Effect.t;
  construct_update : generation:int -> missed:int -> (unit, 'error) Effect.t;
  after_due_read_before_commit : unit -> (unit, 'error) Effect.t;
  after_update_constructed_before_run : unit -> (unit, 'error) Effect.t;
}

let callbacks ~read_next_due ~advance_next_due ~after_update_state
    ~finish_saturated ~construct_update ~after_due_read_before_commit
    ~after_update_constructed_before_run =
  {
    read_next_due;
    advance_next_due;
    after_update_state;
    finish_saturated;
    construct_update;
    after_due_read_before_commit;
    after_update_constructed_before_run;
  }

type 'error start_callbacks = {
  begin_start : generation:int -> (continue, 'error) Effect.t;
  set_next_due :
    generation:int -> next_due_ms:int -> (continue, 'error) Effect.t;
  after_start_update : generation:int -> (continue, 'error) Effect.t;
  construct_start_update :
    generation:int -> missed:int -> (unit, 'error) Effect.t;
  install_cancel :
    generation:int -> cancel:(unit -> unit) -> (continue, 'error) Effect.t;
  cleanup_after_exit :
    generation:int -> (unit, 'error) Exit.t -> (unit, 'error) Effect.t;
  cleanup_failed_start :
    generation:int -> (unit, 'error) Exit.t -> (unit, 'error) Effect.t;
}

let start_callbacks ~begin_start ~set_next_due ~after_start_update
    ~construct_start_update ~install_cancel ~cleanup_after_exit
    ~cleanup_failed_start =
  {
    begin_start;
    set_next_due;
    after_start_update;
    construct_start_update;
    install_cancel;
    cleanup_after_exit;
    cleanup_failed_start;
  }

type ('attempt, 'cancel_hook) demand_claim = {
  claim_start_attempts : 'attempt list;
  claim_cancel_hooks : 'cancel_hook list;
}

let demand_claim ~start_attempts ~cancel_hooks =
  { claim_start_attempts = start_attempts; claim_cancel_hooks = cancel_hooks }

type ('capability, 'attempt, 'cancel_hook, 'error) demand_claim_plan = {
  demand_acquire :
    Runtime_contract.t ->
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
  Effect.Expert.make ~leaf_name:"eta_signal.timer" @@ fun context ->
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
  Effect.Expert.make ~leaf_name:"eta_signal.timer.demand.runtime_contract"
    (fun context -> Exit.Ok (Effect.Expert.contract context))

let run_pending_cancel_hooks effects hooks_ref =
  match !hooks_ref with
  | [] -> Effect.unit
  | hooks ->
      effects.run_cancel_hooks hooks
      |> Effect.on_exit (fun _exit -> Effect.sync (fun () -> hooks_ref := []))

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

let rec run_update_batch callbacks generation remaining ~missed =
  let open Syntax in
  if remaining <= 0 then Effect.pure `Continue
  else
    let* status = callbacks.after_update_state ~generation in
    match status with
    | `Stop -> Effect.pure `Stop
    | `Continue ->
        let* update =
          Effect.sync (fun () -> callbacks.construct_update ~generation ~missed)
        in
        let* () = callbacks.after_update_constructed_before_run () in
        let* () = update in
        run_update_batch callbacks generation (remaining - 1) ~missed

let rec run_updates callbacks generation remaining ~missed =
  let open Syntax in
  match Timer_policy.update_batch ~remaining with
  | None -> Effect.unit
  | Some batch ->
      Timer_policy.update_batch_result batch
        ~plan:(fun ~count ~remaining ~yield ->
          let* status = run_update_batch callbacks generation count ~missed in
          match status with
          | `Stop -> Effect.unit
          | `Continue ->
              if not yield then Effect.unit
              else
                let* () = Effect.yield in
                run_updates callbacks generation remaining ~missed)

let rec run_loop callbacks ~generation ~interval_ms ~next_due_ms
    ~catch_up_policy =
  let open Syntax in
  let* next_due = callbacks.read_next_due ~generation ~fallback:next_due_ms in
  match next_due with
  | None -> Effect.unit
  | Some next_due_ms ->
      let* now_ms = Effect.now in
      let delay_ms = Timer_policy.sleep_delay_ms ~now_ms ~next_due_ms in
      let* () = Effect.sleep (Duration.ms delay_ms) in
      let* due = callbacks.read_next_due ~generation ~fallback:next_due_ms in
      (match due with
      | None -> Effect.unit
      | Some due_ms ->
          let* now_ms = Effect.now in
          let wake =
            Timer_policy.daemon_wake_plan ~catch_up_policy ~interval_ms
              ~next_due_ms:due_ms ~now_ms
          in
          Timer_policy.wake_plan_result wake
            ~plan:
              (fun ~next_due_ms ~saturated_due ~update_count ~update_missed ->
                let continue () =
                  run_loop callbacks ~generation ~interval_ms ~next_due_ms
                    ~catch_up_policy
                in
                let* () = callbacks.after_due_read_before_commit () in
                let* advance =
                  callbacks.advance_next_due ~generation ~expected:due_ms
                    ~next_due_ms
                in
                match advance with
                | `Stop -> Effect.unit
                | `Stale -> continue ()
                | `Advanced ->
                    let* () =
                      run_updates callbacks generation update_count
                        ~missed:update_missed
                    in
                    let* () =
                      if saturated_due then
                        callbacks.finish_saturated ~generation
                      else Effect.unit
                    in
                    let* status = callbacks.after_update_state ~generation in
                    match status with
                    | `Continue -> continue ()
                    | `Stop -> Effect.unit))

let start start_callbacks loop_callbacks ~generation ~interval_ms
    ~update_on_start ~catch_up_policy =
  let open Syntax in
  let start_loop () =
    let* now_ms = Effect.now in
    let next_due_ms =
      Timer_policy.initial_next_due_ms ~now_ms ~interval_ms
    in
    let* status = start_callbacks.set_next_due ~generation ~next_due_ms in
    match status with
    | `Stop -> Effect.unit
    | `Continue ->
        Effect.daemon
          (run_cancellable
             ~install_cancel:(fun ~cancel ->
               start_callbacks.install_cancel ~generation ~cancel)
             ~loop:
               (run_loop loop_callbacks ~generation ~interval_ms ~next_due_ms
                  ~catch_up_policy
               |> Effect.on_exit
                    (start_callbacks.cleanup_after_exit ~generation)))
  in
  let start () =
    if update_on_start then
      let* () = start_callbacks.construct_start_update ~generation ~missed:1 in
      let* status = start_callbacks.after_start_update ~generation in
      match status with
      | `Continue -> start_loop ()
      | `Stop -> Effect.unit
    else start_loop ()
  in
  let* status = start_callbacks.begin_start ~generation in
  match status with
  | `Stop -> Effect.unit
  | `Continue ->
      start ()
      |> Effect.on_exit (start_callbacks.cleanup_failed_start ~generation)
