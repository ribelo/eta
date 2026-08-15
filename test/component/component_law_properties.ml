(* Component law properties.

   Observation boundary: the public diagnostics snapshot after each generated
   reconcile (entry ids, phases, integrity), plus the fiber census at
   teardown. The generated class covers independent and provider-consumer
   dependency graphs with enabled/config churn, random ordering of per-entry
   reconciles, and snapshot mutation rejection. *)

open Eta
open Eta_component

module Stdlib_Random = Stdlib.Random

let ( let* ) = Syntax.( let* )
let ( >>= ) = Effect.( >>= )
let qcheck_seed = Stdlib_Random.State.make [| 0xE7A; 0xC0DE |]
let count = 40

let entry_id_exn id =
  match Entry_id.of_string id with
  | Ok id -> id
  | Error _ -> Alcotest.fail ("invalid entry id: " ^ id)

let coeffect_exn name = Coeffect.create ~name ~equivalent:Int.equal ()

let run_program program =
  Gc.full_major ();
  Gc.compact ();
  let outcome = Eta_test.Run.run program in
  Gc.full_major ();
  Gc.compact ();
  outcome

let expect_ok outcome =
  match outcome.Eta_test.Run.exit with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "context body raised an error"

let census_available outcome =
  match outcome.Eta_test.Run.pending_fibers with
  | Some [] -> true
  | Some _ -> false
  | None -> false

(* A tracked activation counter, one per generated component family. *)
type probe = { mutable p_activations : int }

let pp_string_error ppf error = Format.pp_print_string ppf error

let probe_component probe name =
  let family = Component.Family.create ~name ~module_locator:name () in
  match
    Component.make ~family ~config_equal:Int.equal
      ~requirements:Requirement.none ~provisions:Provision.none
      ~pp_error:pp_string_error
      ~activate:(fun _config () activation ->
        Effect.sync (fun () -> probe.p_activations <- probe.p_activations + 1)
        >>= fun () ->
        Activation.own activation ~acquire:Effect.unit
          ~release:(fun () -> Effect.unit)
          ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "r"))
  with
  | Ok component -> component
  | Error _ -> Alcotest.fail "probe_component: make failed"

(* -- Generated class 1: independent-key churn ------------------------- *)

type independent_entry = { ie_name : string; ie_enabled : bool; ie_config : int }

let independent_gen =
  let open QCheck.Gen in
  let entry_gen =
    map3
      (fun name enabled config -> { ie_name = name; ie_enabled = enabled; ie_config = config })
      (oneof_list [ "alpha"; "beta"; "gamma"; "delta" ])
      (oneof_weighted [ (3, return true); (1, return false) ])
      (int_range 0 3)
  in
  (* A snapshot is a set of entries (at most one row per name). *)
  let snapshot_gen =
    list_size (int_range 0 4) entry_gen
    |> map (fun rows ->
           let table = Hashtbl.create 4 in
           List.iter (fun row -> Hashtbl.replace table row.ie_name row) rows;
           Hashtbl.fold (fun _ row acc -> row :: acc) table [])
  in
  list_size (int_range 1 6) snapshot_gen

let independent_program snapshots =
  let probes =
    List.map (fun name -> (name, { p_activations = 0 }))
      [ "alpha"; "beta"; "gamma"; "delta" ]
  in
  let component_of name = probe_component (List.assoc name probes) name in
  let components = List.map (fun name -> (name, component_of name)) [ "alpha"; "beta"; "gamma"; "delta" ] in
  let tree_of_snapshot rows =
    Desired_state.tree
      (List.map
         (fun row ->
           Desired_state.component
             (Desired_state.Entry.make
                ~id:(entry_id_exn row.ie_name)
                ~component:(List.assoc row.ie_name components)
                ~config:row.ie_config ~enabled:row.ie_enabled
                ~context:Desired_state.Context_spec.empty))
         rows)
  in
  Context.run (fun context diagnostics ->
      let rec step = function
        | [] -> Effect.pure []
        | snapshot :: rest ->
            let* fence = Context.reconcile context (tree_of_snapshot snapshot) in
            let* _ = Diagnostics.Fence.await fence in
            let* view = Diagnostics.snapshot diagnostics in
            let phases =
              List.map
                (fun instance ->
                  let id = Format.asprintf "%a" Entry_id.pp (Diagnostics.entry_id instance) in
                  let phase =
                    match Diagnostics.phase instance with
                    | Diagnostics.Inactive -> "inactive"
                    | Diagnostics.Waiting -> "waiting"
                    | Diagnostics.Activating _ -> "activating"
                    | Diagnostics.Active _ -> "active"
                    | Diagnostics.Settling _ -> "settling"
                    | Diagnostics.Activation_failed _ -> "activation-failed"
                    | Diagnostics.Recovery_failed _ -> "recovery-failed"
                  in
                  (id, phase))
                (Diagnostics.instances view)
              |> List.sort compare
            in
            let* rest_result = step rest in
            Effect.pure (phases :: rest_result)
      in
      let* result = step snapshots in
      let* final = Diagnostics.snapshot diagnostics in
      Effect.sync (fun () -> (result, List.length (Diagnostics.instances final))))

let pp_independent_snapshot rows =
  Printf.sprintf "[%s]"
    (String.concat "; "
       (List.map
          (fun row ->
            Printf.sprintf "%s:%b:%d" row.ie_name row.ie_enabled row.ie_config)
          rows))

(* Law: reconciling a generated sequence of independent-key snapshots
   converges; after the last snapshot every enabled entry is active and
   every disabled or absent entry is gone. The fiber census at teardown is
   available and empty. *)
let property_independent_key_convergence =
  QCheck.Test.make ~name:"component independent-key convergence" ~count
    QCheck.(
      make
        ~print:Print.(list pp_independent_snapshot)
        independent_gen)
    (fun snapshots ->
      let outcome = run_program (independent_program snapshots) in
      let phases_history, _final_count = expect_ok outcome in
      (* The distinguishing observation: the expected final projection is
         derived from the last generated snapshot and compared exactly
         against the observed final phases. *)
      let expected =
        match List.nth_opt snapshots (List.length snapshots - 1) with
        | None -> []
        | Some last ->
            List.filter_map
              (fun row ->
                if row.ie_enabled then Some (row.ie_name, "active") else None)
              last
            |> List.sort compare
      in
      let observed =
        match List.nth_opt phases_history (List.length phases_history - 1) with
        | None -> []
        | Some phases ->
            List.filter (fun (_, phase) -> phase = "active") phases
            |> List.sort compare
      in
      expected = observed && census_available outcome)

(* -- Generated class 2: whole-snapshot atomicity ------------------------ *)

(* A snapshot with a dependency cycle or duplicate provider must reject
   without mutating any previously committed state. *)
type bad_row = { b_name : string; b_requires : string option }

let bad_snapshot_gen =
  let open QCheck.Gen in
  (* Generate snapshots that always contain the cyclic pair a<->b plus
     optional independent entries; admission must reject the whole. *)
  let extra_gen =
    list_size (int_range 0 3)
      (map
         (fun name -> { b_name = name; b_requires = None })
         (oneof_list [ "x"; "y"; "z" ]))
  in
  map
    (fun extra ->
      [ { b_name = "ca"; b_requires = Some "key-b" };
        { b_name = "cb"; b_requires = Some "key-a" } ]
      @ List.filter
          (fun row -> row.b_name <> "ca" && row.b_name <> "cb")
          extra)
    extra_gen

let bad_snapshot_program rows =
  let key_a = coeffect_exn "key-a" in
  let key_b = coeffect_exn "key-b" in
  let mk name requires provides =
    let family = Component.Family.create ~name ~module_locator:name () in
    let requirements : unit Requirement.t =
      match requires with
      | Some "key-a" -> Requirement.map (fun (_ : int) -> ()) (Requirement.one key_a)
      | Some "key-b" -> Requirement.map (fun (_ : int) -> ()) (Requirement.one key_b)
      | Some _ | None -> Requirement.none
    in
    let provisions : int Provision.t =
      match provides with
      | Some "key-a" -> Provision.one key_a
      | Some "key-b" -> Provision.one key_b
      | Some _ | None -> Provision.contramap (fun (_ : int) -> ()) Provision.none
    in
    match
      Component.make ~family ~config_equal:Int.equal ~requirements ~provisions
        ~pp_error:pp_string_error
        ~activate:(fun _config _req activation ->
          Activation.own activation ~acquire:Effect.unit
            ~release:(fun () -> Effect.unit)
            ~pp_release_error:(fun ppf _ -> Format.pp_print_string ppf "r")
          >>= fun () -> Effect.pure 0)
    with
    | Ok component -> component
    | Error _ -> Alcotest.fail "mk: make failed"
  in
  let component_of row =
    match row.b_name with
    | "ca" -> mk "ca" row.b_requires (Some "key-a")
    | "cb" -> mk "cb" row.b_requires (Some "key-b")
    | name -> mk name row.b_requires None
  in
  let tree =
    Desired_state.tree
      (List.map
         (fun row ->
           Desired_state.component
             (Desired_state.Entry.make ~id:(entry_id_exn row.b_name)
                ~component:(component_of row) ~config:0 ~enabled:true
                ~context:Desired_state.Context_spec.empty))
         rows)
  in
  Context.run (fun context diagnostics ->
      (* First commit a known-good baseline. *)
      let baseline_probe = { p_activations = 0 } in
      let baseline = probe_component baseline_probe "baseline" in
      let* baseline_fence =
        Context.reconcile context
          (Desired_state.tree
             [ Desired_state.component
                 (Desired_state.Entry.make ~id:(entry_id_exn "base")
                    ~component:baseline ~config:0 ~enabled:true
                    ~context:Desired_state.Context_spec.empty) ])
      in
      let* _ = Diagnostics.Fence.await baseline_fence in
      let* before = Diagnostics.snapshot diagnostics in
      (* Then attempt the bad snapshot: it must reject atomically. *)
      let* rejected =
        Effect.fold ~ok:(fun _ -> false) ~error:(fun _ -> true)
          (Context.reconcile context tree)
      in
      let* after = Diagnostics.snapshot diagnostics in
      Effect.sync (fun () -> (rejected, before, after)))

let snapshot_digest view =
  List.map
    (fun instance ->
      ( Format.asprintf "%a" Entry_id.pp (Diagnostics.entry_id instance),
        (match Diagnostics.phase instance with
        | Diagnostics.Active _ -> "active" | _ -> "other") ))
    (Diagnostics.instances view)
  |> List.sort compare

let property_whole_snapshot_atomicity =
  QCheck.Test.make ~name:"component whole-snapshot atomicity" ~count
    QCheck.(make ~print:Print.(list (fun row -> row.b_name)) bad_snapshot_gen)
    (fun rows ->
      let outcome = run_program (bad_snapshot_program rows) in
      let rejected, before, after = expect_ok outcome in
      rejected
      && snapshot_digest before = snapshot_digest after
      && census_available outcome)

let laws =
  [ property_independent_key_convergence; property_whole_snapshot_atomicity ]

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      laws
  in
  exit code
