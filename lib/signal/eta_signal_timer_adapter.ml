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
