type ('owner, 'hook, 'event, 'error) result =
  | Pure_ok of
      'hook list
      * 'event list
      * ('owner, Eta_signal_stabilization.delivering)
        Eta_signal_stabilization.token
  | Pure_graph_error of 'hook list * 'error
  | Pure_defect of 'hook list * exn * Printexc.raw_backtrace

type 'error errors = {
  reentrant_stabilization : 'error;
  classify_graph_error : exn -> 'error option;
}

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure = {
  advance_generation : 'capability -> unit;
  begin_staging : 'capability -> 'staging;
  drain_pending : 'capability -> 'pending list;
  release_pending_marks : 'capability -> 'pending list -> unit;
  active_observers : 'capability -> 'observer list;
  stage_pending : 'capability -> 'pending list -> unit;
  plan_staged_binds : 'capability -> 'observer list -> unit;
  sort_delivery_observers : 'capability -> 'observer list -> 'observer list;
  collect_events : 'capability -> 'observer list -> 'event list;
  commit_staging : 'capability -> 'staging -> 'hook list;
  mark_events_pending : 'capability -> 'event list -> unit;
  update_necessity : 'capability -> unit;
}

type ('capability, 'pending, 'observer, 'hook, 'staging) rollback = {
  rollback_staging : 'capability -> 'staging -> 'hook list;
  mark_observers_failed_without_current : 'capability -> 'observer list -> unit;
  requeue_pending : 'capability -> 'pending list -> unit;
}

type 'capability timer_refresh = {
  clear_active_timer_refresh : 'capability -> unit;
}

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t = {
  errors : 'error errors;
  pure :
    ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure;
  rollback : ('capability, 'pending, 'observer, 'hook, 'staging) rollback;
  timer_refresh : 'capability timer_refresh;
}

type ('event, 'error) delivery = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}

let rollback state pure_token capability ops observers pending staging =
  let hooks = ops.rollback.rollback_staging capability staging in
  ops.rollback.mark_observers_failed_without_current capability observers;
  ops.rollback.requeue_pending capability pending;
  ops.timer_refresh.clear_active_timer_refresh capability;
  ignore
    (Eta_signal_stabilization.rollback_to_idle state pure_token
      : (_, Eta_signal_stabilization.idle) Eta_signal_stabilization.token);
  hooks

let run state capability ops =
  match Eta_signal_stabilization.begin_pure state with
  | Error `Reentrant_stabilization ->
      Pure_graph_error ([], ops.errors.reentrant_stabilization)
  | Ok pure_token ->
      ops.pure.advance_generation capability;
      let staging = ops.pure.begin_staging capability in
      let pending = ops.pure.drain_pending capability in
      ops.pure.release_pending_marks capability pending;
      let observers = ops.pure.active_observers capability in
      try
        ops.pure.stage_pending capability pending;
        ops.pure.plan_staged_binds capability observers;
        let delivery_observers =
          ops.pure.sort_delivery_observers capability observers
        in
        let events = ops.pure.collect_events capability delivery_observers in
        let hooks = ops.pure.commit_staging capability staging in
        ops.pure.mark_events_pending capability events;
        ops.pure.update_necessity capability;
        ops.timer_refresh.clear_active_timer_refresh capability;
        let delivering_token =
          Eta_signal_stabilization.commit_to_delivering state pure_token
        in
        Pure_ok (hooks, events, delivering_token)
      with exn -> (
        let backtrace = Printexc.get_raw_backtrace () in
        let hooks =
          rollback state pure_token capability ops observers pending staging
        in
        match ops.errors.classify_graph_error exn with
        | Some err -> Pure_graph_error (hooks, err)
        | None -> Pure_defect (hooks, exn, backtrace))

let finish_delivery ops =
  let open Eta in
  ops.run_pending_cleanup ()
  |> Effect.on_exit (fun _exit -> ops.finish ())

let deliver ops events =
  let open Eta in
  (ops.run_pending_cleanup ()
  |> Effect.bind (fun () -> ops.run_events events)
  |> Effect.bind ops.mark_complete)
  |> Effect.on_exit (fun _exit -> finish_delivery ops)
