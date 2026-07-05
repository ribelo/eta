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

type ('capability, 'attempt, 'cancel_hook, 'error) demand_callbacks = {
  acquire_demand :
    Runtime_contract.t ->
    'capability ->
    ('attempt list * 'cancel_hook list, 'error) result;
  rollback_unclaimed_starts :
    'capability -> 'attempt list -> ('cancel_hook list, 'error) result;
  run_cancel_hooks : 'cancel_hook list -> (unit, 'error) Effect.t;
  run_start_attempts : 'attempt list -> (unit, 'error) Effect.t;
}

let demand_callbacks ~acquire_demand ~rollback_unclaimed_starts
    ~run_cancel_hooks ~run_start_attempts =
  {
    acquire_demand;
    rollback_unclaimed_starts;
    run_cancel_hooks;
    run_start_attempts;
  }

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

let run_pending_cancel_hooks callbacks hooks_ref =
  match !hooks_ref with
  | [] -> Effect.unit
  | hooks ->
      callbacks.run_cancel_hooks hooks
      |> Effect.on_exit (fun _exit -> Effect.sync (fun () -> hooks_ref := []))

let acquire_demand access callbacks runtime_contract =
  access.with_access (fun capability ->
      callbacks.acquire_demand runtime_contract capability)

let rollback_unclaimed_starts access callbacks start_attempts =
  access.with_access (fun capability ->
      callbacks.rollback_unclaimed_starts capability start_attempts)
  |> Effect.bind callbacks.run_cancel_hooks

let refresh_demand access callbacks =
  current_runtime_contract ()
  |> Effect.bind (fun runtime_contract ->
         Effect.acquire_use_release
           ~acquire:
             (acquire_demand access callbacks runtime_contract
             |> Effect.map (fun (start_attempts, cancel_hooks) ->
                    (start_attempts, ref cancel_hooks)))
           ~release:(fun (start_attempts, cancel_hooks_ref) ->
             rollback_unclaimed_starts access callbacks start_attempts
             |> Effect.bind (fun () ->
                    run_pending_cancel_hooks callbacks cancel_hooks_ref))
           (fun (start_attempts, cancel_hooks_ref) ->
             run_pending_cancel_hooks callbacks cancel_hooks_ref
             |> Effect.bind (fun () -> callbacks.run_start_attempts start_attempts)))

let rec run_update_batch callbacks generation remaining ~missed =
  if remaining <= 0 then Effect.pure `Continue
  else
    callbacks.after_update_state ~generation
    |> Effect.bind (function
         | `Stop -> Effect.pure `Stop
         | `Continue ->
             Effect.sync (fun () ->
                 callbacks.construct_update ~generation ~missed)
             |> Effect.bind (fun update ->
                    callbacks.after_update_constructed_before_run ()
                    |> Effect.bind (fun () -> update))
             |> Effect.bind (fun () ->
                    run_update_batch callbacks generation (remaining - 1)
                      ~missed))

let rec run_updates callbacks generation remaining ~missed =
  match Timer_policy.update_batch ~remaining with
  | None -> Effect.unit
  | Some batch ->
      run_update_batch callbacks generation batch.update_batch_count ~missed
      |> Effect.bind (function
           | `Stop -> Effect.unit
           | `Continue ->
               if not batch.update_batch_yield then Effect.unit
               else
                 Effect.yield
                 |> Effect.bind (fun () ->
                        run_updates callbacks generation
                          batch.update_batch_remaining ~missed))

let rec run_loop callbacks ~generation ~interval_ms ~next_due_ms
    ~catch_up_policy =
  callbacks.read_next_due ~generation ~fallback:next_due_ms
  |> Effect.bind (function
       | None -> Effect.unit
       | Some next_due_ms ->
           Effect.now
           |> Effect.bind (fun now_ms ->
                  let delay_ms =
                    Timer_policy.sleep_delay_ms ~now_ms ~next_due_ms
                  in
                  Effect.sleep (Duration.ms delay_ms))
           |> Effect.bind (fun () ->
                  callbacks.read_next_due ~generation ~fallback:next_due_ms
                  |> Effect.bind (function
                       | None -> Effect.unit
                       | Some due_ms ->
                           Effect.now
                           |> Effect.bind (fun now_ms ->
                                  let wake =
                                    Timer_policy.daemon_wake_plan
                                      ~catch_up_policy ~interval_ms
                                      ~next_due_ms:due_ms ~now_ms
                                  in
                                  let next_due_ms = wake.wake_next_due_ms in
                                  let update_count = wake.wake_update_count in
                                  let update_missed =
                                    wake.wake_update_missed
                                  in
                                  let saturated_due =
                                    wake.wake_saturated_due
                                  in
                                  let continue () =
                                    run_loop callbacks ~generation ~interval_ms
                                      ~next_due_ms ~catch_up_policy
                                  in
                                  callbacks.after_due_read_before_commit ()
                                  |> Effect.bind (fun () ->
                                         callbacks.advance_next_due ~generation
                                           ~expected:due_ms ~next_due_ms
                                         |> Effect.bind (function
                                              | `Stop -> Effect.unit
                                              | `Stale -> continue ()
                                              | `Advanced ->
                                                  run_updates callbacks
                                                    generation update_count
                                                    ~missed:update_missed
                                                  |> Effect.bind (fun () ->
                                                         (if saturated_due then
                                                            callbacks
                                                              .finish_saturated
                                                              ~generation
                                                          else Effect.unit)
                                                         |> Effect.bind
                                                              (fun () ->
                                                                callbacks
                                                                  .after_update_state
                                                                  ~generation
                                                                |> Effect.bind
                                                                     (function
                                                                     | `Continue ->
                                                                         continue
                                                                           ()
                                                                     | `Stop ->
                                                                         Effect
                                                                           .unit)))))))))

let start start_callbacks loop_callbacks ~generation ~interval_ms
    ~update_on_start ~catch_up_policy =
  let start_loop () =
    Effect.now
    |> Effect.bind (fun now_ms ->
           let next_due_ms =
             Timer_policy.initial_next_due_ms ~now_ms ~interval_ms
           in
           start_callbacks.set_next_due ~generation ~next_due_ms
           |> Effect.bind (function
                | `Stop -> Effect.unit
                | `Continue ->
                    Effect.daemon
                      (run_cancellable
                         ~install_cancel:(fun ~cancel ->
                           start_callbacks.install_cancel ~generation ~cancel)
                         ~loop:
                           (run_loop loop_callbacks ~generation ~interval_ms
                              ~next_due_ms ~catch_up_policy
                           |> Effect.on_exit
                                (start_callbacks.cleanup_after_exit
                                   ~generation)))))
  in
  let start () =
    if update_on_start then
      start_callbacks.construct_start_update ~generation ~missed:1
      |> Effect.bind (fun () ->
             start_callbacks.after_start_update ~generation
             |> Effect.bind (function
                  | `Continue -> start_loop ()
                  | `Stop -> Effect.unit))
    else start_loop ()
  in
  start_callbacks.begin_start ~generation
  |> Effect.bind (function
       | `Stop -> Effect.unit
       | `Continue ->
           start ()
           |> Effect.on_exit
                (start_callbacks.cleanup_failed_start ~generation))
