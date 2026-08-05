type fault_slot =
  | Before_phase_install
  | After_phase_install
  | After_dynamic_discovery
  | After_frontier_freeze
  | After_discard_partition
  | After_prospective_validation
  | Before_plan_seal
  | Before_total_commit

type counters = {
  mutable enabled : bool;
  mutable phase_entries : int;
  mutable commits : int;
  mutable rollback_calls : int;
  mutable returns_to_idle : int;
}

type counter_snapshot = {
  phase_entries : int;
  commits : int;
  rollback_calls : int;
  returns_to_idle : int;
}

let create_counters () =
  {
    enabled = false;
    phase_entries = 0;
    commits = 0;
    rollback_calls = 0;
    returns_to_idle = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.phase_entries <- 0;
  counters.commits <- 0;
  counters.rollback_calls <- 0;
  counters.returns_to_idle <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    phase_entries = counters.phase_entries;
    commits = counters.commits;
    rollback_calls = counters.rollback_calls;
    returns_to_idle = counters.returns_to_idle;
  }

let succ value = if value = max_int then max_int else value + 1

let note_phase_entry counters =
  if counters.enabled then counters.phase_entries <- succ counters.phase_entries

let note_commit counters =
  if counters.enabled then counters.commits <- succ counters.commits

let note_rollback counters =
  if counters.enabled then counters.rollback_calls <- succ counters.rollback_calls

let note_return_to_idle counters =
  if counters.enabled then counters.returns_to_idle <- succ counters.returns_to_idle

type fault = { slot : fault_slot; exn : exn }
type fault_injector = { mutable fault : fault option }

let create_fault_injector () = { fault = None }
let set_fault injector fault = injector.fault <- fault

let check_fault injector slot =
  match injector.fault with
  | Some fault when fault.slot = slot -> raise fault.exn
  | Some _ | None -> ()

type phase =
  | Idle
  | Planning
  | Delivering

type ('owner, 'error) planning_session = {
  transaction :
    (Eta_signal_transaction.planning, 'error) Eta_signal_transaction.t;
  mutable sealed_transaction :
    (Eta_signal_transaction.sealed, 'error) Eta_signal_transaction.t option;
}

type ('owner, 'error) t = {
  counters : counters;
  commit_counters : Eta_signal_commit_plan.counters;
  faults : fault_injector;
  workspace : Eta_signal_transaction.workspace;
  mutable phase : phase;
  mutable session : ('owner, 'error) planning_session option;
}

let create () =
  {
    counters = create_counters ();
    commit_counters = Eta_signal_commit_plan.create_counters ();
    faults = create_fault_injector ();
    workspace = Eta_signal_transaction.create_workspace ();
    phase = Idle;
    session = None;
  }

let phase t = t.phase
let is_planning t = t.phase = Planning
let accepts_staging t =
  match t.session with
  | Some session -> session.sealed_transaction = None
  | None -> false
let counters t = t.counters
let commit_counters t = t.commit_counters
let fault_injector t = t.faults

let active_session name t =
  match (t.phase, t.session) with
  | Planning, Some session -> session
  | Idle, _ | Delivering, _ | Planning, None ->
      invalid_arg ("Eta_signal_atomic_pass." ^ name ^ ": no planning session")

let active_transaction t = (active_session "active_transaction" t).transaction

let seal_transaction t =
  let session = active_session "seal_transaction" t in
  match Eta_signal_transaction.seal session.transaction (fun () -> Ok ()) with
  | Error _ -> assert false
  | Ok sealed -> session.sealed_transaction <- Some sealed

let commit_transaction t =
  let session = active_session "commit_transaction" t in
  match session.sealed_transaction with
  | None -> invalid_arg "Eta_signal_atomic_pass.commit_transaction: unsealed"
  | Some transaction ->
      ignore
        (Eta_signal_transaction.commit transaction
          : (Eta_signal_transaction.committed, 'error)
            Eta_signal_transaction.t)

let rollback_transaction t =
  let session = active_session "rollback_transaction" t in
  match session.sealed_transaction with
  | None -> Eta_signal_transaction.rollback session.transaction
  | Some transaction -> Eta_signal_transaction.rollback transaction

let new_commit_plan t = Eta_signal_commit_plan.create t.commit_counters

type ('event, 'hook, 'error) result =
  | Planning_ok of 'hook list * 'event list
  | Planning_error of 'hook list * 'error
  | Planning_defect of 'hook list * exn * Printexc.raw_backtrace

let graph_error ~hooks error = Planning_error (hooks, error)

let result result ~planning_ok ~graph_error ~defect =
  match result with
  | Planning_ok (hooks, events) -> planning_ok ~hooks ~events
  | Planning_error (hooks, error) -> graph_error ~hooks error
  | Planning_defect (hooks, exn, backtrace) -> defect ~hooks exn backtrace

type ('capability, 'observer, 'event) observer_snapshot = {
  observers : 'observer list;
  collect_events : 'capability -> 'observer list -> 'event list;
  mark_events_pending : 'capability -> 'event list -> unit;
}

let observer_snapshot ~observers ~collect_events ~mark_events_pending =
  { observers; collect_events; mark_events_pending }

type ('capability, 'pending, 'observer, 'event, 'hook, 'error, 'staging) ops = {
  reentrant_error : 'error;
  classify_graph_error : exn -> 'error option;
  advance_generation : 'capability -> unit;
  begin_staging : 'capability -> 'staging;
  drain_pending : 'capability -> 'pending list;
  release_pending_marks : 'capability -> 'pending list -> unit;
  observer_snapshot : 'capability -> ('capability, 'observer, 'event) observer_snapshot;
  stage_pending : 'capability -> 'pending list -> unit;
  plan_dynamic : 'capability -> 'observer list -> unit;
  prepare_commit :
    'capability ->
    'staging ->
    ((Eta_signal_commit_plan.open_, 'hook) Eta_signal_commit_plan.t, 'error)
    Stdlib.result;
  update_necessity : 'capability -> unit;
  clear_timer_refresh : 'capability -> unit;
  rollback_staging : 'capability -> 'staging -> 'hook list;
  mark_observers_failed : 'capability -> 'observer list -> unit;
  requeue_pending : 'capability -> 'pending list -> unit;
  rollback_observers : 'capability -> 'observer list;
}

let ops ~reentrant_error ~classify_graph_error ~advance_generation ~begin_staging
    ~drain_pending ~release_pending_marks ~observer_snapshot ~stage_pending
    ~plan_dynamic ~prepare_commit ~update_necessity
    ~clear_timer_refresh ~rollback_staging ~mark_observers_failed
    ~requeue_pending ~rollback_observers =
  {
    reentrant_error;
    classify_graph_error;
    advance_generation;
    begin_staging;
    drain_pending;
    release_pending_marks;
    observer_snapshot;
    stage_pending;
    plan_dynamic;
    prepare_commit;
    update_necessity;
    clear_timer_refresh;
    rollback_staging;
    mark_observers_failed;
    requeue_pending;
    rollback_observers;
  }

let return_idle t =
  Option.iter
    (fun session ->
      Eta_signal_transaction.release_workspace t.workspace session.transaction)
    t.session;
  t.session <- None;
  t.phase <- Idle;
  note_return_to_idle t.counters

let rollback t capability ops staging observers pending =
  note_rollback t.counters;
  let hooks =
    match staging with
    | None ->
        rollback_transaction t;
        []
    | Some staging -> ops.rollback_staging capability staging
  in
  ops.mark_observers_failed capability observers;
  ops.requeue_pending capability pending;
  ops.clear_timer_refresh capability;
  return_idle t;
  hooks

let run t capability ops =
  match t.phase with
  | Planning | Delivering -> Planning_error ([], ops.reentrant_error)
  | Idle ->
      let local_ staging = stack_ (ref None) in
      let local_ pending = stack_ (ref []) in
      let local_ observers = stack_ (ref []) in
      (try
         check_fault t.faults Before_phase_install;
         let session =
           {
             transaction = Eta_signal_transaction.begin_planning t.workspace;
             sealed_transaction = None;
           }
         in
         t.session <- Some session;
         t.phase <- Planning;
         note_phase_entry t.counters;
         check_fault t.faults After_phase_install;
         ops.advance_generation capability;
         let staging_value = ops.begin_staging capability in
         staging := Some staging_value;
         let pending_value = ops.drain_pending capability in
         pending := pending_value;
         ops.release_pending_marks capability pending_value;
         observers := ops.rollback_observers capability;
         ops.stage_pending capability pending_value;
         let discovery_snapshot = ops.observer_snapshot capability in
         ops.plan_dynamic capability discovery_snapshot.observers;
         let observer_snapshot = ops.observer_snapshot capability in
         observers := observer_snapshot.observers;
         check_fault t.faults After_dynamic_discovery;
         let events =
           observer_snapshot.collect_events capability observer_snapshot.observers
         in
         check_fault t.faults After_frontier_freeze;
         check_fault t.faults After_discard_partition;
         match ops.prepare_commit capability staging_value with
         | Error error ->
             let hooks =
               rollback t capability ops !staging !observers !pending
             in
             Planning_error (hooks, error)
         | Ok open_plan ->
             check_fault t.faults After_prospective_validation;
             Eta_signal_commit_plan.add_write open_plan (fun () ->
                 commit_transaction t;
                 []);
             Eta_signal_commit_plan.add_write open_plan (fun () ->
                 observer_snapshot.mark_events_pending capability events;
                 []);
             Eta_signal_commit_plan.add_write open_plan (fun () ->
                 ops.update_necessity capability;
                 []);
             Eta_signal_commit_plan.add_write open_plan (fun () ->
                 ops.clear_timer_refresh capability;
                 []);
             check_fault t.faults Before_plan_seal;
             seal_transaction t;
             let plan = Eta_signal_commit_plan.seal open_plan in
             check_fault t.faults Before_total_commit;
             let hooks = Eta_signal_commit_plan.apply plan in
             note_commit t.counters;
             t.phase <- Delivering;
             Planning_ok (hooks, events)
       with exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         let hooks =
           if t.phase = Planning then
             rollback t capability ops !staging !observers !pending
           else []
         in
         match ops.classify_graph_error exn with
         | Some error -> Planning_error (hooks, error)
         | None -> Planning_defect (hooks, exn, backtrace))

let finish_delivering t =
  match t.phase with
  | Delivering -> return_idle t
  | Idle | Planning ->
      invalid_arg "Eta_signal_atomic_pass.finish_delivering: not delivering"

type 'error delivery_cleanup = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}

type ('event, 'error) delivery = {
  cleanup : 'error delivery_cleanup;
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
}

let delivery ~run_pending_cleanup ~run_events ~mark_complete ~finish =
  {
    cleanup = { run_pending_cleanup; finish };
    run_events;
    mark_complete;
  }

let finish_delivery delivery =
  delivery.cleanup.run_pending_cleanup ()
  |> Eta.Effect.on_exit (fun _ -> delivery.cleanup.finish ())

let deliver delivery events =
  let open Eta.Syntax in
  let run =
    let* () = delivery.cleanup.run_pending_cleanup () in
    let* () = delivery.run_events events in
    delivery.mark_complete ()
  in
  Eta.Effect.on_exit (fun _ -> finish_delivery delivery) run
