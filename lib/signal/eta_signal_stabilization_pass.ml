type ('owner, 'hook, 'event, 'error) result =
  | Pure_ok of
      'hook list
      * 'event list
      * ('owner, Eta_signal_stabilization.delivering)
        Eta_signal_stabilization.token
  | Pure_graph_error of 'hook list * 'error
  | Pure_defect of 'hook list * exn * Printexc.raw_backtrace

let graph_error ~hooks err =
  Pure_graph_error (hooks, err)

let result result ~pure_ok ~graph_error ~defect =
  match result with
  | Pure_ok (hooks, events, delivering_token) ->
      pure_ok ~hooks ~events ~delivering_token
  | Pure_graph_error (hooks, err) -> graph_error ~hooks err
  | Pure_defect (hooks, exn, backtrace) -> defect ~hooks exn backtrace

type 'error errors = {
  reentrant_stabilization : 'error;
  classify_graph_error : exn -> 'error option;
}

let errors ~reentrant_stabilization ~classify_graph_error =
  { reentrant_stabilization; classify_graph_error }

type 'capability pure_context = Pure_context of 'capability
type 'capability rollback_context = Rollback_context of 'capability
type 'capability timer_refresh_context = Timer_refresh_context of 'capability

let pure_capability (Pure_context capability) = capability
let rollback_capability (Rollback_context capability) = capability
let timer_refresh_capability (Timer_refresh_context capability) = capability

type ('capability, 'observer, 'event) observer_plan = {
  observers : 'observer list;
  collect_events :
    'capability pure_context -> 'observer list -> 'event list;
  mark_events_pending : 'capability pure_context -> 'event list -> unit;
}

let observer_plan ~observers ~collect_events ~mark_events_pending =
  { observers; collect_events; mark_events_pending }

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure = {
  advance_generation : 'capability pure_context -> unit;
  begin_staging : 'capability pure_context -> 'staging;
  drain_pending : 'capability pure_context -> 'pending list;
  release_pending_marks : 'capability pure_context -> 'pending list -> unit;
  observer_plan :
    'capability pure_context ->
    ('capability, 'observer, 'event) observer_plan;
  stage_pending : 'capability pure_context -> 'pending list -> unit;
  plan_staged_binds : 'capability pure_context -> 'observer list -> unit;
  commit_staging : 'capability pure_context -> 'staging -> 'hook list;
  update_necessity : 'capability pure_context -> unit;
}

let pure_ops ~advance_generation ~begin_staging ~drain_pending
    ~release_pending_marks ~observer_plan ~stage_pending
    ~plan_staged_binds ~commit_staging ~update_necessity =
  {
    advance_generation;
    begin_staging;
    drain_pending;
    release_pending_marks;
    observer_plan;
    stage_pending;
    plan_staged_binds;
    commit_staging;
    update_necessity;
  }

type ('capability, 'pending, 'observer, 'hook, 'staging) rollback = {
  rollback_staging : 'capability rollback_context -> 'staging -> 'hook list;
  mark_observers_failed_without_current :
    'capability rollback_context -> 'observer list -> unit;
  requeue_pending : 'capability rollback_context -> 'pending list -> unit;
}

let rollback_ops ~rollback_staging ~mark_observers_failed_without_current
    ~requeue_pending =
  {
    rollback_staging;
    mark_observers_failed_without_current;
    requeue_pending;
  }

type 'capability timer_refresh = {
  clear_active_timer_refresh : 'capability timer_refresh_context -> unit;
}

let timer_refresh_ops ~clear_active_timer_refresh =
  { clear_active_timer_refresh }

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) t = {
  errors : 'error errors;
  pure :
    ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure;
  rollback : ('capability, 'pending, 'observer, 'hook, 'staging) rollback;
  timer_refresh : 'capability timer_refresh;
}

let pass_ops ~errors ~pure ~rollback ~timer_refresh =
  { errors; pure; rollback; timer_refresh }

type ('event, 'error) delivery = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}

let delivery_ops ~run_pending_cleanup ~run_events ~mark_complete ~finish =
  { run_pending_cleanup; run_events; mark_complete; finish }

let rollback state pure_token rollback_context timer_refresh_context ops
    observers pending staging =
  let hooks = ops.rollback.rollback_staging rollback_context staging in
  ops.rollback.mark_observers_failed_without_current rollback_context
    observers;
  ops.rollback.requeue_pending rollback_context pending;
  ops.timer_refresh.clear_active_timer_refresh timer_refresh_context;
  ignore
    (Eta_signal_stabilization.rollback_to_idle state pure_token
      : (_, Eta_signal_stabilization.idle) Eta_signal_stabilization.token);
  hooks

let rollback_without_staging state pure_token timer_refresh_context ops =
  Eta_signal_stabilization.rollback_transaction state;
  ops.timer_refresh.clear_active_timer_refresh timer_refresh_context;
  ignore
    (Eta_signal_stabilization.rollback_to_idle state pure_token
      : (_, Eta_signal_stabilization.idle) Eta_signal_stabilization.token);
  []

let run state capability ops =
  match Eta_signal_stabilization.begin_pure state with
  | Error `Reentrant_stabilization ->
      Pure_graph_error ([], ops.errors.reentrant_stabilization)
  | Ok pure_token ->
      let pure_context = Pure_context capability in
      let rollback_context = Rollback_context capability in
      let timer_refresh_context = Timer_refresh_context capability in
      let staging = ref None in
      let pending = ref [] in
      let observers = ref [] in
      let rollback_current () =
        match !staging with
        | None ->
            rollback_without_staging state pure_token timer_refresh_context
              ops
        | Some staging ->
            rollback state pure_token rollback_context
              timer_refresh_context ops !observers !pending staging
      in
      try
        ops.pure.advance_generation pure_context;
        let staging_value = ops.pure.begin_staging pure_context in
        staging := Some staging_value;
        let pending_value = ops.pure.drain_pending pure_context in
        pending := pending_value;
        ops.pure.release_pending_marks pure_context pending_value;
        let observer_plan = ops.pure.observer_plan pure_context in
        let observers_value = observer_plan.observers in
        observers := observers_value;
        let staging = staging_value in
        let pending = pending_value in
        let observers = observers_value in
        ops.pure.stage_pending pure_context pending;
        ops.pure.plan_staged_binds pure_context observers;
        let events = observer_plan.collect_events pure_context observers in
        let hooks = ops.pure.commit_staging pure_context staging in
        observer_plan.mark_events_pending pure_context events;
        ops.pure.update_necessity pure_context;
        ops.timer_refresh.clear_active_timer_refresh timer_refresh_context;
        let delivering_token =
          Eta_signal_stabilization.commit_to_delivering state pure_token
        in
        Pure_ok (hooks, events, delivering_token)
      with exn -> (
        let backtrace = Printexc.get_raw_backtrace () in
        let hooks = rollback_current () in
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
