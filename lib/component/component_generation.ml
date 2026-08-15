(* Activation generation child programs.

   Each generation runs as one private supervisor child with one fresh
   [Effect.with_scope] lifetime. The child resolves its requirement values,
   runs the component activation, stages the complete provision set, waits for
   the coordinator commit decision, parks a committed generation on its
   private normal-stop signal, and reports the settled scope exit back to the
   coordinator. *)

open Eta
module Coeffect = Component_coeffect
module Declaration = Component_declaration
module Ids = Component_ids

let ( >>= ) = Effect.( >>= )

type commit_decision =
  | Commit
  | Abort

type commit_cell =
  | Commit_cell : (commit_decision, 'e) Promise.t -> commit_cell

type stop_cell =
  | Stop_cell : (unit, 'e) Promise.t -> stop_cell

(* Pre-classified by the child through [Effect.on_exit] so the coordinator
   never needs to unpack the existential primary result. *)
type activation_summary =
  | Completed
  | Failed
  | Interrupted
  | Not_started

type settled_cause =
  | Settled_cause :
      (Format.formatter -> 'e -> unit) * (unit, 'e) Exit.t
      -> settled_cause

type staged = {
  staged_instance : Ids.Instance_id.t;
  staged_generation : Ids.Generation_id.t;
  staged_bindings : Coeffect.binding list;
  staged_commit : commit_cell;
}

type settled = {
  settled_instance : Ids.Instance_id.t;
  settled_generation : Ids.Generation_id.t;
  settled_summary : activation_summary;
  settled_cleanup_failed : bool;
  settled_renderer_failed : string option;
  settled_cause : settled_cause option;
}

type payload =
  | Staged of staged
  | Settled of settled

(* Runtime invariant violation raised when a guaranteed structural condition
   does not hold (for example a committed view that misses a declared
   requirement). The coordinator recognizes this exception in a generation
   cause and fails the whole component context with its cause. *)
exception Invariant of string

(* Build one generation child blueprint. [stop_slot] is filled synchronously
   during blueprint construction with the private normal-stop cell; the
   coordinator resolves it to deactivate a committed generation. *)
let program ~emit ~component ~config
    ~requirement_bindings ~interception_slots ~activation ~stop_slot
    ~instance_id ~generation_id () =
  let (Declaration.Component component) = component in
  let normal_stop = Promise.create () in
  stop_slot := Some (Stop_cell normal_stop);
  let activation_exit = ref Not_started in
  let body =
    Effect.sync (fun () ->
        Declaration.resolve component.requirements requirement_bindings
          interception_slots)
    >>= fun requirements ->
    Effect.on_exit
      (fun exit ->
        Effect.sync (fun () ->
            activation_exit :=
              (match exit with
              | Exit.Ok _ -> Completed
              | Exit.Error cause when Cause.is_interrupt_only cause ->
                  Interrupted
              | Exit.Error _ -> Failed)))
      (component.activate config requirements activation)
    >>= fun provision_value ->
    let staged_bindings = Declaration.stage component.provisions provision_value in
    let commit_cell = Promise.create () in
    emit
      (Staged
         {
           staged_instance = instance_id;
           staged_generation = generation_id;
           staged_bindings;
           staged_commit = Commit_cell commit_cell;
         });
    Promise.await commit_cell >>= fun decision ->
    match decision with
    | Abort -> Effect.unit
    | Commit -> Effect.discard (Promise.await normal_stop)
  in
  Effect.to_exit (Effect.with_scope body) >>= fun final_exit ->
  emit
    (Settled
       {
         settled_instance = instance_id;
         settled_generation = generation_id;
         settled_summary = !activation_exit;
         settled_cleanup_failed =
           Component_activation.release_failed activation;
         settled_renderer_failed = Component_activation.renderer_failed activation;
         settled_cause =
           (match final_exit with
           | Exit.Ok () -> None
           | Exit.Error _ ->
               Some (Settled_cause (component.pp_error, final_exit)));
       });
  Effect.unit
