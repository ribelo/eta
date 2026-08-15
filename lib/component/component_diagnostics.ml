(* Immutable diagnostics projections.

   Snapshot, participant, and report values are immutable. The authoritative
   retained failure stays an existential same-domain ['error Eta.Cause.t];
   [Failure.t] exposes only pre-rendered pretty, compact, and portable
   projections and never unpacks the existential cause. *)

open Eta

module Context_id = Component_ids.Context_id
module Desired_revision = Component_ids.Desired_revision
module Target_revision = Component_ids.Target_revision
module Instance_id = Component_ids.Instance_id
module Generation_id = Component_ids.Generation_id
module Episode_id = Component_ids.Episode_id
module Fence_id = Component_ids.Fence_id

module Failure = struct
  type renderer_failure = { renderer_exception : string }

  type rendering = {
    pretty : string;
    compact : string;
    portable : string Cause.Portable.t;
  }

  type render_result =
    | Rendered of rendering
    | Renderer_failed of renderer_failure

  (* Retains the original existential same-domain cause. Never converted to a
     [result], a string, or a log-only event. *)
  type t =
    | Failure : {
        cause : 'error Cause.t;
        result : render_result;
      }
        -> t

  (* Each typed failure leaf is rendered at most once: one [Cause.map]
     traversal produces the rendered cause, and pretty, compact, and portable
     projections are derived from it without invoking the renderer again. *)
  let of_cause pp_error cause =
    let render_leaf error =
      Format.asprintf "%a" (fun fmt value -> pp_error fmt value) error
    in
    match Cause.map render_leaf cause with
    | rendered ->
        let portable = Cause.to_portable Fun.id rendered in
        Failure
          {
            cause;
            result =
              Rendered
                {
                  pretty = Cause.pretty Fun.id rendered;
                  compact = Cause.pp_compact Fun.id rendered;
                  portable;
                };
          }
    | exception exn ->
        Failure
          {
            cause;
            result =
              Renderer_failed { renderer_exception = Printexc.to_string exn };
          }

  (* A cause with no typed failure leaves (for example a callback defect)
     renders without any component printer. *)
  let of_cause_without_renderer cause =
    of_cause (fun _fmt _error -> ()) cause

  (* A release-error renderer failure recorded at capture time: the
     authoritative cause is retained unchanged and the public rendering is
     [Renderer_failed] with the recorded renderer exception. *)
  let of_cause_renderer_failed cause ~renderer_exception =
    Failure { cause; result = Renderer_failed { renderer_exception } }

  let rendering (Failure failure) = failure.result

  (* [pp] and [pp_compact] use captured text only: they invoke no component
     code and no retained error printer. *)
  let pp fmt (Failure failure) =
    match failure.result with
    | Rendered rendering -> Format.pp_print_string fmt rendering.pretty
    | Renderer_failed { renderer_exception } ->
        Format.fprintf fmt "<failure renderer failed: %s>" renderer_exception

  let pp_compact fmt (Failure failure) =
    match failure.result with
    | Rendered rendering -> Format.pp_print_string fmt rendering.compact
    | Renderer_failed { renderer_exception } ->
        Format.fprintf fmt "<failure renderer failed: %s>" renderer_exception

  let pp_renderer_failure fmt { renderer_exception } =
    Format.fprintf fmt "renderer raised: %s" renderer_exception
end

type lifecycle =
  | Running
  | Stopping
  | Stopped

type progress =
  | Quiescent
  | Reconciling
  | Blocked

type integrity =
  | Sound
  | Degraded of Instance_id.t list
  | Failed of Failure.t

(* Public diagnostic phases are constructed only when an immutable snapshot is
   created; the runtime stores the internal phase tag separately from the
   generation identifier. *)
type phase =
  | Inactive
  | Waiting
  | Activating of Generation_id.t
  | Active of Generation_id.t
  | Settling of Generation_id.t
  | Activation_failed of Generation_id.t * Failure.t
  | Recovery_failed of Generation_id.t * Failure.t

type revision = Component_ids.t

type requirement_binding = {
  requirement_name : string;
  requirement_provider : Episode_id.t;
}

type instance = {
  instance_entry_id : Component_entry_id.t;
  instance_instance_id : Instance_id.t;
  instance_target_revision : Target_revision.t option;
  instance_phase : phase;
  instance_provider_episode : Episode_id.t option;
  instance_committed_view : requirement_binding list;
}

module Fence = struct
  type kind =
    | Reconcile of Desired_revision.t
    | Retry of Component_entry_id.t
    | Replace of Component_source_revision.t
    | Shutdown

  type outcome =
    | Quiescent
    | Superseded
    | Rolled_back
    | Degraded
    | Restoration_failed
    | Context_failed

  type participant_role =
    | Started
    | Retired
    | Restored
    | Waited

  type participant = {
    participant_entry : Component_entry_id.t;
    participant_instance : Instance_id.t;
    participant_roles : participant_role list;
    participant_generations : Generation_id.t list;
    participant_episodes : Episode_id.t list;
    participant_terminal_phase : phase option;
    participant_removed : bool;
    participant_failure : Failure.t option;
  }

  type report = {
    report_id : Fence_id.t;
    report_kind : kind;
    report_admitted_at : revision;
    report_completed_at : revision;
    report_outcome : outcome;
    report_final_snapshot : snapshot;
    report_participants : participant list;
    report_failures : Failure.t list;
  }

  (* The settlement fence handle: one accepted context operation owns one
     fence. Repeated waits return the same terminal report. [fh_register]
     registers one report waiter with the serialized coordinator; the
     coordinator fills [fh_report] at completion. *)
  and report_resume_pack =
    | Report_resume_pack : ((report, 'e) Exit.t -> unit) -> report_resume_pack

  and t = {
    fence_id : Fence_id.t;
    fence_report_cell : report option ref;
    fence_register : report_resume_pack -> unit;
  }

  and fence_observation = {
    observed_id : Fence_id.t;
    observed_kind : kind;
    observed_complete : bool;
  }

  and snapshot = {
    snapshot_context_id : Context_id.t;
    snapshot_revision : revision;
    snapshot_accepted_desired_revision : Desired_revision.t option;
    snapshot_lifecycle : lifecycle;
    snapshot_progress : progress;
    snapshot_integrity : integrity;
    snapshot_instances : instance list;
    snapshot_fences : fence_observation list;
  }

  let id t = t.fence_id

  let await t =
    Effect.async ~register:(fun resume ->
        match !(t.fence_report_cell) with
        | Some report ->
            resume (Exit.Ok report);
            None
        | None ->
            t.fence_register (Report_resume_pack resume);
            None)
  let report_id report = report.report_id
  let kind report = report.report_kind
  let admitted_at report = report.report_admitted_at
  let completed_at report = report.report_completed_at
  let outcome report = report.report_outcome
  let final_snapshot report = report.report_final_snapshot
  let participants report = report.report_participants
  let failures report = report.report_failures
  let participant_entry participant = participant.participant_entry
  let participant_instance participant = participant.participant_instance
  let participant_roles participant = participant.participant_roles
  let participant_generations participant = participant.participant_generations
  let participant_episodes participant = participant.participant_episodes

  let participant_terminal_phase participant =
    participant.participant_terminal_phase

  let participant_removed participant = participant.participant_removed
  let participant_failure participant = participant.participant_failure
end

type snapshot = Fence.snapshot

let context_id snapshot = snapshot.Fence.snapshot_context_id
let revision snapshot = snapshot.Fence.snapshot_revision

let accepted_desired_revision snapshot =
  snapshot.Fence.snapshot_accepted_desired_revision

let lifecycle snapshot = snapshot.Fence.snapshot_lifecycle
let progress snapshot = snapshot.Fence.snapshot_progress
let integrity snapshot = snapshot.Fence.snapshot_integrity
let instances snapshot = snapshot.Fence.snapshot_instances
let fences snapshot = snapshot.Fence.snapshot_fences
let entry_id instance = instance.instance_entry_id
let instance_id instance = instance.instance_instance_id
let target_revision instance = instance.instance_target_revision
let phase instance = instance.instance_phase
let provider_episode instance = instance.instance_provider_episode
let committed_view instance = instance.instance_committed_view
let requirement_name binding = binding.requirement_name
let requirement_provider binding = binding.requirement_provider
let observed_fence_id observation = observation.Fence.observed_id
let observed_fence_kind observation = observation.Fence.observed_kind
let observed_fence_complete observation = observation.Fence.observed_complete

type change =
  | Changed of snapshot
  | Closed of snapshot

type await_error =
  | Wrong_context
  | Invalid_revision

type fence_observation = Fence.fence_observation
