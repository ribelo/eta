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

type 'capability pure_generation_plan = {
  pure_generation_advance : 'capability pure_context -> unit;
}

let pure_generation_plan ~advance_generation =
  { pure_generation_advance = advance_generation }

type ('capability, 'staging) pure_staging_plan = {
  pure_staging_begin : 'capability pure_context -> 'staging;
}

let pure_staging_plan ~begin_staging =
  { pure_staging_begin = begin_staging }

type ('capability, 'pending) pure_pending_plan = {
  pure_pending_drain : 'capability pure_context -> 'pending list;
  pure_pending_release_marks :
    'capability pure_context -> 'pending list -> unit;
  pure_pending_stage : 'capability pure_context -> 'pending list -> unit;
}

let pure_pending_plan ~drain_pending ~release_pending_marks
    ~stage_pending =
  {
    pure_pending_drain = drain_pending;
    pure_pending_release_marks = release_pending_marks;
    pure_pending_stage = stage_pending;
  }

type ('capability, 'observer, 'event) pure_observer_plan = {
  pure_observer_plan :
    'capability pure_context ->
    ('capability, 'observer, 'event) observer_plan;
  pure_observer_plan_staged_binds :
    'capability pure_context -> 'observer list -> unit;
}

let pure_observer_plan ~observer_plan ~plan_staged_binds =
  {
    pure_observer_plan = observer_plan;
    pure_observer_plan_staged_binds = plan_staged_binds;
  }

type ('capability, 'hook, 'staging) pure_commit_plan = {
  pure_commit_staging : 'capability pure_context -> 'staging -> 'hook list;
  pure_commit_update_necessity : 'capability pure_context -> unit;
}

let pure_commit_plan ~commit_staging ~update_necessity =
  {
    pure_commit_staging = commit_staging;
    pure_commit_update_necessity = update_necessity;
  }

type ('capability, 'pending, 'observer, 'event, 'hook, 'staging) pure = {
  generation_plan : 'capability pure_generation_plan;
  staging_plan : ('capability, 'staging) pure_staging_plan;
  pending_plan : ('capability, 'pending) pure_pending_plan;
  observer_plan : ('capability, 'observer, 'event) pure_observer_plan;
  commit_plan : ('capability, 'hook, 'staging) pure_commit_plan;
}

let pure_ops ~generation ~staging ~pending ~observers ~commit =
  {
    generation_plan = generation;
    staging_plan = staging;
    pending_plan = pending;
    observer_plan = observers;
    commit_plan = commit;
  }

type ('capability, 'hook, 'staging) rollback_staging_plan = {
  rollback_staging : 'capability rollback_context -> 'staging -> 'hook list;
}

let rollback_staging_plan ~rollback_staging =
  { rollback_staging }

type ('capability, 'observer) rollback_observer_plan = {
  mark_observers_failed_without_current :
    'capability rollback_context -> 'observer list -> unit;
}

let rollback_observer_plan ~mark_observers_failed_without_current =
  { mark_observers_failed_without_current }

type ('capability, 'pending) rollback_pending_plan = {
  requeue_pending : 'capability rollback_context -> 'pending list -> unit;
}

let rollback_pending_plan ~requeue_pending =
  { requeue_pending }

type ('capability, 'pending, 'observer, 'hook, 'staging) rollback = {
  rollback_staging_plan : ('capability, 'hook, 'staging) rollback_staging_plan;
  rollback_observer_plan : ('capability, 'observer) rollback_observer_plan;
  rollback_pending_plan : ('capability, 'pending) rollback_pending_plan;
}

let rollback_ops ~staging ~observers ~pending =
  {
    rollback_staging_plan = staging;
    rollback_observer_plan = observers;
    rollback_pending_plan = pending;
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

type 'error delivery_cleanup_plan = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}

let delivery_cleanup_plan ~run_pending_cleanup ~finish =
  { run_pending_cleanup; finish }

type ('event, 'error) delivery_event_plan = {
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
}

let delivery_event_plan ~run_events ~mark_complete =
  { run_events; mark_complete }

type ('event, 'error) delivery = {
  delivery_cleanup : 'error delivery_cleanup_plan;
  delivery_events : ('event, 'error) delivery_event_plan;
}

let delivery_ops ~cleanup ~events =
  { delivery_cleanup = cleanup; delivery_events = events }

let rollback state pure_token rollback_context timer_refresh_context ops
    observers pending staging =
  let hooks =
    ops.rollback.rollback_staging_plan.rollback_staging rollback_context
      staging
  in
  ops.rollback.rollback_observer_plan.mark_observers_failed_without_current
    rollback_context observers;
  ops.rollback.rollback_pending_plan.requeue_pending rollback_context
    pending;
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
        ops.pure.generation_plan.pure_generation_advance pure_context;
        let staging_value =
          ops.pure.staging_plan.pure_staging_begin pure_context
        in
        staging := Some staging_value;
        let pending_value =
          ops.pure.pending_plan.pure_pending_drain pure_context
        in
        pending := pending_value;
        ops.pure.pending_plan.pure_pending_release_marks pure_context
          pending_value;
        let observer_plan =
          ops.pure.observer_plan.pure_observer_plan pure_context
        in
        let observers_value = observer_plan.observers in
        observers := observers_value;
        let staging = staging_value in
        let pending = pending_value in
        let observers = observers_value in
        ops.pure.pending_plan.pure_pending_stage pure_context pending;
        ops.pure.observer_plan.pure_observer_plan_staged_binds pure_context
          observers;
        let events = observer_plan.collect_events pure_context observers in
        let hooks =
          ops.pure.commit_plan.pure_commit_staging pure_context staging
        in
        observer_plan.mark_events_pending pure_context events;
        ops.pure.commit_plan.pure_commit_update_necessity pure_context;
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
  ops.delivery_cleanup.run_pending_cleanup ()
  |> Eta.Effect.on_exit (fun _exit -> ops.delivery_cleanup.finish ())

let deliver ops events =
  let open Eta.Syntax in
  let delivery =
    let* () = ops.delivery_cleanup.run_pending_cleanup () in
    let* () = ops.delivery_events.run_events events in
    ops.delivery_events.mark_complete ()
  in
  Eta.Effect.on_exit (fun _exit -> finish_delivery ops) delivery
