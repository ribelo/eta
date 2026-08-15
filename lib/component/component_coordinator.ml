(* Serialized context coordinator.

   One component context owns one serialized coordinator. The coordinator runs
   as the lexical body of a [Supervisor.scoped] nursery so that every
   generation child is started, interrupted, and fenced inside one lexical
   lifetime. Every context operation and every atomic state mutation is one
   message processed by the coordinator loop; a snapshot at revision [r]
   contains every visible mutation through [r] and no prefix of the
   transaction at [r]. *)

open Eta
module Coeffect = Component_coeffect
module Declaration = Component_declaration
module Desired = Component_desired_state
module Admission = Component_admission
module Graph = Component_provider_graph
module Diag = Component_diagnostics
module Ids = Component_ids

(* Coordinator functions build supervisor-scope programs; [>>=] sequences
   scope steps where [let*] is less readable in nested recursion. *)
let ( >>= ) x f = Supervisor.Scope.bind f x

(* ------------------------------------------------------------------ *)
(* Public operation error types                                        *)
(* ------------------------------------------------------------------ *)

type callback =
  | Configuration_equivalence
  | Interception_merge of string

type admission_error =
  | Context_not_running
  | Duplicate_entry_id of Component_entry_id.t
  | Entry_kind_changed of Component_entry_id.t
  | Duplicate_provider of {
      coeffect : string;
      realm : string;
      entries : Component_entry_id.t list;
    }
  | Dependency_cycle of Component_entry_id.t list
  | Callback_failed of {
      callback : callback;
      failure : Diag.Failure.t;
    }
  | Retry_not_available of Component_entry_id.t
  | Stale_source_revision of Component_source_revision.t
  | Stale_entry_incarnation of Component_entry_id.t
  | Stale_target_revision of Component_entry_id.t
  | Wrong_target_context of Component_entry_id.t
  | Component_identity_mismatch of Component_entry_id.t
  | Quarantined_instance of Component_entry_id.t

(* ------------------------------------------------------------------ *)
(* State                                                               *)
(* ------------------------------------------------------------------ *)

type phase_tag =
  | PInactive
  | PWaiting
  | PActivating
  | PActive
  | PSettling
  | PActivationFailed
  | PRecoveryFailed

type intercept_decl =
  | Intercept_decl :
      ('value, 'metadata) Coeffect.Interception.t * 'metadata
      -> intercept_decl

type merged_metadata =
  | Merged :
      ('value, 'metadata) Coeffect.Interception.t * 'metadata
      -> merged_metadata

exception Callback_exn of callback * exn

type desired_target = {
  dt_packed : Desired.packed_entry;
  dt_enabled : bool;
  dt_specs : Desired.Context_spec.t list;
  dt_realm_assignment : (int * int) list;
  dt_interception : intercept_decl list;
  dt_merged : (int * merged_metadata) list;
  dt_revision : Ids.Target_revision.t;
  dt_group_path : Component_entry_id.t list;
  dt_position : int;
}

type episode = {
  ep_id : Ids.Episode_id.t;
  ep_instance : Ids.Instance_id.t;
  ep_generation : Ids.Generation_id.t;
  ep_bindings : Coeffect.binding list;
  mutable ep_slots : Graph.slot list;
  mutable ep_lease_count : int;
  mutable ep_fenced : bool;
}

type report_resume = Diag.Fence.report_resume_pack

type snapshot_resume =
  | Snapshot_resume : ((Diag.snapshot, 'e) Exit.t -> unit) -> snapshot_resume

type await_resume = (Diag.change, Diag.await_error) Exit.t -> unit

type op_resume = (Diag.Fence.t, admission_error) Exit.t -> unit

type participant = {
  p_entry : Component_entry_id.t;
  p_instance : Ids.Instance_id.t;
  mutable p_roles : Diag.Fence.participant_role list;
  mutable p_generations : Ids.Generation_id.t list;
  mutable p_episodes : Ids.Episode_id.t list;
  mutable p_terminal_phase : Diag.phase option;
  mutable p_removed : bool;
  mutable p_failure : Diag.Failure.t option;
}

type fence = {
  f_id : Ids.Fence_id.t;
  f_kind : Diag.Fence.kind;
  f_admitted_at : int;
  mutable f_participants : participant list;
  mutable f_pending : int;
  mutable f_complete : bool;
  mutable f_superseded : bool;
  mutable f_degraded : bool;
  mutable f_rolled_back : bool;
  mutable f_restoration_failed : bool;
  mutable f_context_failed : bool;
  mutable f_report : Diag.Fence.report option;
  f_report_cell : Diag.Fence.report option ref;
  mutable f_waiters : report_resume list;
  mutable f_started_ms : int option;
}

type ('s, 'err) generation = {
  gen_id : Ids.Generation_id.t;
  gen_admission : bool Mutable_ref.t;
  gen_stop : Component_generation.stop_cell option ref;
  gen_child : ('s, 'err, unit) Supervisor.child;
  gen_started_by : fence;
  gen_declaration_uid : int;
  gen_realm_assignment : (int * int) list;
  mutable gen_tx : fence option;
  mutable gen_tx_inflight : bool;
  mutable gen_retired_by : fence option;
  mutable gen_waiting : fence list;
  mutable gen_episode : episode option;
  gen_leases : episode list;
  gen_view : (Coeffect.Key.t * episode) list;
  gen_slots : Declaration.interception_slot list;
  mutable gen_cancel_requested : bool;
  mutable gen_start_token_resolved : bool;
  mutable gen_stop_pending : bool;
  mutable gen_stop_forced : bool;
}

and ('s, 'err) instance = {
  i_entry : Component_entry_id.t;
  i_id : Ids.Instance_id.t;
  i_incarnation : int;
  mutable i_phase : phase_tag;
  mutable i_generation : ('s, 'err) generation option;
  mutable i_desired : desired_target option;
  mutable i_target_revision : Ids.Target_revision.t;
  mutable i_last_failure : Diag.Failure.t option;
  mutable i_failed_generation : Ids.Generation_id.t option;
  mutable i_quarantined : bool;
  (* Episode identities whose leases are retained through a failed cleanup;
     the provider stays guarded and the context can report [Blocked]. *)
  mutable i_guarded_leases : Ids.Episode_id.t list;
  mutable i_failed_revision : Ids.Target_revision.t option;
  mutable i_retire_order : int;
  mutable i_position : int;
}

(* One replacement transaction: retained declarations for rollback,
   transaction-local staged provider episodes, and the candidate start
   schedule in provider-first order. *)
and ('s, 'err) replace_tx = {
  r_fence : fence;
  r_candidates : ('s, 'err) instance list;
  r_saved : (('s, 'err) instance * desired_target) list;
  mutable r_to_start : ('s, 'err) instance list;
  mutable r_inflight : int;
  mutable r_staged : episode list;
  mutable r_dead : bool;
  mutable r_restoring : bool;
}

type msg =
  | Reconcile of Desired.t * op_resume
  | Retry of Component_entry_id.t * op_resume
  | Replace of Component_replacement.batch * op_resume
  | Shutdown of op_resume
  | Snapshot_req of snapshot_resume
  | Await_req of int * Ids.t * await_resume
  | Remove_waiter of int
  | Fence_await of Ids.Fence_id.t * Diag.Fence.report_resume_pack
  | Gen_payload of Component_generation.payload
  | Body_done

type ('s, 'err) state = {
  queue : (msg, unit) Queue.t;
  stamp : int;
  owner_domain : int;
  mutable revision : int;
  mutable desired_counter : int;
  mutable desired : Admission.flattened option;
  mutable instances : ('s, 'err) instance list;
  registry : (Graph.slot, episode) Hashtbl.t;
  episodes : (Ids.Episode_id.t, episode) Hashtbl.t;
  mutable fences : fence list;
  mutable waiters : (int * Ids.t * await_resume) list;
  mutable lifecycle : Diag.lifecycle;
  mutable integrity_failed : Diag.Failure.t option;
  mutable shutdown_fence : fence option;
  mutable admission_open : bool;
  mutable body_done : bool;
  mutable latest_source_revision : int64 option;
  mutable txs : ('s, 'err) replace_tx list;
  running : bool Mutable_ref.t;
  mutable counters : int array;
  mutable retiring_order : int;
  mutable telemetry : Component_telemetry.event list;
}

let ctr_generation = 0
let ctr_episode = 1
let ctr_instance = 2
let ctr_fence = 3
let ctr_target = 4
let ctr_incarnation = 5

let fresh state index =
  let value = state.counters.(index) + 1 in
  state.counters.(index) <- value;
  value

(* ------------------------------------------------------------------ *)
(* Small helpers                                                       *)
(* ------------------------------------------------------------------ *)

let emit state payload =
  ignore (Queue.try_offer_now state.queue (Gen_payload payload) : _ Queue.offer_result)

let find_instance state id =
  List.find_opt (fun instance -> Ids.Instance_id.equal instance.i_id id) state.instances

let find_instance_by_entry state entry =
  List.find_opt
    (fun instance -> Component_entry_id.equal instance.i_entry entry)
    state.instances

let find_tx state fence =
  List.find_opt (fun tx -> tx.r_fence == fence) state.txs

let participant_for fence instance =
  match
    List.find_opt
      (fun participant -> Ids.Instance_id.equal participant.p_instance instance.i_id)
      fence.f_participants
  with
  | Some participant -> participant
  | None ->
      let participant =
        {
          p_entry = instance.i_entry;
          p_instance = instance.i_id;
          p_roles = [];
          p_generations = [];
          p_episodes = [];
          p_terminal_phase = None;
          p_removed = false;
          p_failure = None;
        }
      in
      fence.f_participants <- fence.f_participants @ [ participant ];
      participant

let add_role participant role generation =
  if not (List.exists (fun existing -> existing = role) participant.p_roles) then
    participant.p_roles <- participant.p_roles @ [ role ];
  if
    not
      (List.exists
         (Ids.Generation_id.equal generation)
         participant.p_generations)
  then participant.p_generations <- participant.p_generations @ [ generation ]

let add_participant_episode participant episode_id =
  if
    not
      (List.exists (Ids.Episode_id.equal episode_id) participant.p_episodes)
  then participant.p_episodes <- participant.p_episodes @ [ episode_id ]

(* ------------------------------------------------------------------ *)
(* Snapshot construction and revision machinery                        *)
(* ------------------------------------------------------------------ *)

let public_phase state instance =
  match instance.i_phase, instance.i_generation, instance.i_failed_generation with
  | PInactive, _, _ -> Diag.Inactive
  | PWaiting, _, _ -> Diag.Waiting
  | PActivating, Some generation, _ -> Diag.Activating generation.gen_id
  | PActive, Some generation, _ -> Diag.Active generation.gen_id
  | PSettling, Some generation, _ -> Diag.Settling generation.gen_id
  | PSettling, None, Some failed -> Diag.Settling failed
  | PSettling, None, None -> Diag.Inactive
  | PActivationFailed, _, Some failed -> (
      match instance.i_last_failure with
      | Some failure -> Diag.Activation_failed (failed, failure)
      | None -> Diag.Inactive)
  | PActivationFailed, _, None -> Diag.Inactive
  | PRecoveryFailed, _, Some failed -> (
      match instance.i_last_failure with
      | Some failure -> Diag.Recovery_failed (failed, failure)
      | None -> Diag.Inactive)
  | PRecoveryFailed, _, None -> Diag.Inactive
  | (PActivating | PActive), None, _ -> Diag.Inactive

let instance_view instance =
  match instance.i_generation with
  | Some generation ->
      List.map
        (fun (key, episode) ->
          {
            Diag.requirement_name = Coeffect.Key.name key;
            requirement_provider = episode.ep_id;
          })
        generation.gen_view
  | None -> []

let instance_episode instance =
  match instance.i_generation with
  | Some generation -> (
      match generation.gen_episode with
      | Some episode -> Some episode.ep_id
      | None -> None)
  | None -> None

let snapshot_integrity state =
  match state.integrity_failed with
  | Some failure -> Diag.Failed failure
  | None ->
      let quarantined =
        List.filter_map
          (fun instance -> if instance.i_quarantined then Some instance.i_id else None)
          state.instances
      in
      if quarantined = [] then Diag.Sound else Diag.Degraded quarantined

let snapshot_progress state =
  let work_remains =
    List.exists
      (fun instance ->
        match instance.i_phase with
        | PActivating | PSettling -> true
        | _ -> false)
      state.instances
    || List.exists (fun fence -> not fence.f_complete) state.fences
  in
  if not work_remains then Diag.Quiescent
  else
    (* No legal lifecycle step can release an incomplete fence when a fenced
       episode is guarded by a lease retained through a failed cleanup. *)
    let blocked =
      Hashtbl.fold
        (fun _ episode blocked ->
          blocked
          || (episode.ep_fenced && episode.ep_lease_count > 0
            && List.exists
                 (fun instance ->
                   instance.i_quarantined
                   && List.exists
                        (fun guarded ->
                          Ids.Episode_id.equal guarded episode.ep_id)
                        instance.i_guarded_leases)
                 state.instances))
        state.episodes false
    in
    if blocked then Diag.Blocked else Diag.Reconciling

let build_snapshot state =
  let ordered =
    List.sort
      (fun a b ->
        match a.i_desired, b.i_desired with
        | Some _, None -> -1
        | None, Some _ -> 1
        | Some _, Some _ -> Int.compare a.i_position b.i_position
        | None, None -> Int.compare a.i_retire_order b.i_retire_order)
      state.instances
  in
  {
    Diag.Fence.snapshot_context_id = Ids.make state.stamp 0;
    snapshot_revision = Ids.make state.stamp state.revision;
    snapshot_accepted_desired_revision =
      (if state.desired_counter = 0 then None
       else Some (Ids.make state.stamp state.desired_counter));
    snapshot_lifecycle = state.lifecycle;
    snapshot_progress = snapshot_progress state;
    snapshot_integrity = snapshot_integrity state;
    snapshot_instances =
      List.map
        (fun instance ->
          {
            Diag.instance_entry_id = instance.i_entry;
            instance_instance_id = instance.i_id;
            instance_target_revision = Some instance.i_target_revision;
            instance_phase = public_phase state instance;
            instance_provider_episode = instance_episode instance;
            instance_committed_view = instance_view instance;
          })
        ordered;
    snapshot_fences =
      List.map
        (fun fence ->
          {
            Diag.Fence.observed_id = fence.f_id;
            observed_kind = fence.f_kind;
            observed_complete = fence.f_complete;
          })
        state.fences;
  }

(* One coordinator transaction changes every visible fact under one revision;
   [touch] advances the revision once and delivers the same later snapshot to
   every waiter on an earlier revision. *)
let touch state =
  state.revision <- state.revision + 1;
  match state.waiters with
  | [] -> ()
  | waiters ->
      let ready, pending =
        List.partition
          (fun (_, after, _) -> after.Ids.id < state.revision)
          waiters
      in
      state.waiters <- pending;
      if ready <> [] then (
        let snapshot = build_snapshot state in
        List.iter
          (fun (_, _, resume) -> resume (Exit.Ok (Diag.Changed snapshot)))
          ready)

(* Telemetry events are recorded as data during state mutation and flushed
   through the observability runtime after the serialized mutation
   completes. Recording is a plain list prepend: it cannot fail and cannot
   change lifecycle results, revisions, snapshots, or settlement reports. *)
let record state event =
  state.telemetry <- event :: state.telemetry

let flush_telemetry state =
  let open Supervisor.Scope in
  match state.telemetry with
  | [] -> pure ()
  | events ->
      state.telemetry <- [];
      let rec emit_all = function
        | [] -> pure ()
        | event :: rest ->
            let* () = lift (Component_telemetry.emit_event event) in
            emit_all rest
      in
      emit_all (List.rev events)

(* ------------------------------------------------------------------ *)
(* Fences                                                              *)
(* ------------------------------------------------------------------ *)

let new_fence state kind =
  let fence =
    {
      f_id = Ids.make state.stamp (fresh state ctr_fence);
      f_kind = kind;
      f_admitted_at = state.revision;
      f_participants = [];
      f_pending = 0;
      f_complete = false;
      f_superseded = false;
      f_degraded = false;
      f_rolled_back = false;
      f_restoration_failed = false;
      f_context_failed = false;
      f_report = None;
      f_report_cell = ref None;
      f_waiters = [];
      f_started_ms = None;
    }
  in
  state.fences <- state.fences @ [ fence ];
  fence

(* Telemetry durations start at operation admission. The stamp is set from
   the runtime monotonic clock at the admission point; internal fences carry
   no timestamp and emit no duration point. *)
let stamp_fence_start state fence =
  let open Supervisor.Scope in
  let* now = lift Effect.now_ms in
  fence.f_started_ms <- Some now;
  pure ()

let fence_outcome fence =
  if fence.f_context_failed then Diag.Fence.Context_failed
  else if fence.f_degraded then Diag.Fence.Degraded
  else if fence.f_restoration_failed then Diag.Fence.Restoration_failed
  else if fence.f_rolled_back then Diag.Fence.Rolled_back
  else if fence.f_superseded then Diag.Fence.Superseded
  else Diag.Fence.Quiescent

let check_owner owner =
  if (Domain.self () :> int) <> owner then
    invalid_arg "eta_component: component context accessed from a foreign domain"

let invariant_die message =
  Cause.die (Component_generation.Invariant message)

(* One settlement fence handle per accepted context operation. *)
let fence_handle state fence =
  let queue = state.queue in
  let running = state.running in
  let register (Diag.Fence.Report_resume_pack resume) =
    match !(fence.f_report_cell) with
    | Some report -> resume (Exit.Ok report)
    | None -> (
        if Mutable_ref.get running then
          match
            Queue.try_offer_now queue
              (Fence_await (fence.f_id, Diag.Fence.Report_resume_pack resume))
          with
          | `Sent -> ()
          | _ ->
              resume
                (Exit.Error
                   (invariant_die "eta_component: fence outlived its context"))
        else
          resume
            (Exit.Error
               (invariant_die "eta_component: fence outlived its context")))
  in
  {
    Diag.Fence.fence_id = fence.f_id;
    fence_report_cell = fence.f_report_cell;
    fence_register = register;
  }

(* A fence completes when all work it started settles; repeated waits return
   the same terminal report. Completion is one visible mutation: the revision
   advances and the final snapshot is built at the completing revision. *)
let maybe_complete_fence state fence =
  if (not fence.f_complete) && fence.f_pending = 0 then (
    fence.f_complete <- true;
    touch state;
    let snapshot = build_snapshot state in
    let report =
      {
        Diag.Fence.report_id = fence.f_id;
        report_kind = fence.f_kind;
        report_admitted_at = Ids.make state.stamp fence.f_admitted_at;
        report_completed_at = Ids.make state.stamp state.revision;
        report_outcome = fence_outcome fence;
        report_final_snapshot = snapshot;
        report_participants =
          List.map
            (fun participant ->
              {
                Diag.Fence.participant_entry = participant.p_entry;
                participant_instance = participant.p_instance;
                participant_roles = participant.p_roles;
                participant_generations = participant.p_generations;
                participant_episodes = participant.p_episodes;
                participant_terminal_phase = participant.p_terminal_phase;
                participant_removed = participant.p_removed;
                participant_failure = participant.p_failure;
              })
            fence.f_participants;
        report_failures =
          List.filter_map (fun participant -> participant.p_failure) fence.f_participants;
      }
    in
    fence.f_report <- Some report;
    fence.f_report_cell := Some report;
    let kind_label =
      match fence.f_kind with
      | Diag.Fence.Reconcile _ -> Component_telemetry.operation_reconcile
      | Diag.Fence.Retry _ -> Component_telemetry.operation_retry
      | Diag.Fence.Replace _ -> Component_telemetry.operation_replace
      | Diag.Fence.Shutdown -> Component_telemetry.operation_shutdown
    in
    let outcome_label =
      match fence_outcome fence with
      | Diag.Fence.Quiescent -> Component_telemetry.outcome_label `Quiescent
      | Diag.Fence.Superseded -> Component_telemetry.outcome_label `Superseded
      | Diag.Fence.Rolled_back -> Component_telemetry.outcome_label `Rolled_back
      | Diag.Fence.Degraded -> Component_telemetry.outcome_label `Degraded
      | Diag.Fence.Restoration_failed ->
          Component_telemetry.outcome_label `Restoration_failed
      | Diag.Fence.Context_failed ->
          Component_telemetry.outcome_label `Context_failed
    in
    record state
      (Component_telemetry.Fence_completed
         (kind_label, outcome_label, fence.f_started_ms));
    let waiters = fence.f_waiters in
    fence.f_waiters <- [];
    List.iter
      (fun (Diag.Fence.Report_resume_pack resume) -> resume (Exit.Ok report))
      waiters)

let complete_ready_fences state =
  List.iter (maybe_complete_fence state) state.fences

(* ------------------------------------------------------------------ *)
(* Provider registry, episodes, and leases                             *)
(* ------------------------------------------------------------------ *)

let register_episode state episode =
  Hashtbl.replace state.episodes episode.ep_id episode;
  List.iter
    (fun slot -> Hashtbl.replace state.registry slot episode)
    episode.ep_slots

let unregister_episode_slots state episode =
  List.iter
    (fun slot ->
      match Hashtbl.find_opt state.registry slot with
      | Some current when Ids.Episode_id.equal current.ep_id episode.ep_id ->
          Hashtbl.remove state.registry slot
      | _ -> ())
    episode.ep_slots

let resolve_slot state key_uid realm_uid =
  Hashtbl.find_opt state.registry (Graph.slot ~key_uid ~realm_uid)

let realm_for assignment key_uid =
  match List.assoc_opt key_uid assignment with
  | Some realm_uid -> realm_uid
  | None -> Desired.Realm.uid Desired.root_realm

(* Resolve all declared requirements of one activation as one operation
   against the current registry. *)
let resolve_view state assignment requirement_keys =
  let rec resolve acc = function
    | [] -> Some (List.rev acc)
    | (Coeffect.Key.K coeffect as key) :: rest -> (
        let key_uid = Coeffect.uid coeffect in
        match resolve_slot state key_uid (realm_for assignment key_uid) with
        | Some episode -> resolve ((key, episode) :: acc) rest
        | None -> None)
  in
  resolve [] requirement_keys

let requirement_keys_of packed =
  let (Desired.Packed_entry entry) = packed in
  let (Declaration.Component component) = entry.component in
  Declaration.requirement_keys component.requirements

let provision_keys_of packed =
  let (Desired.Packed_entry entry) = packed in
  let (Declaration.Component component) = entry.component in
  Declaration.provision_keys component.provisions

let declaration_uid_of packed =
  let (Desired.Packed_entry entry) = packed in
  Declaration.uid entry.component

(* One consumer episode owns one lease for each distinct provider episode in
   its committed view. *)
let take_leases view =
  let distinct =
    List.fold_left
      (fun acc (_, episode) ->
        if
          List.exists
            (fun existing -> Ids.Episode_id.equal existing.ep_id episode.ep_id)
            acc
        then acc
        else episode :: acc)
      [] view
  in
  List.iter
    (fun episode -> episode.ep_lease_count <- episode.ep_lease_count + 1)
    distinct;
  distinct

(* ------------------------------------------------------------------ *)
(* Lifecycle actions (run inside the coordinator scope)                *)
(* ------------------------------------------------------------------ *)

let resolve_stop state generation =
  match !(generation.gen_stop) with
  | Some (Component_generation.Stop_cell cell) ->
      Supervisor.Scope.lift (Effect.discard (Promise.resolve cell (Exit.Ok ())))
  | None ->
      Supervisor.Scope.lift
        (Effect.sync (fun () ->
             raise
               (Component_generation.Invariant
                  "eta_component: generation stop cell missing")))

(* Close admission, fence the provider episode, and arrange the stop signal:
   cancellation for an uncommitted (invalidated) activation or forced
   shutdown, otherwise the private normal-stop signal once the direct lease
   count reaches zero. *)
let retire_generation state supervisor fence instance generation ~forced =
  let open Supervisor.Scope in
  if generation.gen_stop_pending then (
    (* The generation is already retiring under another fence. This fence is
       a distinct operation that must still observe the settlement: register
       it as a waiter so its pending count does not reach zero before the
       generation and its cleanup finish. *)
    let already_waiting =
      List.exists (fun waiting -> waiting == fence) generation.gen_waiting
    in
    let retired_by_this =
      match generation.gen_retired_by with
      | Some retiring -> retiring == fence
      | None -> false
    in
    if (not already_waiting) && not retired_by_this then (
      generation.gen_waiting <- fence :: generation.gen_waiting;
      fence.f_pending <- fence.f_pending + 1;
      let participant = participant_for fence instance in
      add_role participant Diag.Fence.Waited generation.gen_id;
      match generation.gen_episode with
      | Some episode -> add_participant_episode participant episode.ep_id
      | None -> ());
    (* A forced shutdown escalates a pending graceful retirement. *)
    if forced && not generation.gen_stop_forced then (
      generation.gen_stop_forced <- true;
      generation.gen_cancel_requested <- true;
      request_cancel generation.gen_child)
    else pure ())
  else (
    Mutable_ref.set generation.gen_admission false;
    (match generation.gen_episode with
    | Some episode when not episode.ep_fenced ->
        episode.ep_fenced <- true;
        unregister_episode_slots state episode
    | _ -> ());
    generation.gen_retired_by <- Some fence;
    generation.gen_stop_pending <- true;
    generation.gen_stop_forced <- forced;
    fence.f_pending <- fence.f_pending + 1;
    let participant = participant_for fence instance in
    add_role participant Diag.Fence.Retired generation.gen_id;
    (match generation.gen_episode with
    | Some episode -> add_participant_episode participant episode.ep_id
    | None -> ());
    (* An unfinished start on a conflicting target supersedes the fence that
       started this generation. *)
    if (not generation.gen_start_token_resolved)
       && not generation.gen_started_by.f_complete
    then generation.gen_started_by.f_superseded <- true;
    (* A replacement superseded before publication closes every candidate and
       restoration attempt and restores no obsolete pre-mutation target. *)
    (match generation.gen_tx with
    | Some tx_fence when tx_fence != fence -> (
        match find_tx state tx_fence with
        | Some tx when not tx.r_dead ->
            tx.r_dead <- true;
            tx_fence.f_superseded <- true;
            tx.r_staged <- []
        | _ -> ())
    | _ -> ());
    let stop_now =
      match generation.gen_episode with
      | None -> true
      | Some episode -> episode.ep_lease_count = 0
    in
    if stop_now then
      match generation.gen_episode with
      | None ->
          generation.gen_cancel_requested <- true;
          request_cancel generation.gen_child
      | Some _ ->
          if forced then (
            generation.gen_cancel_requested <- true;
            request_cancel generation.gen_child)
          else resolve_stop state generation
      else pure ())

(* A fenced provider episode closes admission for every consumer whose
   committed view retains it; each such consumer settles with its unchanged
   provider view. *)
let rec invalidate_consumers state supervisor fence episode =
  let open Supervisor.Scope in
  let consumers =
    List.filter
      (fun instance ->
        match instance.i_generation with
        | Some generation ->
            (not generation.gen_stop_pending)
            && List.exists
                 (fun (_, leased) ->
                   Ids.Episode_id.equal leased.ep_id episode.ep_id)
                 generation.gen_view
        | None -> false)
      state.instances
  in
  let rec loop = function
    | [] -> pure ()
    | instance :: rest -> (
        match instance.i_generation with
        | Some generation ->
            instance.i_phase <- PSettling;
            retire_instance_generation state supervisor fence instance
              generation
            >>= fun () -> loop rest
        | None -> loop rest)
  in
  loop consumers

and retire_instance_generation state supervisor fence instance generation =
  let open Supervisor.Scope in
  (match generation.gen_episode with
  | Some episode when not episode.ep_fenced ->
      episode.ep_fenced <- true;
      unregister_episode_slots state episode;
      invalidate_consumers state supervisor fence episode
  | _ -> pure ())
  >>= fun () -> retire_generation state supervisor fence instance generation ~forced:false

(* Start one fresh serialized generation for an instance whose complete
   committed provider view is resolved. *)
let start_generation state supervisor fence instance desired ?(tx = None) view =
  let open Supervisor.Scope in
  let (Desired.Packed_entry entry) = desired.dt_packed in
  let (Declaration.Component component) = entry.component in
  let gen_id = Ids.make state.stamp (fresh state ctr_generation) in
  let admission = Mutable_ref.make true in
  let release_failed_flag = ref false in
  let renderer_failed_ref = ref None in
  let activation =
    Component_activation.make ~admission_open:admission
      ~instance_id:instance.i_id ~generation_id:gen_id ~release_failed_flag
      ~renderer_failed_ref
  in
  let interception_slots =
    List.filter_map
      (fun (Declaration.Declared_metadata (interception, _)) ->
        let key_uid =
          Coeffect.uid (Coeffect.Interception.coeffect interception)
        in
        match List.assoc_opt key_uid desired.dt_merged with
        | Some (Merged (merged_interception, merged_value)) -> (
            match
              Type.Id.provably_equal
                (Coeffect.Interception.metadata_id interception)
                (Coeffect.Interception.metadata_id merged_interception)
            with
            | Some Type.Equal ->
                Some
                  (Declaration.Slot
                     { interception; merged = Mutable_ref.make merged_value })
            | None ->
                raise
                  (Component_generation.Invariant
                     "eta_component: interception descriptor mismatch"))
        | None ->
            Some
              (Declaration.Slot
                 {
                   interception;
                   merged =
                     Mutable_ref.make
                       (Coeffect.Interception.empty interception);
                 }))
      (Declaration.requirement_metadata component.requirements)
  in
  let bindings = List.concat_map (fun (_, episode) -> episode.ep_bindings) view in
  let stop_slot = ref None in
  let program =
    Component_generation.program ~emit:(emit state)
      ~component:(Declaration.Component component) ~config:entry.config
      ~requirement_bindings:bindings ~interception_slots ~activation
      ~stop_slot ~instance_id:instance.i_id ~generation_id:gen_id ()
  in
  let* child = start supervisor (lift program) in
  let generation =
    {
      gen_id;
      gen_admission = admission;
      gen_stop = stop_slot;
      gen_child = child;
      gen_started_by = fence;
      gen_declaration_uid = Declaration.uid (Declaration.Component component);
      gen_realm_assignment = desired.dt_realm_assignment;
      gen_tx = tx;
      gen_tx_inflight = tx <> None;
      gen_retired_by = None;
      gen_waiting = [];
      gen_episode = None;
      gen_leases = take_leases view;
      gen_view = view;
      gen_slots = interception_slots;
      gen_cancel_requested = false;
      gen_start_token_resolved = false;
      gen_stop_pending = false;
      gen_stop_forced = false;
    }
  in
  instance.i_generation <- Some generation;
  instance.i_phase <- PActivating;
  fence.f_pending <- fence.f_pending + 1;
  let participant = participant_for fence instance in
  add_role participant Diag.Fence.Started gen_id;
  pure ()

(* Recompute the complete target provider view; start a fresh generation when
   every declared requirement resolves, and leave the consumer waiting while
   one declared requirement has no discoverable provider episode. *)
let advance_instance state supervisor fence instance =
  let open Supervisor.Scope in
  if instance.i_quarantined then pure ()
  else
    match instance.i_generation, instance.i_desired with
    | None, Some desired when desired.dt_enabled -> (
        (* An activation-failed instance does not restart on an unchanged
           desired state: only a fresh target revision or an explicit retry
           admits a new generation. *)
        match instance.i_phase with
        | PActivationFailed
          when Option.equal Ids.Target_revision.equal
                 instance.i_failed_revision (Some desired.dt_revision) ->
            pure ()
        | _ ->
            let requirement_keys = requirement_keys_of desired.dt_packed in
            let assignment = desired.dt_realm_assignment in
            let resolved =
              List.for_all
                (fun (Coeffect.Key.K coeffect) ->
                  let key_uid = Coeffect.uid coeffect in
                  resolve_slot state key_uid (realm_for assignment key_uid)
                  <> None)
                requirement_keys
            in
            if resolved then (
              match resolve_view state assignment requirement_keys with
              | Some view ->
                  start_generation state supervisor fence instance desired view
              | None ->
                  instance.i_phase <- PWaiting;
                  pure ())
            else (
              instance.i_phase <- PWaiting;
              pure ()))
    | None, _ ->
        instance.i_phase <- PInactive;
        pure ()
    | Some _, _ -> pure ()

(* ------------------------------------------------------------------ *)
(* Effective context computation                                       *)
(* ------------------------------------------------------------------ *)

let realm_assignment_of specs keys =
  List.map
    (fun (Coeffect.Key.K coeffect) ->
      let key_uid = Coeffect.uid coeffect in
      let realm = Admission.effective_realm specs key_uid in
      (key_uid, Desired.Realm.uid realm))
    keys
  |> List.sort (fun a b -> Int.compare (fst a) (fst b))

let interception_fingerprint_of specs =
  List.concat_map
    (fun spec ->
      List.filter_map
        (fun entry ->
          match entry with
          | Desired.Context_spec.Intercept (interception, metadata) ->
              Some (Intercept_decl (interception, metadata))
          | _ -> None)
        spec)
    specs

let fingerprint_equal left right =
  List.length left = List.length right
  && List.for_all2
       (fun (Intercept_decl (li, lm)) (Intercept_decl (ri, rm)) ->
         Int.equal
           (Coeffect.uid (Coeffect.Interception.coeffect li))
           (Coeffect.uid (Coeffect.Interception.coeffect ri))
         &&
         match
           Type.Id.provably_equal
             (Coeffect.Interception.metadata_id ri)
             (Coeffect.Interception.metadata_id li)
         with
         | Some equal -> lm == Coeffect.cast equal rm
         | None -> false)
       left right

(* Fold component-declared metadata, then outer-context metadata, then
   inner-context metadata, in that order. A requirement with no declared
   metadata uses the empty value and still receives context interception.

   The locally abstract [m] lets the per-layer [Type.Equal] equation unify
   each layer pack's existential metadata with the accumulator; equations
   between two existentials would be confined to the match branch. *)
let merge_one :
    type value metadata.
    (value, metadata) Coeffect.Interception.t ->
    metadata ->
    Declaration.declared_metadata list ->
    metadata =
 fun interception declared layers ->
  let merge = Coeffect.Interception.merge interception in
  let name = Coeffect.name (Coeffect.Interception.coeffect interception) in
  let rec fold acc = function
    | [] -> acc
    | Declaration.Declared_metadata (layer_interception, metadata) :: rest -> (
        match
          Type.Id.provably_equal
            (Coeffect.Interception.metadata_id layer_interception)
            (Coeffect.Interception.metadata_id interception)
        with
        | Some equal ->
            let next =
              try merge acc (Coeffect.cast equal metadata)
              with exn -> raise (Callback_exn (Interception_merge name, exn))
            in
            fold next rest
        | None ->
            raise
              (Component_generation.Invariant
                 "eta_component: interception layer descriptor mismatch"))
  in
  fold declared layers

let compute_merged specs requirements_metadata =
  List.map
    (fun (Declaration.Declared_metadata (interception, declared)) ->
      let key_uid =
        Coeffect.uid (Coeffect.Interception.coeffect interception)
      in
      let layers = Admission.interception_layers specs key_uid in
      (key_uid, Merged (interception, merge_one interception declared layers)))
    requirements_metadata

(* ------------------------------------------------------------------ *)
(* Reconciliation                                                      *)
(* ------------------------------------------------------------------ *)

let fail_resume resume error = resume (Exit.Error (Cause.fail error))

let callback_failure callback exn =
  Callback_failed
    {
      callback;
      failure = Diag.Failure.of_cause_without_renderer (Cause.die exn);
    }

type ('s, 'err) entry_plan = {
  pl_flat : Admission.flat_entry;
  pl_verdict : bool;
  pl_realm_assignment : (int * int) list;
  pl_fingerprint : intercept_decl list;
  pl_interception_changed : bool;
  pl_merged : (int * merged_metadata) list;
  pl_declaration_changed : bool;
  pl_enabled_changed : bool;
  pl_realm_changed : bool;
  pl_instance : ('s, 'err) instance option;
}

(* One replacement candidate's prospective desired target, fully computed -
   including every interception merge callback - before any lifecycle
   mutation. *)
type ('s, 'err) replace_precomputed = {
  rp_instance : ('s, 'err) instance;
  rp_packed : Component_desired_state.packed_entry;
  rp_specs : Component_desired_state.Context_spec.t list;
  rp_realm_assignment : (int * int) list;
  rp_fingerprint : intercept_decl list;
  rp_merged : (int * merged_metadata) list;
  rp_enabled : bool;
  rp_group_path : Component_entry_id.t list;
  rp_position : int;
}

let config_verdict instance new_packed =
  match instance with
  | None -> false
  | Some instance -> (
      match instance.i_desired with
      | None -> false
      | Some old_dt -> (
          let (Desired.Packed_entry old_entry) = old_dt.dt_packed in
          let (Desired.Packed_entry new_entry) = new_packed in
          let (Declaration.Component old_component) = old_entry.component in
          let (Declaration.Component new_component) = new_entry.component in
          if
            not
              (Int.equal
                 (Declaration.Family.uid old_component.family)
                 (Declaration.Family.uid new_component.family))
          then false
          else
            match
              Type.Id.provably_equal
                old_component.family.Declaration.Family.config_id
                new_component.family.Declaration.Family.config_id
            with
            | Some Type.Equal -> (
                try
                  new_component.config_equal old_entry.config new_entry.config
                with exn ->
                  raise (Callback_exn (Configuration_equivalence, exn)))
            | None -> false))

(* Compute one plan for every effectively flattened entry. Configuration
   equivalence and interception merge callbacks run here, before any
   lifecycle mutation; a callback exception rejects the admission with no
   mutation. *)
let plan_entry state flat =
  let (Desired.Packed_entry entry) = flat.Admission.fe_packed in
  let (Declaration.Component component) = entry.component in
  let instance = find_instance_by_entry state flat.Admission.fe_id in
  let keys =
    Declaration.requirement_keys component.requirements
    @ Declaration.provision_keys component.provisions
  in
  let realm_assignment = realm_assignment_of flat.fe_specs keys in
  let fingerprint = interception_fingerprint_of flat.fe_specs in
  let requirements_metadata =
    Declaration.requirement_metadata component.requirements
  in
  match instance with
  | Some instance when not instance.i_quarantined -> (
      match instance.i_desired with
      | Some old_dt ->
          let verdict =
            if
              Int.equal
                (declaration_uid_of old_dt.dt_packed)
                (declaration_uid_of flat.fe_packed)
            then config_verdict (Some instance) flat.fe_packed
            else false
          in
          let declaration_changed =
            not
              (Int.equal
                 (declaration_uid_of old_dt.dt_packed)
                 (declaration_uid_of flat.fe_packed))
          in
          let realm_changed = old_dt.dt_realm_assignment <> realm_assignment in
          let interception_changed =
            not (fingerprint_equal old_dt.dt_interception fingerprint)
          in
          let merged =
            if interception_changed then
              compute_merged flat.fe_specs requirements_metadata
            else old_dt.dt_merged
          in
          {
            pl_flat = flat;
            pl_verdict = verdict;
            pl_realm_assignment = realm_assignment;
            pl_fingerprint = fingerprint;
            pl_interception_changed = interception_changed;
            pl_merged = merged;
            pl_declaration_changed = declaration_changed;
            pl_enabled_changed = old_dt.dt_enabled <> flat.fe_enabled;
            pl_realm_changed = realm_changed;
            pl_instance = Some instance;
          }
      | None ->
          (* The instance is retiring under a previous removal; the returning
             identifier allocates a fresh target. *)
          {
            pl_flat = flat;
            pl_verdict = false;
            pl_realm_assignment = realm_assignment;
            pl_fingerprint = fingerprint;
            pl_interception_changed = true;
            pl_merged = compute_merged flat.fe_specs requirements_metadata;
            pl_declaration_changed = true;
            pl_enabled_changed = true;
            pl_realm_changed = true;
            pl_instance = Some instance;
          })
  | _ ->
      {
        pl_flat = flat;
        pl_verdict = false;
        pl_realm_assignment = realm_assignment;
        pl_fingerprint = fingerprint;
        pl_interception_changed = false;
        pl_merged = compute_merged flat.fe_specs requirements_metadata;
        pl_declaration_changed = false;
        pl_enabled_changed = false;
        pl_realm_changed = false;
        pl_instance = instance;
      }

let target_facts_changed plan =
  match plan.pl_instance with
  | None -> true
  | Some instance -> (
      match instance.i_desired with
      | None -> true
      | Some _ ->
          plan.pl_declaration_changed || plan.pl_enabled_changed
          || plan.pl_realm_changed
          || plan.pl_interception_changed
          || not plan.pl_verdict)

(* Install one accepted plan as the instance's latest desired target. *)
let install_plan state plan =
  let revision =
    if target_facts_changed plan then
      Ids.make state.stamp (fresh state ctr_target)
    else
      match plan.pl_instance with
      | Some instance -> instance.i_target_revision
      | None -> Ids.make state.stamp (fresh state ctr_target)
  in
  let desired =
    {
      dt_packed = plan.pl_flat.fe_packed;
      dt_enabled = plan.pl_flat.fe_enabled;
      dt_specs = plan.pl_flat.fe_specs;
      dt_realm_assignment = plan.pl_realm_assignment;
      dt_interception = plan.pl_fingerprint;
      dt_merged = plan.pl_merged;
      dt_revision = revision;
      dt_group_path = plan.pl_flat.fe_group_path;
      dt_position = plan.pl_flat.fe_position;
    }
  in
  match plan.pl_instance with
  | Some instance ->
      instance.i_desired <- Some desired;
      instance.i_target_revision <- revision;
      instance.i_position <- plan.pl_flat.fe_position;
      instance
  | None ->
      let instance =
        {
          i_entry = plan.pl_flat.fe_id;
          i_id = Ids.make state.stamp (fresh state ctr_instance);
          i_incarnation = fresh state ctr_incarnation;
          i_phase = PInactive;
          i_generation = None;
          i_desired = Some desired;
          i_target_revision = revision;
          i_last_failure = None;
          i_failed_generation = None;
          i_quarantined = false;
          i_guarded_leases = [];
          i_failed_revision = None;
          i_retire_order = 0;
          i_position = plan.pl_flat.fe_position;
        }
      in
      state.instances <- state.instances @ [ instance ];
      instance

let plan_changed_requires_retirement plan =
  plan.pl_declaration_changed
  || plan.pl_enabled_changed
  || not plan.pl_verdict

(* A provider episode whose effective realm slot moved with unchanged
   declaration and configuration transfers to the destination slot and keeps
   its episode identity. *)
let transfer_episode state instance generation plan =
  match generation.gen_episode with
  | None -> None
  | Some episode ->
      let new_slots =
        provision_keys_of plan.pl_flat.fe_packed
        |> List.map (fun (Coeffect.Key.K coeffect) ->
               let key_uid = Coeffect.uid coeffect in
               Graph.slot ~key_uid
                 ~realm_uid:(realm_for plan.pl_realm_assignment key_uid))
      in
      let old_slots = episode.ep_slots in
      let same =
        List.length old_slots = List.length new_slots
        && List.for_all2
             (fun a b -> Graph.Slot.equal a b)
             (List.sort Graph.Slot.compare old_slots)
             (List.sort Graph.Slot.compare new_slots)
      in
      if same then None else Some (episode, new_slots)

(* An interception change updates the runtime-owned metadata snapshots for
   later coeffect operations only; it does not reactivate the consumer. *)
let update_interception_slots generation plan =
  List.iter
    (fun (Declaration.Slot slot) ->
      let key_uid =
        Coeffect.uid (Coeffect.Interception.coeffect slot.interception)
      in
      match List.assoc_opt key_uid plan.pl_merged with
      | Some (Merged (merged_interception, merged_value)) -> (
          match
            Type.Id.provably_equal
              (Coeffect.Interception.metadata_id slot.interception)
              (Coeffect.Interception.metadata_id merged_interception)
          with
          | Some Type.Equal -> Mutable_ref.set slot.merged merged_value
          | None ->
              raise
                (Component_generation.Invariant
                   "eta_component: interception update descriptor mismatch"))
      | None -> ())
    generation.gen_slots

(* A generation remains valid while its target facts are unchanged and its
   complete committed provider view resolves to the same episodes. *)
let generation_valid state generation plan =
  plan.pl_flat.fe_enabled
  && plan.pl_verdict
  && not plan.pl_declaration_changed
  && Int.equal
       (declaration_uid_of plan.pl_flat.fe_packed)
       generation.gen_declaration_uid
  && List.for_all
       (fun (key, episode) ->
         (not episode.ep_fenced)
         &&
         let (Coeffect.Key.K coeffect) = key in
         let key_uid = Coeffect.uid coeffect in
         match
           resolve_slot state key_uid
             (realm_for plan.pl_realm_assignment key_uid)
         with
         | Some current -> Ids.Episode_id.equal current.ep_id episode.ep_id
         | None -> false)
       generation.gen_view

(* ------------------------------------------------------------------ *)
(* Reconcile driver                                                    *)
(* ------------------------------------------------------------------ *)

let cascade_fence state generation =
  match generation.gen_retired_by with
  | Some fence when not fence.f_complete -> fence
  | _ -> (
      match generation.gen_started_by with
      | fence when not fence.f_complete -> fence
      | _ -> (
          match state.shutdown_fence with
          | Some fence when not fence.f_complete -> fence
          | _ ->
              new_fence state
                (Diag.Fence.Reconcile
                   (Ids.make state.stamp (max 1 state.desired_counter)))))

(* Remove settled instances whose entry left desired state, then release the
   context authority of their stable identifier. *)
let remove_instance state instance =
  state.instances <-
    List.filter
      (fun existing -> not (Ids.Instance_id.equal existing.i_id instance.i_id))
      state.instances;
  List.iter
    (fun fence ->
      match
        List.find_opt
          (fun participant ->
            Ids.Instance_id.equal participant.p_instance instance.i_id)
          fence.f_participants
      with
      | Some participant -> participant.p_removed <- true
      | None -> ())
    state.fences

let plan_of plans instance =
  List.find_opt
    (fun plan -> Component_entry_id.equal plan.pl_flat.fe_id instance.i_entry)
    plans

(* Retirement fence computed to a fixed point before ordinary consumer
   reconciliation: every provider whose final target must retire is fenced,
   and every consumer retaining a retiring episode retires before new work
   starts. *)
let compute_invalid state plans =
  let invalid = Hashtbl.create 16 in
  let retiring = Hashtbl.create 16 in
  let direct_invalid instance generation =
    match plan_of plans instance with
    | Some plan ->
        (not (generation_valid state generation plan))
        || plan_changed_requires_retirement plan
    | None -> true
  in
  let rec sweep changed =
    let marked = ref false in
    List.iter
      (fun instance ->
        match instance.i_generation with
        | Some generation when not (Hashtbl.mem invalid instance.i_id) ->
            let consumer_of_retiring =
              List.exists
                (fun (_, episode) -> Hashtbl.mem retiring episode.ep_id)
                generation.gen_view
            in
            if direct_invalid instance generation || consumer_of_retiring then (
              Hashtbl.replace invalid instance.i_id ();
              (match generation.gen_episode with
              | Some episode -> Hashtbl.replace retiring episode.ep_id ()
              | None -> ());
              marked := true)
        | _ -> ())
      state.instances;
    if !marked then sweep changed
  in
  sweep ();
  invalid

let reconcile_retire_and_start state supervisor fence plans =
  let open Supervisor.Scope in
  (* Realm transfers commit first, atomically: every moving episode's source
     slots are unregistered before any destination is installed, so a swap of
     two providers between realms cannot see a destination occupied by the
     other still-unmoved episode. *)
  let* () =
    lift
      (Effect.sync (fun () ->
           let transfers =
             List.filter_map
               (fun plan ->
                 match plan.pl_instance with
                 | Some instance -> (
                     match instance.i_generation with
                     | Some generation
                       when plan.pl_realm_changed
                            && plan.pl_verdict
                            && not plan.pl_declaration_changed ->
                         transfer_episode state instance generation plan
                     | _ -> None)
                 | None -> None)
               plans
           in
           List.iter
             (fun (episode, _) -> unregister_episode_slots state episode)
             transfers;
           List.iter
             (fun (episode, new_slots) ->
               episode.ep_slots <- new_slots;
               List.iter
                 (fun slot ->
                   match Hashtbl.find_opt state.registry slot with
                   | Some existing
                     when not (Ids.Episode_id.equal existing.ep_id episode.ep_id) ->
                       (* The destination was validated free of enabled
                          providers; a remaining occupant must be a retiring
                          episode already fenced in this transaction. *)
                       if not existing.ep_fenced then
                         raise
                           (Component_generation.Invariant
                              "eta_component: realm transfer destination occupied")
                   | _ -> ())
                 new_slots;
               List.iter
                 (fun slot -> Hashtbl.replace state.registry slot episode)
                 new_slots)
             transfers))
  in
  let invalid = compute_invalid state plans in
  let rec retire_all = function
    | [] -> pure ()
    | instance :: rest -> (
        match instance.i_generation with
        | Some generation
          when Hashtbl.mem invalid instance.i_id
               && not generation.gen_stop_pending ->
            instance.i_phase <- PSettling;
            retire_instance_generation state supervisor fence instance
              generation
            >>= fun () -> retire_all rest
        | _ -> retire_all rest)
  in
  let* () = retire_all state.instances in
  (* Interception updates for retained valid generations. *)
  let* () =
    lift
      (Effect.sync (fun () ->
           List.iter
             (fun plan ->
               match plan.pl_instance with
               | Some instance -> (
                   match instance.i_generation with
                   | Some generation
                     when (not generation.gen_stop_pending)
                          && plan.pl_interception_changed ->
                       update_interception_slots generation plan
                   | _ -> ())
               | None -> ())
             plans))
  in
  (* Per-entry reconciliation: every instance coordinator reads the latest
     accepted snapshot. *)
  let rec advance_all = function
    | [] -> pure ()
    | instance :: rest -> (
        match instance.i_generation with
        | None -> (
            match instance.i_desired with
            | None ->
                remove_instance state instance;
                advance_all rest
            | Some _ ->
                let* () = advance_instance state supervisor fence instance in
                advance_all rest)
        | Some _ -> advance_all rest)
  in
  advance_all state.instances

(* One operation admission boundary: the operation resume is invoked exactly
   once, so wrapping it records the admitted or rejected telemetry event at
   the exact decision point without touching coordinator state. *)
let classify_resume state operation resume result =
  (match result with
  | Exit.Ok _ ->
      record state (Component_telemetry.Operation_admitted operation)
  | Exit.Error _ ->
      record state (Component_telemetry.Operation_rejected operation));
  resume result

let apply_reconcile state supervisor tree resume =
  let resume result =
    classify_resume state Component_telemetry.operation_reconcile resume result
  in
  let open Supervisor.Scope in
  if not state.admission_open then (
    fail_resume resume Context_not_running;
    pure false)
  else
    match Admission.validate_unique_ids tree with
    | Error id ->
        fail_resume resume (Duplicate_entry_id id);
        pure false
    | Ok () -> (
        let flattened = Admission.flatten tree in
        let authorities =
          List.map (fun instance -> (instance.i_entry, Admission.Entry_kind))
            state.instances
          (* A group retains its kind authority while any descendant
             instance is still known (including settling descendants), so a
             later reconcile cannot reuse the group identifier as a
             component entry until the last descendant has settled. *)
          @ List.concat_map
              (fun instance ->
                match instance.i_desired with
                | Some desired ->
                    List.map
                      (fun group_id -> (group_id, Admission.Group_kind))
                      desired.dt_group_path
                | None -> [])
              state.instances
          @
          match state.desired with
          | Some previous ->
              List.filter_map
                (fun (id, kind) ->
                  if
                    List.exists
                      (fun instance -> Component_entry_id.equal instance.i_entry id)
                      state.instances
                  then None
                  else Some (id, kind))
                previous.Admission.kinds
          | None -> []
        in
        match Admission.validate_kinds ~authorities flattened with
        | Error id ->
            fail_resume resume (Entry_kind_changed id);
            pure false
        | Ok () -> (
            match Admission.validate_providers flattened with
            | Error duplicate ->
                fail_resume resume
                  (Duplicate_provider
                     {
                       coeffect = duplicate.dp_coeffect;
                       realm = duplicate.dp_realm;
                       entries = duplicate.dp_entries;
                     });
                pure false
            | Ok () -> (
                match Admission.validate_cycles flattened with
                | Some cycle ->
                    fail_resume resume (Dependency_cycle cycle);
                    pure false
                | None -> (
                    match List.map (plan_entry state) flattened.entries with
                    | plans ->
                        let fence =
                          new_fence state
                            (Diag.Fence.Reconcile
                               (Ids.make state.stamp (state.desired_counter + 1)))
                        in
                        let* () = stamp_fence_start state fence in
                        state.desired_counter <- state.desired_counter + 1;
                        state.desired <- Some flattened;
                        let plans =
                          List.map
                            (fun plan ->
                              let instance = install_plan state plan in
                              { plan with pl_instance = Some instance })
                            plans
                        in
                        (* Entries that left desired state retire; their
                           instances are removed after settlement. *)
                        List.iter
                          (fun instance ->
                            match plan_of plans instance with
                            | Some _ -> ()
                            | None ->
                                if instance.i_desired <> None then (
                                  state.retiring_order <- state.retiring_order + 1;
                                  instance.i_retire_order <- state.retiring_order);
                                instance.i_desired <- None)
                          state.instances;
                        let* () =
                          reconcile_retire_and_start state supervisor fence plans
                        in
                        complete_ready_fences state;
                        resume (Exit.Ok (fence_handle state fence));
                        touch state;
                        pure false
                    | exception Callback_exn (callback, exn) ->
                        fail_resume resume (callback_failure callback exn);
                        pure false))))

(* ------------------------------------------------------------------ *)
(* Generation settlement                                               *)
(* ------------------------------------------------------------------ *)

let rec release_leases state supervisor leases =
  let open Supervisor.Scope in
  match leases with
  | [] -> pure ()
  | episode :: rest ->
      episode.ep_lease_count <- episode.ep_lease_count - 1;
      let* () =
        if episode.ep_lease_count = 0 && episode.ep_fenced then
          (* The guarded provider runs recovery only when its direct lease
             count reaches zero. *)
          match find_instance state episode.ep_instance with
          | Some provider -> (
              match provider.i_generation with
              | Some generation
                when generation.gen_stop_pending
                     && Ids.Generation_id.equal generation.gen_id
                          episode.ep_generation ->
                  if generation.gen_stop_forced then (
                    generation.gen_cancel_requested <- true;
                    request_cancel generation.gen_child)
                  else resolve_stop state generation
              | _ -> pure ())
          | None -> pure ()
        else pure ()
      in
      release_leases state supervisor rest

let flag_fences_degraded generation =
  let fences =
    (match generation.gen_retired_by with
    | Some fence -> [ fence ]
    | None -> [])
    @ generation.gen_waiting
    @ [ generation.gen_started_by ]
  in
  List.iter
    (fun fence -> if not fence.f_complete then fence.f_degraded <- true)
    fences

let record_participant_terminal fence instance phase failure =
  match
    List.find_opt
      (fun participant ->
        Ids.Instance_id.equal participant.p_instance instance.i_id)
      fence.f_participants
  with
  | Some participant ->
      participant.p_terminal_phase <- Some phase;
      participant.p_failure <- (match failure with
        | Some _ -> failure
        | None -> participant.p_failure)
  | None -> ()

let rec context_fail state supervisor cause =
  state.integrity_failed <-
    Some (Diag.Failure.of_cause_without_renderer cause);
  state.admission_open <- false;
  List.iter
    (fun fence ->
      if not fence.f_complete then fence.f_context_failed <- true)
    state.fences;
  initiate_shutdown state supervisor

(* Shutdown closes admission for new context operations, supersedes every
   unfinished target, and waits for every owned scope. Repeated shutdown
   requests return the first fence. *)
and initiate_shutdown state supervisor =
  let open Supervisor.Scope in
  let fence, fresh =
    match state.shutdown_fence with
    | Some fence -> (fence, false)
    | None ->
        let fence = new_fence state Diag.Fence.Shutdown in
        state.shutdown_fence <- Some fence;
        state.admission_open <- false;
        state.lifecycle <- Diag.Stopping;
        record state (Component_telemetry.Lifecycle "stopping");
        List.iter
          (fun other ->
            if other != fence && not other.f_complete then
              other.f_superseded <- true)
          state.fences;
        (fence, true)
  in
  if not fresh then pure fence
  else
    let* () = stamp_fence_start state fence in
    let rec retire_all = function
      | [] -> pure ()
      | instance :: rest -> (
          match instance.i_generation with
          | Some generation ->
              instance.i_phase <- PSettling;
              retire_generation state supervisor fence instance generation
                ~forced:true
              >>= fun () -> retire_all rest
          | None -> retire_all rest)
    in
    let* () = retire_all state.instances in
    complete_ready_fences state;
    pure fence

(* ------------------------------------------------------------------ *)
(* Replacement                                                         *)
(* ------------------------------------------------------------------ *)

let resolve_view_tx state tx assignment requirement_keys =
  let rec resolve acc = function
    | [] -> Some (List.rev acc)
    | (Coeffect.Key.K coeffect as key) :: rest -> (
        let key_uid = Coeffect.uid coeffect in
        let realm_uid = realm_for assignment key_uid in
        let slot = Graph.slot ~key_uid ~realm_uid in
        match resolve_slot state key_uid realm_uid with
        | Some episode -> resolve ((key, episode) :: acc) rest
        | None -> (
            (* A staged consumer can resolve a staged provider from the same
               replacement transaction. *)
            match
              List.find_opt
                (fun episode ->
                  List.exists (fun s -> Graph.Slot.equal s slot) episode.ep_slots)
                tx.r_staged
            with
            | Some episode -> resolve ((key, episode) :: acc) rest
            | None -> None))
  in
  resolve [] requirement_keys

(* Topological candidate order: a candidate that requires a coeffect another
   candidate provides activates after its provider. *)
let topo_candidates candidates =
  let provides instance =
    match instance.i_desired with
    | Some desired ->
        provision_keys_of desired.dt_packed
        |> List.map (fun (Coeffect.Key.K coeffect) ->
               Graph.slot ~key_uid:(Coeffect.uid coeffect)
                 ~realm_uid:
                   (realm_for desired.dt_realm_assignment
                      (Coeffect.uid coeffect)))
    | None -> []
  in
  let requires instance =
    match instance.i_desired with
    | Some desired ->
        requirement_keys_of desired.dt_packed
        |> List.map (fun (Coeffect.Key.K coeffect) ->
               Coeffect.uid coeffect)
    | None -> []
  in
  let rec order acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
        let ready, blocked =
          List.partition
            (fun instance ->
              let requirement_uids = requires instance in
              not
                (List.exists
                   (fun other ->
                     (not (Ids.Instance_id.equal other.i_id instance.i_id))
                     &&
                     let other_slots = provides other in
                     List.exists
                       (fun key_uid ->
                         List.exists
                           (fun slot -> slot.Graph.key_uid = key_uid)
                           other_slots)
                       requirement_uids)
                   remaining))
            remaining
        in
        (match ready with
        | [] -> List.rev acc @ remaining
        | _ -> order (List.rev_append ready acc) blocked)
  in
  order [] candidates

(* Candidate start schedule: sweep the provider-first order, start every
   candidate whose old generation settled and whose complete view resolves
   against the registry plus the transaction-local staged episodes, commit
   the declaration of a candidate whose provider is unavailable without an
   activation, and postpone the rest for the next settle or stage event. *)
let rec try_start_candidates state supervisor tx =
  let open Supervisor.Scope in
  let requirement_uids_of instance =
    match instance.i_desired with
    | Some desired ->
        requirement_keys_of desired.dt_packed
        |> List.map (fun (Coeffect.Key.K coeffect) -> Coeffect.uid coeffect)
    | None -> []
  in
  let tx_dep_pending instance remaining =
    let requirement_uids = requirement_uids_of instance in
    List.exists
      (fun other ->
        (not (Ids.Instance_id.equal other.i_id instance.i_id))
        && (match other.i_desired with
           | Some other_desired ->
               provision_keys_of other_desired.dt_packed
               |> List.exists (fun (Coeffect.Key.K coeffect) ->
                      List.mem (Coeffect.uid coeffect) requirement_uids)
           | None -> false))
      remaining
  in
  let rec sweep postponed = function
    | [] -> pure (List.rev postponed)
    | instance :: rest -> (
        if
          instance.i_quarantined
          ||
          (match instance.i_generation with
          | Some _ -> true
          | None -> false)
        then sweep (instance :: postponed) rest
        else
          match instance.i_desired with
          | None -> sweep postponed rest
          | Some desired -> (
              let requirement_keys = requirement_keys_of desired.dt_packed in
              let assignment = desired.dt_realm_assignment in
              match resolve_view_tx state tx assignment requirement_keys with
              | Some view ->
                  tx.r_inflight <- tx.r_inflight + 1;
                  let* () =
                    start_generation state supervisor tx.r_fence instance
                      desired view ~tx:(Some tx.r_fence)
                  in
                  sweep postponed rest
              | None ->
                  if tx_dep_pending instance (postponed @ rest) then
                    sweep (instance :: postponed) rest
                  else (
                    (* A required provider is unavailable: commit the new
                       declaration without an activation and leave the
                       consumer waiting. *)
                    instance.i_phase <- PWaiting;
                    sweep postponed rest)))
  in
  let* remaining = sweep [] tx.r_to_start in
  tx.r_to_start <- remaining;
  pure ()

(* Publish all staged provider episodes in one commit. *)
let maybe_publish_tx state supervisor tx =
  let open Supervisor.Scope in
  if tx.r_to_start = [] && tx.r_inflight = 0 && not tx.r_dead then (
    tx.r_dead <- true;
    let episodes = tx.r_staged in
    tx.r_staged <- [];
    List.iter (register_episode state) episodes;
    let rec advance_all = function
      | [] -> pure ()
      | instance :: rest -> (
          match instance.i_generation with
          | None -> (
              match instance.i_desired with
              | Some desired
                when desired.dt_enabled
                     && (not instance.i_quarantined)
                     && (instance.i_phase = PInactive || instance.i_phase = PWaiting) ->
                  let* () =
                    advance_instance state supervisor tx.r_fence instance
                  in
                  advance_all rest
              | _ -> advance_all rest)
          | Some _ -> advance_all rest)
    in
    advance_all state.instances)
  else pure ()

(* Candidate failure after drainage starts rollback: close every candidate
   attempt and restore the declarations and configurations captured
   immediately before lifecycle mutation. *)
let start_rollback state supervisor tx =
  let open Supervisor.Scope in
  tx.r_dead <- true;
  tx.r_fence.f_rolled_back <- true;
  (* Restore the saved pre-mutation targets: declaration and target revision
     move together so diagnostics never observe a candidate revision over a
     restored declaration. *)
  List.iter
    (fun (instance, saved) ->
      instance.i_desired <- Some saved;
      instance.i_target_revision <- saved.dt_revision)
    tx.r_saved;
  let rec close_staged = function
    | [] -> pure ()
    | instance :: rest -> (
        match instance.i_generation with
        | Some generation when not generation.gen_stop_pending ->
            instance.i_phase <- PSettling;
            retire_generation state supervisor tx.r_fence instance generation
              ~forced:false
            >>= fun () -> close_staged rest
        | _ -> close_staged rest)
  in
  let* () = close_staged tx.r_candidates in
  tx.r_staged <- [];
  tx.r_restoring <- true;
  tx.r_dead <- false;
  tx.r_to_start <- topo_candidates tx.r_candidates;
  List.iter
    (fun instance ->
      let participant = participant_for tx.r_fence instance in
      if
        not
          (List.exists
             (fun role -> role = Diag.Fence.Restored)
             participant.p_roles)
      then participant.p_roles <- participant.p_roles @ [ Diag.Fence.Restored ])
    tx.r_candidates;
  try_start_candidates state supervisor tx

(* A transaction-tracked generation settled: account for its in-flight slot,
   start rollback on candidate failure, fail restoration on restoration
   failure, and otherwise continue the schedule. *)
let tx_after_settle state supervisor tx generation summary =
  let open Supervisor.Scope in
  (if generation.gen_tx_inflight then (
     generation.gen_tx_inflight <- false;
     tx.r_inflight <- tx.r_inflight - 1));
  match summary with
  | Component_generation.Failed when not tx.r_dead ->
      if tx.r_restoring then (
        (* A failed restoration closes every staged restoration attempt and
           publishes no restored provision set. *)
        tx.r_dead <- true;
        tx.r_fence.f_restoration_failed <- true;
        let rec close_staged = function
          | [] -> pure ()
          | instance :: rest -> (
              match instance.i_generation with
              | Some generation when not generation.gen_stop_pending ->
                  instance.i_phase <- PSettling;
                  retire_generation state supervisor tx.r_fence instance
                    generation ~forced:false
                  >>= fun () -> close_staged rest
              | _ -> close_staged rest)
        in
        let* () = close_staged tx.r_candidates in
        tx.r_staged <- [];
        pure ())
      else start_rollback state supervisor tx
  | _ ->
      let* () = try_start_candidates state supervisor tx in
      maybe_publish_tx state supervisor tx

let process_settled state supervisor (settled : Component_generation.settled) =
  let open Supervisor.Scope in
  match find_instance state settled.settled_instance with
  | Some instance -> (
      match instance.i_generation with
      | Some generation
        when Ids.Generation_id.equal generation.gen_id
               settled.settled_generation ->
          instance.i_generation <- None;
          let cleanup_failed = settled.settled_cleanup_failed in
          let* () =
            if cleanup_failed then
              (* A failed cleanup retains its provider leases; the provider
                 remains guarded. *)
              pure ()
            else release_leases state supervisor generation.gen_leases
          in
          (* A cleanly settled episode with no retained leases is no longer
             needed for progress diagnosis or participant identity; the
             immutable fence records already copied its identity. *)
          (match generation.gen_episode with
          | Some episode
            when (not cleanup_failed) && episode.ep_lease_count = 0 ->
              Hashtbl.remove state.episodes episode.ep_id
          | _ -> ());
          if not generation.gen_start_token_resolved then (
            generation.gen_start_token_resolved <- true;
            generation.gen_started_by.f_pending <-
              generation.gen_started_by.f_pending - 1);
          (match generation.gen_retired_by with
          | Some fence -> fence.f_pending <- fence.f_pending - 1
          | None -> ());
          List.iter
            (fun fence -> fence.f_pending <- fence.f_pending - 1)
            generation.gen_waiting;
          let failure, invariant_action =
            match settled.settled_cause with
            | Some (Component_generation.Settled_cause (pp_error, exit)) -> (
                match exit with
                | Exit.Ok () -> (None, pure ())
                | Exit.Error cause ->
                    (* A runtime invariant violation fails the whole context;
                       otherwise the cause settles with the instance. *)
                    let rec has_invariant = function
                      | Cause.Die die ->
                          (match die.exn with
                          | Component_generation.Invariant _ -> true
                          | _ -> false)
                      | Cause.Sequential causes | Cause.Concurrent causes ->
                          List.exists has_invariant causes
                      | Cause.Suppressed { primary; _ } -> has_invariant primary
                      | _ -> false
                    in
                    if has_invariant cause then
                      ( None,
                        context_fail state supervisor cause
                        >>= fun _ -> pure () )
                    else
                      let failure =
                        match settled.settled_renderer_failed with
                        | Some renderer_exception ->
                            (* A release-error renderer raised during
                               finalizer capture: retain the authoritative
                               cause and expose [Renderer_failed]. *)
                            Diag.Failure.of_cause_renderer_failed cause
                              ~renderer_exception
                        | None -> Diag.Failure.of_cause pp_error cause
                      in
                      (Some failure, pure ()))
            | None -> (None, pure ())
          in
          let* () = invariant_action in
          record state
            (Component_telemetry.Activation_settled
               (Component_telemetry.summary_label
                  (match settled.settled_summary with
                  | Component_generation.Completed -> `Completed
                  | Component_generation.Failed -> `Failed
                  | Component_generation.Interrupted -> `Interrupted
                  | Component_generation.Not_started -> `Aborted)));
          let participant_fences =
            generation.gen_started_by
            :: (match generation.gen_retired_by with
               | Some fence -> [ fence ]
               | None -> [])
            @ generation.gen_waiting
          in
          (if cleanup_failed then (
             (* Cleanup failure quarantines the instance, degrades the
                context, and rejects every later generation for it. *)
             let failure_value = failure in
             instance.i_phase <- PRecoveryFailed;
             instance.i_quarantined <- true;
             instance.i_guarded_leases <-
               List.map (fun episode -> episode.ep_id) generation.gen_leases;
             record state Component_telemetry.Instance_quarantined;
             instance.i_last_failure <- failure_value;
             instance.i_failed_generation <- Some generation.gen_id;
             instance.i_failed_revision <- None;
             flag_fences_degraded generation;
             List.iter
               (fun fence ->
                 record_participant_terminal fence instance
                   (match instance.i_last_failure with
                   | Some retained ->
                       Diag.Recovery_failed (generation.gen_id, retained)
                   | None -> Diag.Inactive)
                   instance.i_last_failure)
               participant_fences)
           else
             match settled.settled_summary with
             | Component_generation.Failed ->
                 let failure_value = failure in
                 instance.i_phase <- PActivationFailed;
                 instance.i_last_failure <- failure_value;
                 instance.i_failed_generation <- Some generation.gen_id;
                 instance.i_failed_revision <-
                   (match instance.i_desired with
                   | Some desired -> Some desired.dt_revision
                   | None -> None);
                 List.iter
                   (fun fence ->
                     record_participant_terminal fence instance
                       (match instance.i_last_failure with
                       | Some retained ->
                           Diag.Activation_failed (generation.gen_id, retained)
                       | None -> Diag.Inactive)
                       instance.i_last_failure)
                   participant_fences
             | Component_generation.Interrupted
               when not generation.gen_cancel_requested -> (
                 (* An unexpected interruption remains part of the activation
                    cause. *)
                 match failure with
                 | Some _ ->
                     instance.i_phase <- PActivationFailed;
                     instance.i_last_failure <- failure;
                     instance.i_failed_generation <- Some generation.gen_id;
                     instance.i_failed_revision <-
                       (match instance.i_desired with
                       | Some desired -> Some desired.dt_revision
                       | None -> None)
                 | None -> instance.i_phase <- PInactive)
             | _ ->
                 (* Clean settlement: committed and normally stopped, aborted
                    staging, or requested lifecycle interruption. *)
                 instance.i_phase <- PInactive;
                 List.iter
                   (fun fence ->
                     record_participant_terminal fence instance Diag.Inactive
                       None)
                   participant_fences);
          let* () =
            if instance.i_quarantined then pure ()
            else
              match instance.i_desired with
              | None ->
                  remove_instance state instance;
                  pure ()
              | Some _ ->
                  (* A generation retired by shutdown does not restart: the
                     context is closing. A generation retired by an
                     invalidating reconcile re-advances against the latest
                     target; a generation that ended on its own re-advances
                     against the latest target as well. An instance owned by
                     a live replacement transaction never cascades: the
                     transaction schedule owns its next generation. *)
                  let in_live_tx =
                    List.exists
                      (fun tx ->
                        (not tx.r_dead)
                        && List.exists
                             (fun candidate ->
                               Ids.Instance_id.equal candidate.i_id
                                 instance.i_id)
                             tx.r_candidates)
                      state.txs
                  in
                  if
                    generation.gen_tx = None
                    && (not in_live_tx)
                    && state.lifecycle = Diag.Running
                    && (instance.i_phase = PInactive
                        || instance.i_phase = PWaiting)
                  then
                    let fence = cascade_fence state generation in
                    advance_instance state supervisor fence instance
                  else pure ()
          in
          (* Transaction-tracked instances drive the replacement schedule:
             old-generation settlement and candidate settlement both continue
             it. Membership, not the settled generation's own [gen_tx], is
             the dispatch key: the old generation was started before the
             transaction existed. *)
          let* () =
            let member_txs =
              List.filter
                (fun tx ->
                  (not tx.r_dead)
                  && List.exists
                       (fun candidate ->
                         Ids.Instance_id.equal candidate.i_id instance.i_id)
                       tx.r_candidates)
                state.txs
            in
            let rec drive = function
              | [] -> pure ()
              | tx :: rest ->
                  let* () =
                    tx_after_settle state supervisor tx generation
                      settled.settled_summary
                  in
                  drive rest
            in
            drive member_txs
          in
          pure ()
      | _ -> pure ())
  | None -> pure ()

let process_staged state supervisor (staged : Component_generation.staged) =
  let open Supervisor.Scope in
  let commit_cell = staged.staged_commit in
  let resolve decision =
    let (Component_generation.Commit_cell cell) = commit_cell in
    lift (Effect.discard (Promise.resolve cell (Exit.Ok decision)))
  in
  let provision_slots_of instance generation =
    match instance.i_desired with
    | Some desired ->
        provision_keys_of desired.dt_packed
        |> List.map (fun (Coeffect.Key.K coeffect) ->
               let key_uid = Coeffect.uid coeffect in
               Graph.slot ~key_uid
                 ~realm_uid:(realm_for generation.gen_realm_assignment key_uid))
    | None -> []
  in
  match find_instance state staged.staged_instance with
  | Some instance -> (
      match instance.i_generation with
      | Some generation
        when Ids.Generation_id.equal generation.gen_id
               staged.staged_generation
             && not generation.gen_stop_pending ->
          let slots = provision_slots_of instance generation in
          let episode =
            {
              ep_id = Ids.make state.stamp (fresh state ctr_episode);
              ep_instance = instance.i_id;
              ep_generation = generation.gen_id;
              ep_bindings = staged.staged_bindings;
              ep_slots = slots;
              ep_lease_count = 0;
              ep_fenced = false;
            }
          in
          let resolve_start_token () =
            if not generation.gen_start_token_resolved then (
              generation.gen_start_token_resolved <- true;
              generation.gen_started_by.f_pending <-
                generation.gen_started_by.f_pending - 1)
          in
          (match generation.gen_tx with
          | Some tx_fence -> (
              match find_tx state tx_fence with
              | Some tx when not tx.r_dead ->
                  (* Transaction-local staging: a staged provider episode is
                     undiscoverable to other component instances until the
                     batch commit; a staged consumer can resolve it. *)
                  tx.r_staged <- tx.r_staged @ [ episode ];
                  generation.gen_episode <- Some episode;
                  instance.i_phase <- PActive;
                  let participant =
                    participant_for generation.gen_started_by instance
                  in
                  add_participant_episode participant episode.ep_id;
                  let* () = resolve Component_generation.Commit in
                  if generation.gen_tx_inflight then (
                    generation.gen_tx_inflight <- false;
                    tx.r_inflight <- tx.r_inflight - 1);
                  resolve_start_token ();
                  let* () = try_start_candidates state supervisor tx in
                  maybe_publish_tx state supervisor tx
              | _ ->
                  (* The transaction is dead: close the attempt. *)
                  resolve Component_generation.Abort)
          | None ->
              let occupied =
                List.find_opt
                  (fun slot ->
                    match Hashtbl.find_opt state.registry slot with
                    | Some existing ->
                        not (Ids.Episode_id.equal existing.ep_id episode.ep_id)
                    | None -> false)
                  slots
              in
              let* () =
                match occupied with
                | Some _ ->
                    lift
                      (Effect.sync (fun () ->
                           raise
                             (Component_generation.Invariant
                                "eta_component: duplicate provider episode at commit")))
                | None -> pure ()
              in
              (* The complete declared provision set publishes at one commit
                 point. *)
              register_episode state episode;
              generation.gen_episode <- Some episode;
              instance.i_phase <- PActive;
              let participant =
                participant_for generation.gen_started_by instance
              in
              add_participant_episode participant episode.ep_id;
              let* () = resolve Component_generation.Commit in
              (* Waiting consumers whose declared keys in the affected realm
                 were just published recompute their complete target view. *)
              let* () =
                let affected =
                  List.filter
                    (fun other ->
                      (not (Ids.Instance_id.equal other.i_id instance.i_id))
                      && other.i_phase = PWaiting
                      && not other.i_quarantined
                      &&
                      match other.i_desired with
                      | Some desired ->
                          let keys = requirement_keys_of desired.dt_packed in
                          List.exists
                            (fun (Coeffect.Key.K coeffect) ->
                              let key_uid = Coeffect.uid coeffect in
                              List.exists
                                (fun slot ->
                                  Graph.Slot.equal slot
                                    (Graph.slot ~key_uid
                                       ~realm_uid:
                                         (realm_for
                                            desired.dt_realm_assignment key_uid)))
                                slots)
                            keys
                      | None -> false)
                    state.instances
                in
                let rec advance_all = function
                  | [] -> pure ()
                  | other :: rest ->
                      let* () =
                        advance_instance state supervisor
                          generation.gen_started_by other
                      in
                      advance_all rest
                in
                advance_all affected
              in
              (* The staging generation committed: its start token resolves
                 after cascade starts so one operation covers its cascades. *)
              resolve_start_token ();
              pure ())
      | _ ->
          (* A stale generation cannot commit its staged provisions. *)
          resolve Component_generation.Abort)
  | None -> resolve Component_generation.Abort



let apply_replace state supervisor (batch : Component_replacement.batch) resume =
  let resume result =
    classify_resume state Component_telemetry.operation_replace resume result
  in
  let open Supervisor.Scope in
  if not state.admission_open then (
    fail_resume resume Context_not_running;
    pure false)
  else
    match state.latest_source_revision with
    | Some latest
      when not (Int64.compare batch.Component_replacement.source_revision latest > 0) ->
        fail_resume resume
          (Stale_source_revision batch.source_revision);
        pure false
    | _ -> (
        let checks =
          List.map
            (fun
              (Component_replacement.Candidate { target; _ } as packed_candidate)
            ->
              let entry = target.Component_replacement.target_entry.id in
              if
                Ids.stamp target.expected_target <> state.stamp
                || Ids.stamp target.expected_instance <> state.stamp
              then Error (Wrong_target_context entry)
              else
                match find_instance_by_entry state entry with
                | None -> Error (Stale_entry_incarnation entry)
                | Some instance ->
                    if
                      not
                        (Ids.Instance_id.equal instance.i_id
                           target.expected_instance)
                    then Error (Stale_entry_incarnation entry)
                    else if
                      not
                        (Ids.Target_revision.equal instance.i_target_revision
                           target.expected_target)
                    then Error (Stale_target_revision entry)
                    else if instance.i_quarantined then
                      Error (Quarantined_instance entry)
                    else Ok (instance, packed_candidate))
            batch.candidates
        in
        match List.find_opt (function Error _ -> true | Ok _ -> false) checks with
        | Some (Error error) ->
            fail_resume resume error;
            pure false
        | _ ->
            let checked =
              List.map (function
                | Ok value -> value
                | Error _ -> assert false)
                checks
            in
            (* Pre-mutation identity boundary: the candidate component's
               family and configuration identity must match the identity the
               target was built against. The target revision staleness check
               above covers drift since the observed snapshot; here we check
               the candidate against the instance's retained declaration.
               Replacement may change the configuration value freely, so no
               value-equivalence callback runs here. *)
            let config_check
                (instance, Component_replacement.Candidate { target; component }) =
              let (Declaration.Component replacement) = component in
              match instance.i_desired with
              | Some old_dt -> (
                  let (Desired.Packed_entry old_entry) = old_dt.dt_packed in
                  let (Declaration.Component old_component) = old_entry.component in
                  if
                    Int.equal
                      (Declaration.Family.uid old_component.family)
                      (Declaration.Family.uid replacement.family)
                    && Option.is_some
                         (Type.Id.provably_equal
                            old_component.family.Declaration.Family.config_id
                            replacement.family.Declaration.Family.config_id)
                  then None
                  else
                    Some
                      (Component_identity_mismatch target.target_entry.id))
              | None ->
                  Some
                    (Component_identity_mismatch target.target_entry.id)
            in
            (match
               List.find_map config_check checked
             with
            | Some error ->
                fail_resume resume error;
                pure false
            | None -> (
                (* Pre-mutation boundary: compute every candidate target,
                   including all interception merge callbacks, and validate
                   the prospective provider graph. A raising merge callback
                   or an invalid prospective graph rejects the admission
                   before any fence, revision, or instance state changes. *)
                let precompute
                    ( instance,
                      Component_replacement.Candidate { target; component } ) =
                  let (Declaration.Component replacement) = component in
                  match instance.i_desired with
                  | Some old_dt ->
                      let keys =
                        Declaration.requirement_keys replacement.requirements
                        @ Declaration.provision_keys replacement.provisions
                      in
                      let parent_specs =
                        match List.rev old_dt.dt_specs with
                        | [] -> []
                        | _ :: parent -> List.rev parent
                      in
                      let specs = parent_specs @ [ target.target_entry.context ] in
                      {
                        rp_instance = instance;
                        rp_packed = Desired.Packed_entry target.target_entry;
                        rp_specs = specs;
                        rp_realm_assignment = realm_assignment_of specs keys;
                        rp_fingerprint = interception_fingerprint_of specs;
                        rp_merged =
                          compute_merged specs
                            (Declaration.requirement_metadata
                               replacement.requirements);
                        rp_enabled = old_dt.dt_enabled;
                        rp_group_path = old_dt.dt_group_path;
                        rp_position = old_dt.dt_position;
                      }
                  | None ->
                      (* config_check already rejected this candidate. *)
                      assert false
                in
                let precomputed = List.map precompute checked in
                (* The prospective provider graph: candidate declarations
                   replace their targets; every other instance keeps its
                   current declaration. *)
                let prospective =
                  List.filter_map
                    (fun instance ->
                      match
                        List.find_opt
                          (fun rp -> rp.rp_instance == instance)
                          precomputed
                      with
                      | Some rp ->
                          Some
                            {
                              Admission.fe_id = instance.i_entry;
                              fe_packed = rp.rp_packed;
                              fe_enabled = rp.rp_enabled;
                              fe_specs = rp.rp_specs;
                              fe_group_path = rp.rp_group_path;
                              fe_position = rp.rp_position;
                            }
                      | None -> (
                          match instance.i_desired with
                          | Some dt ->
                              Some
                                {
                                  Admission.fe_id = instance.i_entry;
                                  fe_packed = dt.dt_packed;
                                  fe_enabled = dt.dt_enabled;
                                  fe_specs = dt.dt_specs;
                                  fe_group_path = dt.dt_group_path;
                                  fe_position = dt.dt_position;
                                }
                          | None -> None))
                    state.instances
                in
                let prospective_flattened =
                  { Admission.entries = prospective; groups = []; kinds = [] }
                in
                (match Admission.validate_providers prospective_flattened with
                | Error duplicate ->
                    fail_resume resume
                      (Duplicate_provider
                         {
                           coeffect = duplicate.Admission.dp_coeffect;
                           realm = duplicate.dp_realm;
                           entries = duplicate.dp_entries;
                         });
                    pure false
                | Ok () -> (
                    match Admission.validate_cycles prospective_flattened with
                    | Some cycle ->
                        fail_resume resume (Dependency_cycle cycle);
                        pure false
                    | None ->
                        let fence =
                          new_fence state
                            (Diag.Fence.Replace batch.source_revision)
                        in
                        let* () = stamp_fence_start state fence in
                        state.latest_source_revision <-
                          Some batch.source_revision;
                        let candidates =
                          List.map (fun rp -> rp.rp_instance) precomputed
                        in
                        let saved =
                          List.filter_map
                            (fun instance ->
                              match instance.i_desired with
                              | Some desired -> Some (instance, desired)
                              | None -> None)
                            candidates
                        in
                        (* Install the precomputed candidate targets. *)
                        List.iter
                          (fun rp ->
                            let revision =
                              Ids.make state.stamp (fresh state ctr_target)
                            in
                            rp.rp_instance.i_desired <-
                              Some
                                {
                                  dt_packed = rp.rp_packed;
                                  dt_enabled = rp.rp_enabled;
                                  dt_specs = rp.rp_specs;
                                  dt_realm_assignment = rp.rp_realm_assignment;
                                  dt_interception = rp.rp_fingerprint;
                                  dt_merged = rp.rp_merged;
                                  dt_revision = revision;
                                  dt_group_path = rp.rp_group_path;
                                  dt_position = rp.rp_position;
                                };
                            rp.rp_instance.i_target_revision <- revision)
                          precomputed;
                        let tx =
                          {
                            r_fence = fence;
                            r_candidates = candidates;
                            r_saved = saved;
                            r_to_start = [];
                            r_inflight = 0;
                            r_staged = [];
                            r_dead = false;
                            r_restoring = false;
                          }
                        in
                        state.txs <- tx :: state.txs;
                        (* Fence every provider in the affected runtime closure and
                           settle old generations in consumer-first order. *)
                        let rec retire_all = function
                          | [] -> pure ()
                          | instance :: rest -> (
                              match instance.i_generation with
                              | Some generation when not generation.gen_stop_pending ->
                                  instance.i_phase <- PSettling;
                                  retire_instance_generation state supervisor fence
                                    instance generation
                                  >>= fun () -> retire_all rest
                              | _ -> retire_all rest)
                        in
                        let* () = retire_all candidates in
                        tx.r_to_start <- topo_candidates candidates;
                        let* () = try_start_candidates state supervisor tx in
                        complete_ready_fences state;
                        resume (Exit.Ok (fence_handle state fence));
                        touch state;
                        pure false)))
            | exception Callback_exn (callback, exn) ->
                (* A raising interception merge callback escapes from
                   precompute, before any fence or state mutation. *)
                fail_resume resume (callback_failure callback exn);
                pure false))

(* ------------------------------------------------------------------ *)
(* Retry                                                               *)
(* ------------------------------------------------------------------ *)

let apply_retry state supervisor entry resume =
  let resume result =
    classify_resume state Component_telemetry.operation_retry resume result
  in
  let open Supervisor.Scope in
  if not state.admission_open then (
    fail_resume resume Context_not_running;
    pure false)
  else
    match find_instance_by_entry state entry with
    | Some instance when instance.i_quarantined ->
        fail_resume resume (Quarantined_instance entry);
        pure false
    | Some instance
      when instance.i_phase = PActivationFailed
           && instance.i_generation = None -> (
        match instance.i_desired with
        | Some _ ->
            (* A retry selects a fresh retry generation for one entry. *)
            let fence = new_fence state (Diag.Fence.Retry entry) in
            let* () = stamp_fence_start state fence in
            instance.i_phase <- PWaiting;
            let* () = advance_instance state supervisor fence instance in
            complete_ready_fences state;
            resume (Exit.Ok (fence_handle state fence));
            touch state;
            pure false
        | None ->
            fail_resume resume (Retry_not_available entry);
            pure false)
    | _ ->
        fail_resume resume (Retry_not_available entry);
        pure false

(* ------------------------------------------------------------------ *)
(* Shutdown operation                                                  *)
(* ------------------------------------------------------------------ *)

let apply_shutdown state supervisor resume =
  let resume result =
    classify_resume state Component_telemetry.operation_shutdown resume result
  in
  let open Supervisor.Scope in
  let* fence = initiate_shutdown state supervisor in
  complete_ready_fences state;
  resume (Exit.Ok (fence_handle state fence));
  touch state;
  pure false

(* ------------------------------------------------------------------ *)
(* Message dispatcher and coordinator loop                             *)
(* ------------------------------------------------------------------ *)

let should_stop state =
  state.body_done
  &&
  match state.shutdown_fence with
  | Some fence ->
      fence.f_complete
      && List.for_all
           (fun instance -> instance.i_generation = None)
           state.instances
  | None -> false

let process :
    type s err.
    (s, err) state ->
    (s, err) Supervisor.t ->
    msg ->
    (s, bool, err) Supervisor.Scope.t =
 fun state supervisor msg ->
  let open Supervisor.Scope in
  match msg with
  | Reconcile (tree, resume) -> apply_reconcile state supervisor tree resume
  | Retry (entry, resume) -> apply_retry state supervisor entry resume
  | Replace (batch, resume) -> apply_replace state supervisor batch resume
  | Shutdown resume -> apply_shutdown state supervisor resume
  | Snapshot_req (Snapshot_resume resume) ->
      resume (Exit.Ok (build_snapshot state));
      pure false
  | Await_req (waiter_id, after, resume) ->
      if after.Ids.stamp <> state.stamp then
        resume (Exit.Error (Cause.fail Diag.Wrong_context))
      else if after.Ids.id > state.revision then
        resume (Exit.Error (Cause.fail Diag.Invalid_revision))
      else if state.lifecycle = Diag.Stopped then
        resume (Exit.Ok (Diag.Closed (build_snapshot state)))
      else if after.Ids.id < state.revision then
        resume (Exit.Ok (Diag.Changed (build_snapshot state)))
      else state.waiters <- (waiter_id, after, resume) :: state.waiters;
      pure false
  | Remove_waiter waiter_id ->
      state.waiters <-
        List.filter (fun (id, _, _) -> id <> waiter_id) state.waiters;
      pure false
  | Fence_await (fence_id, Report_resume_pack resume) -> (
      match
        List.find_opt
          (fun fence -> Ids.Fence_id.equal fence.f_id fence_id)
          state.fences
      with
      | Some fence -> (
          match fence.f_report with
          | Some report ->
              resume (Exit.Ok report);
              pure false
          | None ->
              fence.f_waiters <- Report_resume_pack resume :: fence.f_waiters;
              pure false)
      | None ->
          resume
            (Exit.Error
               (Cause.die
                  (Component_generation.Invariant
                     "eta_component: unknown fence")));
          pure false)
  | Gen_payload (Component_generation.Staged staged) ->
      let* () = process_staged state supervisor staged in
      complete_ready_fences state;
      touch state;
      pure (should_stop state)
  | Gen_payload (Component_generation.Settled settled) ->
      let* () = process_settled state supervisor settled in
      complete_ready_fences state;
      touch state;
      pure (should_stop state)
  | Body_done ->
      state.body_done <- true;
      let* _ = initiate_shutdown state supervisor in
      complete_ready_fences state;
      touch state;
      pure (should_stop state)

let rec loop :
    type s err.
    (s, err) state -> (s, err) Supervisor.t -> (s, unit, err) Supervisor.Scope.t =
 fun state supervisor ->
  let open Supervisor.Scope in
  let* take_exit = lift (Effect.to_exit (Queue.take state.queue)) in
  match take_exit with
  | Error _ -> pure ()
  | Ok msg ->
      let* stop =
        match
          (try Ok (process state supervisor msg)
           with exn -> Error exn)
        with
        | Ok scope -> scope
        | Error exn ->
            (* A component-runtime invariant violation fails the whole
               context with its cause. *)
            context_fail state supervisor (Cause.die exn)
            >>= fun _ -> pure (should_stop state)
      in
      (* Flush recorded telemetry after the serialized mutation completes.
         A dropped or disabled sink changes nothing authoritative. *)
      let* () = flush_telemetry state in
      if stop then pure () else loop state supervisor

(* ------------------------------------------------------------------ *)
(* Handles and public operations                                       *)
(* ------------------------------------------------------------------ *)

type context = {
  ch_queue : (msg, unit) Queue.t;
  ch_running : bool Mutable_ref.t;
  ch_stamp : int;
  ch_owner : int;
}

type diagnostics = {
  dh_queue : (msg, unit) Queue.t;
  dh_running : bool Mutable_ref.t;
  dh_stamp : int;
  dh_final : Diag.snapshot option ref;
  dh_owner : int;
}

let waiter_ids = Atomic.make 0

(* Context operations are serialized through the coordinator queue. An
   operation admitted after shutdown returns [Context_not_running]; an
   operation rejected by admission creates no settlement fence and changes no
   accepted state. *)
let submit handle build =
  Effect.async ~register:(fun resume ->
      check_owner handle.ch_owner;
      if not (Mutable_ref.get handle.ch_running) then (
        resume (Exit.Error (Cause.fail Context_not_running));
        None)
      else
        match Queue.try_offer_now handle.ch_queue (build resume) with
        | `Sent -> None
        | _ ->
            resume (Exit.Error (Cause.fail Context_not_running));
            None)

let reconcile handle desired =
  submit handle (fun resume -> Reconcile (desired, resume))

let retry handle entry = submit handle (fun resume -> Retry (entry, resume))

let replace handle batch = submit handle (fun resume -> Replace (batch, resume))

let shutdown handle = submit handle (fun resume -> Shutdown resume)

(* [snapshot] returns one atomic projection of the serialized coordinator
   state and creates no semantic lifecycle event. *)
let snapshot handle =
  let reply_final resume =
    match !(handle.dh_final) with
    | Some snapshot ->
        resume (Exit.Ok snapshot);
        None
    | None ->
        resume
          (Exit.Error (invariant_die "eta_component: snapshot unavailable"));
        None
  in
  Effect.async ~register:(fun resume ->
      check_owner handle.dh_owner;
      if not (Mutable_ref.get handle.dh_running) then reply_final resume
      else
        match
          Queue.try_offer_now handle.dh_queue
            (Snapshot_req (Snapshot_resume resume))
        with
        | `Sent -> None
        | _ -> reply_final resume)

(* [await_change] reads the current revision and registers the waiter in one
   atomic coordinator operation; intermediate revisions coalesce. *)
let await_change handle ~after =
  Effect.async ~register:(fun resume ->
      check_owner handle.dh_owner;
      if after.Ids.stamp <> handle.dh_stamp then (
        resume (Exit.Error (Cause.fail Diag.Wrong_context));
        None)
      else if not (Mutable_ref.get handle.dh_running) then (
        match !(handle.dh_final) with
        | Some snapshot ->
            if after.Ids.id > (Diag.revision snapshot).Ids.id then (
              resume (Exit.Error (Cause.fail Diag.Invalid_revision));
              None)
            else (
              resume (Exit.Ok (Diag.Closed snapshot));
              None)
        | None ->
            resume
              (Exit.Error
                 (invariant_die "eta_component: final snapshot unavailable"));
            None)
      else
        let waiter_id = Atomic.fetch_and_add waiter_ids 1 in
        match
          Queue.try_offer_now handle.dh_queue
            (Await_req (waiter_id, after, resume))
        with
        | `Sent ->
            Some
              (Effect.sync (fun () ->
                   ignore
                     (Queue.try_offer_now handle.dh_queue
                        (Remove_waiter waiter_id)
                      : _ Queue.offer_result)))
        | _ ->
            resume
              (Exit.Error
                 (invariant_die "eta_component: change wait unavailable"));
            None)

(* ------------------------------------------------------------------ *)
(* Context.run                                                         *)
(* ------------------------------------------------------------------ *)

(* One lexical [Context.run] effect owns one [Supervisor.scoped] nursery;
   each generation is a private supervisor child with a fresh
   [Effect.with_scope] lifetime. When the body returns, fails, or is
   interrupted, shutdown starts and the context waits for every owned scope
   to settle before the effect completes. *)
let run : type value error.
    (context -> diagnostics -> (value, error) Effect.t) ->
    (value, error) Effect.t =
 fun body ->
  Supervisor.scoped
    {
      run =
        (fun supervisor ->
          let open Supervisor.Scope in
          let stamp = Ids.fresh_context_stamp () in
          let running = Mutable_ref.make true in
          let state =
            {
              queue = Queue.unbounded ();
              stamp;
              owner_domain = (Domain.self () :> int);
              revision = 0;
              desired_counter = 0;
              desired = None;
              instances = [];
              registry = Hashtbl.create 16;
              episodes = Hashtbl.create 16;
              fences = [];
              waiters = [];
              lifecycle = Diag.Running;
              integrity_failed = None;
              shutdown_fence = None;
              admission_open = true;
              body_done = false;
              latest_source_revision = None;
              txs = [];
              running;
              counters = Array.make 8 0;
              retiring_order = 0;
              telemetry = [ Component_telemetry.Lifecycle "running" ];
            }
          in
          let context =
            {
              ch_queue = state.queue;
              ch_running = running;
              ch_stamp = stamp;
              ch_owner = state.owner_domain;
            }
          in
          let diagnostics =
            {
              dh_queue = state.queue;
              dh_running = running;
              dh_stamp = stamp;
              dh_final = ref None;
              dh_owner = state.owner_domain;
            }
          in
          let emit_body_done () =
            ignore
              (Queue.try_offer_now state.queue Body_done
                 : _ Queue.offer_result)
          in
          let* body_child =
            start supervisor
              (lift
                 (Effect.on_exit
                    (fun _exit -> Effect.sync emit_body_done)
                    (body context diagnostics)))
          in
          let* () = loop state supervisor in
          (* The context is closed: deliver the final snapshot to every
             remaining waiter and expose it through diagnostics. *)
          state.lifecycle <- Diag.Stopped;
          record state (Component_telemetry.Lifecycle "stopped");
          touch state;
          let final_snapshot = build_snapshot state in
          List.iter
            (fun (_, _, resume) ->
              resume (Exit.Ok (Diag.Closed final_snapshot)))
            state.waiters;
          state.waiters <- [];
          List.iter
            (fun fence ->
              if not fence.f_complete then (
                fence.f_context_failed <- true;
                fence.f_pending <- 0;
                maybe_complete_fence state fence))
            state.fences;
          diagnostics.dh_final := Some final_snapshot;
          Mutable_ref.set running false;
          let* () = flush_telemetry state in
          Queue.shutdown state.queue;
          (* Preserve the body cause: awaiting the body child re-enters its
             exact exit. *)
          await body_child);
    }

let context_id context = context.ch_stamp
