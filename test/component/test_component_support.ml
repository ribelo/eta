(* Test helpers: tracked components and shared builders.

   A tracked component records every activation, acquisition, and release in
   a shared event log so gates can assert exact order and cardinality. *)

open Eta
open Eta_component

let ( let* ) = Syntax.( let* )
let ( >>= ) = Effect.( >>= )

(* ------------------------------------------------------------------ *)
(* Identifiers and entries                                             *)
(* ------------------------------------------------------------------ *)

let entry_id_exn id =
  match Entry_id.of_string id with
  | Ok entry_id -> entry_id
  | Error _ -> Alcotest.failf "bad entry id: %s" id

let context_id_exn name = name

(* ------------------------------------------------------------------ *)
(* Tracked components                                                  *)
(* ------------------------------------------------------------------ *)

type tracked = {
  t_name : string;
  mutable t_activations : int;
  mutable t_events : string list;
  mutable t_fail_with : string option;
  mutable t_hang : bool;
  t_shared : string list ref;
}

let tracked name =
  {
    t_name = name;
    t_activations = 0;
    t_events = [];
    t_fail_with = None;
    t_hang = false;
    t_shared = ref [];
  }

let track tracked event =
  tracked.t_events <- tracked.t_events @ [ event ];
  tracked.t_shared := !(tracked.t_shared) @ [ event ]

let events tracked = tracked.t_events
let shared_events tracked = !(tracked.t_shared)

(* Two tracked components that share one ordered event log, for observing
   cross-component interleaving. *)
let tracked_pair name_a name_b =
  let a = tracked name_a in
  let b = tracked name_b in
  b.t_events <- [];
  let shared = a.t_shared in
  let b = { b with t_shared = shared } in
  (a, b)

let take_events tracked =
  let evts = tracked.t_events in
  tracked.t_events <- [];
  evts

(* A component whose activation acquires one tracked resource named after
   the component and releases it on settlement. [~provision] supplies the
   provided coeffect value. *)
let tracked_component tracked =
  let family =
    Component.Family.create ~name:tracked.t_name
      ~module_locator:tracked.t_name ()
  in
  match
    Component.make ~family ~config_equal:Int.equal
      ~requirements:Requirement.none ~provisions:Provision.none
      ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
      ~activate:(fun _config () activation ->
        Effect.sync (fun () ->
            tracked.t_activations <- tracked.t_activations + 1;
            track tracked "activate")
        >>= fun () ->
        match tracked.t_fail_with with
        | Some error ->
            track tracked "fail";
            Effect.fail error
        | None ->
            if tracked.t_hang then Effect.never
            else
              Activation.own activation
                ~acquire:
                  (Effect.sync (fun () ->
                       track tracked ("acquire:" ^ tracked.t_name)))
                ~release:(fun () ->
                  Effect.sync (fun () ->
                      track tracked ("release:" ^ tracked.t_name)))
                ~pp_release_error:(fun ppf _ ->
                  Format.pp_print_string ppf "release-err"))
  with
  | Ok component -> component
  | Error _ -> Alcotest.fail "tracked_component: make failed"

(* A provider component that provides one coeffect value. *)
let provider_component tracked coeffect value_of_config =
  let family =
    Component.Family.create ~name:tracked.t_name
      ~module_locator:tracked.t_name ()
  in
  match
    Component.make ~family ~config_equal:Int.equal
      ~requirements:Requirement.none
      ~provisions:(Provision.one coeffect)
      ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
      ~activate:(fun config () activation ->
        Effect.sync (fun () ->
            tracked.t_activations <- tracked.t_activations + 1;
            track tracked "activate")
        >>= fun () ->
        Activation.own activation
          ~acquire:
            (Effect.sync (fun () -> track tracked ("acquire:" ^ tracked.t_name)))
          ~release:(fun () ->
            Effect.sync (fun () -> track tracked ("release:" ^ tracked.t_name)))
          ~pp_release_error:(fun ppf _ ->
            Format.pp_print_string ppf "release-err")
        >>= fun () -> Effect.pure (value_of_config config))
  with
  | Ok component -> component
  | Error _ -> Alcotest.fail "provider_component: make failed"

(* A consumer component that requires one coeffect value. *)
let consumer_component tracked coeffect =
  let family =
    Component.Family.create ~name:tracked.t_name
      ~module_locator:tracked.t_name ()
  in
  match
    Component.make ~family ~config_equal:Int.equal
      ~requirements:(Requirement.one coeffect)
      ~provisions:Provision.none
      ~pp_error:(fun ppf error -> Format.pp_print_string ppf error)
      ~activate:(fun _config requirement activation ->
        Effect.sync (fun () ->
            tracked.t_activations <- tracked.t_activations + 1;
            track tracked (Printf.sprintf "activate:%d" requirement))
        >>= fun () ->
        Activation.own activation
          ~acquire:
            (Effect.sync (fun () -> track tracked ("acquire:" ^ tracked.t_name)))
          ~release:(fun () ->
            Effect.sync (fun () -> track tracked ("release:" ^ tracked.t_name)))
          ~pp_release_error:(fun ppf _ ->
            Format.pp_print_string ppf "release-err"))
  with
  | Ok component -> component
  | Error _ -> Alcotest.fail "consumer_component: make failed"

(* ------------------------------------------------------------------ *)
(* Desired-state builders                                              *)
(* ------------------------------------------------------------------ *)

let entry id component config =
  Desired_state.Entry.make ~id:(entry_id_exn id) ~component ~config
    ~enabled:true ~context:Desired_state.Context_spec.empty

let tree_of entries =
  Desired_state.tree (List.map (fun entry -> Desired_state.component entry) entries)

let coeffect_exn name =
  Coeffect.create ~name ~equivalent:Int.equal ()

(* ------------------------------------------------------------------ *)
(* Run helpers                                                         *)
(* ------------------------------------------------------------------ *)

let run_program program =
  (* Reclaim backend resources between the many short-lived test runtimes so
     io_uring ring memory from earlier runs does not exhaust the sandbox. *)
  Gc.full_major ();
  Gc.compact ();
  let outcome = Eta_test.Run.run program in
  Gc.full_major ();
  Gc.compact ();
  outcome

let expect_ok outcome =
  match outcome.Eta_test.Run.exit with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "run failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause

let check_census outcome =
  match outcome.Eta_test.Run.pending_fibers with
  | Some [] -> ()
  | Some fibers ->
      Alcotest.failf "pending fibers after run: %d" (List.length fibers)
  | None -> Alcotest.fail "fiber census unavailable"

let phase_name = function
  | Diagnostics.Inactive -> "inactive"
  | Diagnostics.Waiting -> "waiting"
  | Diagnostics.Activating _ -> "activating"
  | Diagnostics.Active _ -> "active"
  | Diagnostics.Settling _ -> "settling"
  | Diagnostics.Activation_failed _ -> "activation-failed"
  | Diagnostics.Recovery_failed _ -> "recovery-failed"

(* Test bodies mix admission and await error rows; [any_error] widens both
   to one string channel. Tests that expect success fail loudly through
   [expect_ok] when a typed failure reaches it. *)
let any_error effect =
  Effect.map_error (fun _ -> "error") effect

let snapshot_phases snapshot =
  List.map
    (fun instance ->
      ( Diagnostics.entry_id instance,
        phase_name (Diagnostics.phase instance) ))
    (Diagnostics.instances snapshot)

let find_phase snapshot entry =
  match
    List.find_opt
      (fun (id, _) -> Entry_id.equal id (entry_id_exn entry))
      (snapshot_phases snapshot)
  with
  | Some (_, phase) -> phase
  | None -> Alcotest.failf "no instance for entry %s" entry
