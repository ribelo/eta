(* Tracked activation ownership.

   [Activation.t] is the narrow handle handed to component activation code. It
   carries the component-instance and activation-generation identity for
   lifecycle-diagnostics attribution, the generation admission fence, and the
   release-failure flag shared with the coordinator. It exposes no registry,
   dynamic lookup, publication, child-installation, context authority, runtime
   token, or lifecycle handle. *)

open Eta

type t = {
  admission_open : bool Mutable_ref.t;
  instance_id : Component_ids.Instance_id.t;
  generation_id : Component_ids.Generation_id.t;
  release_failed_flag : bool ref;
  renderer_failed_ref : string option ref;
}

let make ~admission_open ~instance_id ~generation_id ~release_failed_flag
    ~renderer_failed_ref =
  { admission_open; instance_id; generation_id; release_failed_flag;
    renderer_failed_ref }

let instance_id t = t.instance_id
let generation_id t = t.generation_id
let release_failed t = !(t.release_failed_flag)
let renderer_failed t = !(t.renderer_failed_ref)

(* Closed admission is reported as requested lifecycle interruption without
   widening the acquisition-error type. The coordinator closes admission only
   as part of a target change that also requests cancellation, so parking on
   an interruptible never-point delivers the pending interruption promptly. *)
let closed_admission () : ('a, 'err) Effect.t =
  Effect.interruptible Effect.never

(* The total internal renderer wrapper: a raising [pp_release_error] records
   the renderer failure for diagnostics, produces stable fallback text, and
   never replaces the authoritative finalizer cause. *)
let total_renderer ~record pp fmt error =
  try pp fmt error
  with exn ->
    record (Printexc.to_string exn);
    Format.fprintf fmt "<release-error renderer failed: %s>"
      (Printexc.to_string exn)

let own t ~acquire ~release ~pp_release_error =
  if not (Mutable_ref.get t.admission_open) then closed_admission ()
  else
    (* [acquire_release] registers the release with the current Eta activation
       scope before it returns, including an acquisition that lands after
       cancellation was requested. The scope runs releases serially in reverse
       registration order, at most once each, and retains a release failure in
       the finalizer cause.

       The release error is rendered exactly once by [pp_release_error] at
       failure time and re-failed as the pre-rendered string inside an inner
       scope whose finalizer capture passes string leaves through, so the
       settled release-error leaf carries precisely this rendering. A raising
       renderer records the failure for diagnostics and falls back to stable
       text; the authoritative finalizer cause is unchanged. *)
    Effect.acquire_release ~acquire ~release:(fun resource ->
        Effect.on_exit
          (fun exit ->
            Effect.sync (fun () ->
                if Exit.is_error exit then t.release_failed_flag := true))
          (Eta_observability.with_error_pp Format.pp_print_string
             (Effect.map (fun (_ : string option) -> ())
                (Effect.with_scope
                   (Effect.acquire_release
                      ~acquire:
                        (Effect.fold
                           ~ok:(fun () -> None)
                           ~error:(fun error ->
                             Some
                               (Format.asprintf "%a"
                                  (total_renderer
                                     ~record:(fun renderer_exception ->
                                       t.renderer_failed_ref :=
                                         Some renderer_exception)
                                     pp_release_error)
                                  error))
                           (release resource))
                      ~release:(fun rendered ->
                        match rendered with
                        | None -> Effect.unit
                        | Some text -> Effect.fail text))))))
