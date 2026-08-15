module Crux = Eta_crux
module Projection = Eta_crux_test.Projection_harness.Opaque
module Typed_projection = Eta_crux_test.Projection_harness

let output_of_delivery delivery =
  Eta_crux_test.Projection_harness.Opaque.delivery_value
    (Crux.Driver.Delivery.projection delivery)
  |> Option.get

let output_of_commit commit =
  Eta_crux_test.Projection_harness.Opaque.commit_value commit
  |> Option.get

let latest_committed_snapshot driver =
  Option.bind (Crux.Driver.latest_committed_snapshot driver)
    Eta_crux_test.Projection_harness.Opaque.snapshot_value

let handle_latest_committed_snapshot handle =
  Option.bind (Eta_crux_test.Handle.latest_committed_snapshot handle)
    Eta_crux_test.Projection_harness.Opaque.snapshot_value

let handle_latest_delivered_snapshot handle =
  Option.bind (Eta_crux_test.Handle.latest_delivered_snapshot handle)
    Eta_crux_test.Projection_harness.Opaque.snapshot_value

let projection_content_value = function
  | Crux.Wire.Frame.Bootstrap (entry :: _) -> entry.value
  | Crux.Wire.Frame.Updates updates ->
      let rec latest = function
        | [] -> None
        | Crux.Wire.Frame.Attached entry :: rest
        | Crux.Wire.Frame.Changed entry :: rest -> (
            match latest rest with
            | Some _ as value -> value
            | None -> Some entry.value)
        | Crux.Wire.Frame.Removed _ :: rest -> latest rest
      in
      latest updates |> Option.get
  | Crux.Wire.Frame.Bootstrap [] ->
      invalid_arg "expected a nonempty projection frame"
module Int_map = Eta_signal_map.Map.Make (Int)

let int_map_find key map =
  match Int_map.find_opt key map with
  | Some value -> value
  | None -> invalid_arg "Eta Crux law: missing map key"

let shared_runtime : Crux.never Eta.Runtime.t option ref = ref None
let shared_clock : Eta_test.Test_clock.t option ref = ref None

let run_ok eff =
  match !shared_runtime with
  | None -> failwith "law runtime is not installed"
  | Some runtime ->
      Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let law_clock () =
  match !shared_clock with
  | Some clock -> clock
  | None -> failwith "law clock is not installed"

let committed = function
  | Ok (Crux.Root.Committed { commit; post_commit }) ->
      let output = output_of_commit commit in
      (output, post_commit)
  | _ -> failwith "expected a committed advancement"

let start post_commit =
  ignore
    (run_ok
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (function
            | Crux.Post_commit.Already_started ->
                Failure "post-commit token started twice")))

let send endpoint action =
  run_ok
    (Crux.Endpoint.send endpoint action
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"))

let stop_root root =
  Crux.Root.request_stop root;
  match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start post_commit
  | _ -> failwith "root did not stop"

let small_actions =
  let open QCheck.Gen in
  list_size (0 -- 20) (-10 -- 10)

(** Each property has a generated class and an observation boundary.

    - [qcheck_description_identity] generates bounded action lists. It observes
      transition count and both outputs from one shared description.
    - [qcheck_cutoff_boundary] generates bounded action lists. It observes
      projection counts for every public cutoff constructor and every committed
      model.
    - [qcheck_assoc_key_order] generates bounded key-value bindings. It observes
      the complete ordered child map.
    - [qcheck_assoc_continuous_presence] generates one retained key and action.
      It observes the retained endpoint and model.
    - [qcheck_assoc_data_update] generates one key, data, and action. It observes
      cutoff direction, baseline retention, builder count, endpoint identity,
      retained model, and accepted data.
    - [qcheck_assoc_remove_reenter] generates one key and action. It observes the
      stale old endpoint and the fresh child state.
    - [qcheck_source_spec_identity] generates spec changes. It observes cutoff
      direction, retained published baselines, and exact producer incarnations.
    - [qcheck_source_latest_mapper] generates mapper replacements. It observes
      the mapper used for the next source item.
    - [qcheck_source_terminal_outcome] generates completion or failure. It
      observes one terminal action, one producer, and final idleness.
    - [qcheck_transition_snapshot] generates bounded transition values. It
      observes apply arguments, output, and post-commit effect eligibility.
    - [qcheck_one_event_advancement] generates nonempty action lists and stop
      priority. It observes each prefix or zero transition calls.
    - [qcheck_projection_image_per_commit] generates action lists with an equal
      model action. It observes exact output count and values.
    - [qcheck_lifecycle_once_per_interval] generates active-state changes. It
      observes lifecycle starts for each structural interval.
    - [qcheck_ingress_fifo_admission] generates three actions. It observes the
      waiting sender, nonblocking overflow, and FIFO model order.
    - [qcheck_capacity_bounds] generates capacities and values. It observes all
      admissions, one overflow, and the drained model.
    - [qcheck_endpoint_contramap] generates bounded action lists. It observes the
      final model after contramapped admission.
    - [qcheck_bind_child_identity] generates selection and action commands. It
      observes retained state within each selected interval.
    - [qcheck_active_disposed_states] generates child actions across selection
      changes. It observes stale endpoints and fresh reentry state.
    - [qcheck_committed_dependencies_only] generates successful and failed
      replacements. It observes [map], [both], and [bind] deliveries.
    - [qcheck_post_commit_fence] generates bounded action lists. It observes the
      advancement fence before each post-commit start.
    - [qcheck_assoc_rollback] generates a retained child and a failing child. It
      observes retained and provisional export states after rollback.
    - [qcheck_assoc_lifecycle_order] generates removal and addition counts. It
      observes revoked old exports and active new exports.
    - [qcheck_cause_classification] generates fatal and interrupted work. It
      observes crash settlement or stop settlement.
    - [qcheck_export_generation] generates one payload across removal and
      reentry. It observes retained, revoked, and fresh export identities.
    - [qcheck_export_rebinding] generates two payloads. It observes stable export
      identity, target selection, and zero local codec calls.
    - [qcheck_request_first_resolution] generates one request value. It observes
      the first response and the second-resolution rejection.
    - [qcheck_request_capacity] generates request capacities. It observes the
      admitted bound, slot reuse, and all request completions.
    - [qcheck_driver_one_advancement] generates one stale child action. It
      observes one structural delivery, one rejection, and no extra commit.
    - [qcheck_delivery_token] generates one output value. It observes the
      delivery fence, lifecycle start, and one-shot completion.
    - [qcheck_request_closure_reasons] generates owner, stop, and crash closure
      cases. It observes the exact cancellation reason.
    - [qcheck_wire_sequence] generates frame-family rotations. It observes nine
      accepted sequences, one gap rejection, and session closure.
    - [qcheck_exact_envelope_grammars] generates malformed JSON and
      S-expression cases. It observes decoder rejection.
    - [qcheck_wire_reply_correlation] generates exact, unknown, and wrong-family
      replies. It observes acceptance or the exact protocol error.
    - [qcheck_malformed_frame_isolation] generates three malformed-frame cases.
      It observes session rejection and unchanged application state.
    - [qcheck_wire_closed_outcomes] generates four invalid remote identities. It
      observes one typed result while the session stays open.
    - [qcheck_wire_bounds] generates frame, handle, request, and output sizes. It
      observes each documented size boundary.
    - [qcheck_wire_redaction] generates local diagnostics, models, and actions.
      It observes the exact public result and absence of private text.
    - [qcheck_bounded_drain] generates positive step limits. It observes the
      exact limit status and subsequent handle usability.
    - [qcheck_controlled_dependencies] generates bounded integer lists. It
      observes FIFO order, one-shot states, committed output, and cancellation. *)

let qcheck_description_identity =
  QCheck.Test.make ~name:"qcheck_description_identity"
    ~count:200
    (QCheck.make ~print:QCheck.Print.(list int) small_actions)
    (fun actions ->
      let transitions = ref 0 in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            incr transitions;
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (Crux.both machine machine)
      in
      let initial_output, initial_post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let (_, endpoint), _ = initial_output in
      start initial_post_commit;
      let final_left, final_right =
        List.fold_left
          (fun _ action ->
            send endpoint action;
            let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
            start post_commit;
            output)
          initial_output actions
      in
      let left_model, _ = final_left in
      let right_model, _ = final_right in
      left_model = List.fold_left ( + ) 0 actions
      && right_model = left_model
      && !transitions = List.length actions)

let qcheck_cutoff_boundary =
  QCheck.Test.make ~name:"qcheck_cutoff_boundary"
    ~count:200
    (QCheck.make ~print:QCheck.Print.(list int) small_actions)
    (fun actions ->
      let actions = 1 :: -1 :: 0 :: actions in
      let equal_projections = ref 0 in
      let compare_projections = ref 0 in
      let always_projections = ref 0 in
      let never_projections = ref 0 in
      let physical_projections = ref 0 in
      let asymmetric_projections = ref 0 in
      let machine =
        Crux.State_machine.create
          ~model_cutoff:Crux.Cutoff.never
          (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let model = Crux.map machine ~f:fst in
      let project cutoff projections =
        Crux.cutoff model ~cutoff
        |> Crux.map ~f:(fun value ->
               incr projections;
               value)
      in
      let equal =
        project
          (Crux.Cutoff.of_equal (fun left right ->
               left mod 2 = right mod 2))
          equal_projections
      in
      let compare =
        project
          (Crux.Cutoff.of_compare (fun left right ->
               Int.compare (left mod 2) (right mod 2)))
          compare_projections
      in
      let always = project Crux.Cutoff.always always_projections in
      let never = project Crux.Cutoff.never never_projections in
      let physical = project Crux.Cutoff.phys_equal physical_projections in
      let asymmetric =
        project
          (Crux.Cutoff.of_equal (fun published candidate ->
               candidate = published + 1))
          asymmetric_projections
      in
      let probes =
        Crux.both equal
          (Crux.both compare (Crux.both always (Crux.both never physical)))
      in
      let structural =
        Crux.bind (Crux.map model ~f:(fun value -> value mod 2))
          ~f:(fun parity ->
            Crux.both (Crux.return parity)
              (Crux.lifecycle (Crux.return Eta.Effect.unit))
            |> Crux.map ~f:fst)
        |> Crux.cutoff ~cutoff:Crux.Cutoff.always
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (Crux.map
             (Crux.both machine
                (Crux.both probes (Crux.both asymmetric structural)))
             ~f:(fun (machine, (_, (asymmetric, structural))) ->
               (machine, asymmetric, structural)))
      in
      let initial_output, initial_post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let (initial_model, endpoint), initial_asymmetric, initial_structural =
        initial_output
      in
      start initial_post_commit;
      let final_model, parity_changes, physical_changes, asymmetric_changes, _ =
        List.fold_left
          (fun
            ( model,
              parity_changes,
              physical_changes,
              asymmetric_changes,
              asymmetric_published )
            action ->
            send endpoint action;
            let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
            start post_commit;
            let (new_model, _), observed_asymmetric, observed_structural =
              output
            in
            let suppress_asymmetric =
              new_model = asymmetric_published + 1
            in
            let expected_asymmetric =
              if suppress_asymmetric then asymmetric_published else new_model
            in
            if
              observed_asymmetric <> expected_asymmetric
              || observed_structural <> initial_structural
            then
              QCheck.Test.fail_reportf
                "candidate=%d asymmetric=%d/%d structural=%d/%d"
                new_model observed_asymmetric expected_asymmetric
                observed_structural initial_structural;
            ( new_model,
              parity_changes
              + Bool.to_int (model mod 2 <> new_model mod 2),
              physical_changes + Bool.to_int (model != new_model),
              asymmetric_changes + Bool.to_int (not suppress_asymmetric),
              expected_asymmetric ))
          (initial_model, 0, 0, 0, initial_asymmetric)
          actions
      in
      let expected_model = List.fold_left ( + ) 0 actions in
      let expected_parity = parity_changes + 1 in
      let expected_never = List.length actions + 1 in
      let expected_physical = physical_changes + 1 in
      if
        final_model <> expected_model
        || !equal_projections <> expected_parity
        || !compare_projections <> expected_parity
        || !always_projections <> 1
        || !never_projections <> expected_never
        || !physical_projections <> expected_physical
        || !asymmetric_projections <> asymmetric_changes + 1
      then
        QCheck.Test.fail_reportf
          "model=%d/%d equal=%d/%d compare=%d/%d always=%d/1 never=%d/%d physical=%d/%d asymmetric=%d/%d"
          final_model expected_model
          !equal_projections expected_parity
          !compare_projections expected_parity
          !always_projections !never_projections expected_never
          !physical_projections expected_physical
          !asymmetric_projections (asymmetric_changes + 1);
      stop_root root;
      let ref_physical = ref 0 in
      let ref_structural = ref 0 in
      let ref_machine =
        Crux.State_machine.create
          ~model_cutoff:Crux.Cutoff.never
          (Crux.return ()) ~default_model:(ref 0)
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            ((if action = 0 then model else ref !model), None))
      in
      let ref_model = Crux.map ref_machine ~f:fst in
      let count cutoff counter =
        Crux.cutoff ref_model ~cutoff
        |> Crux.map ~f:(fun value ->
               incr counter;
               value)
      in
      let ref_root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (Crux.map
             (Crux.both ref_machine
                (Crux.both
                   (count Crux.Cutoff.phys_equal ref_physical)
                   (count
                      (Crux.Cutoff.of_equal (fun left right ->
                           !left = !right))
                      ref_structural)))
             ~f:fst)
      in
      let (_, ref_endpoint), ref_post =
        committed (run_ok (Crux.Root.advance ref_root))
      in
      start ref_post;
      List.iter
        (fun action ->
          send ref_endpoint action;
          let _, post = committed (run_ok (Crux.Root.advance ref_root)) in
          start post)
        actions;
      let fresh_refs =
        List.fold_left
          (fun count action -> count + Bool.to_int (action <> 0))
          0 actions
      in
      if
        !ref_physical <> fresh_refs + 1
        || !ref_structural <> 1
      then
        QCheck.Test.fail_reportf
          "reference physical=%d/%d structural=%d/1"
          !ref_physical (fresh_refs + 1) !ref_structural;
      stop_root ref_root;
      true)

let assoc_description
    ?(data_cutoff = Crux.Cutoff.of_equal Int.equal)
    ?builds initial =
  let parent =
    Crux.State_machine.create (Crux.return ()) ~default_model:initial
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let children =
    let module Assoc = Crux.Assoc (Int) in
    Assoc.assoc (Crux.map parent ~f:fst)
      ~data_cutoff
      ~f:(fun ~key:_ ~data ->
        Option.iter incr builds;
        let machine =
          Crux.State_machine.create data ~default_model:0
            ~apply_action:(fun ~self:_ ~input:_ ~model ~action ->
              (model + action, None))
        in
        Crux.map (Crux.both data machine)
          ~f:(fun (current_data, (model, endpoint)) ->
            (current_data, model, endpoint)))
  in
  Crux.both parent children

let qcheck_assoc_key_order =
  let input =
    let open QCheck.Gen in
    list_size (0 -- 32) (pair (-20 -- 20) (-100 -- 100))
  in
  QCheck.Test.make ~name:"qcheck_assoc_key_order" ~count:200
    (QCheck.make
       ~print:QCheck.Print.(list (pair int int))
       input)
    (fun bindings ->
      let input =
        List.fold_left
          (fun map (key, value) -> Int_map.set key value map)
          Int_map.empty bindings
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:8 ~request_capacity:1
          (assoc_description input)
      in
      let ((_parent, children), post_commit) =
        committed (run_ok (Crux.Root.advance root))
      in
      start post_commit;
      List.map (fun (key, (data, _, _)) -> (key, data))
        (Int_map.to_list children)
      = Int_map.to_list input)

let assoc_sample =
  let open QCheck.Gen in
  QCheck.make
    ~print:(fun (key, first, second, delta) ->
      Printf.sprintf "{key=%d; first=%d; second=%d; delta=%d}" key first
        second delta)
    (quad (-20 -- 20) (-100 -- 100) (-100 -- 100) (-10 -- 10))

let qcheck_assoc_continuous_presence =
  QCheck.Test.make ~name:"qcheck_assoc_continuous_presence" ~count:200
    assoc_sample
    (fun (key, data, _, delta) ->
      let initial = Int_map.singleton key data in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:8 ~request_capacity:1
          (assoc_description initial)
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, retained_endpoint = int_map_find key children in
      send parent_endpoint (Int_map.set (key + 1) 17 initial);
      let _, update_post = committed (run_ok (Crux.Root.advance root)) in
      start update_post;
      send retained_endpoint delta;
      let ((_, children), child_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start child_post;
      let _, model, _ = int_map_find key children in
      model = delta)

let qcheck_assoc_data_update =
  QCheck.Test.make ~name:"qcheck_assoc_data_update" ~count:200 assoc_sample
    (fun (key, first, _second, delta) ->
      let builds = ref 0 in
      let data_cutoff =
        Crux.Cutoff.of_equal (fun published candidate ->
            candidate = published + 1)
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:8 ~request_capacity:1
          (assoc_description ~data_cutoff ~builds
             (Int_map.singleton key first))
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, child_endpoint = int_map_find key children in
      send child_endpoint delta;
      let _, child_post = committed (run_ok (Crux.Root.advance root)) in
      start child_post;
      send parent_endpoint (Int_map.singleton key (first + 1));
      let ((_, suppressed_children), suppressed_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start suppressed_post;
      let suppressed_data, suppressed_model, suppressed_endpoint =
        int_map_find key suppressed_children
      in
      send parent_endpoint (Int_map.singleton key (first + 2));
      let ((_, accepted_children), accepted_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start accepted_post;
      let accepted_data, accepted_model, accepted_endpoint =
        int_map_find key accepted_children
      in
      let result =
        suppressed_data = first
        && suppressed_model = delta
        && suppressed_endpoint == child_endpoint
        && accepted_data = first + 2
        && accepted_model = delta
        && accepted_endpoint == child_endpoint
        && !builds = 1
      in
      stop_root root;
      result)

let qcheck_assoc_remove_reenter =
  QCheck.Test.make ~name:"qcheck_assoc_remove_reenter" ~count:200 assoc_sample
    (fun (key, data, _, delta) ->
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:8 ~request_capacity:1
          (assoc_description (Int_map.singleton key data))
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, old_endpoint = int_map_find key children in
      send parent_endpoint Int_map.empty;
      let _, remove_post = committed (run_ok (Crux.Root.advance root)) in
      start remove_post;
      send old_endpoint delta;
      let stale =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> true
        | _ -> false
      in
      send parent_endpoint (Int_map.singleton key data);
      let ((_, children), reenter_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start reenter_post;
      let _, _, new_endpoint = int_map_find key children in
      send new_endpoint delta;
      let ((_, children), child_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start child_post;
      let _, model, _ = int_map_find key children in
      stale && model = delta)

type source_command =
  | Emit of int
  | Complete
  | Fail of string

type source_observation =
  | Item of int
  | Completed
  | Failed of string

type source_output =
  ((int * int) * (int * int) Crux.Endpoint.t)
  * ((source_observation list * source_observation Crux.Endpoint.t) * unit)

type source_harness = {
  root : Crux.Root.t;
  commands : (source_command, Crux.never) Eta.Queue.t;
  openings : int ref;
  opened_specs : int list ref;
  mapped_multipliers : int list ref;
  config_endpoint : (int * int) Crux.Endpoint.t;
}

let make_source_harness
    ?(spec_cutoff = Crux.Cutoff.of_equal Int.equal)
    ?fail_mapper
    ~spec ~mapper () =
  let commands = Eta.Queue.unbounded () in
  let openings = ref 0 in
  let opened_specs = ref [] in
  let mapped_multipliers = ref [] in
  let rec running ~emit =
    let open Eta.Syntax in
    let* command =
      Eta.Queue.take commands
      |> Eta.Effect.or_die (function
           | `Closed -> Failure "source command queue closed"
           | `Closed_with_error (_ : Crux.never) -> .)
    in
    match command with
    | Emit item ->
        let* () =
          emit item
          |> Eta.Effect.or_die (function
               | Crux.Endpoint.Ingress_closed ->
                   Failure "source target ingress closed")
        in
        running ~emit
    | Complete -> Eta.Effect.unit
    | Fail message -> Eta.Effect.fail message
  in
  let producer spec ~emit =
    let open Eta.Syntax in
    let* () =
      Eta.Effect.sync (fun () ->
          incr openings;
          opened_specs := !opened_specs @ [ spec ])
    in
    Eta.Effect.pure (running ~emit)
  in
  let config =
    Crux.State_machine.create (Crux.return ())
      ~default_model:(spec, mapper)
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let sink =
    Crux.State_machine.create (Crux.return ()) ~default_model:[]
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model @ [ action ], None))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff
      ~spec:(Crux.map config ~f:(fun ((spec, _), _) -> spec))
      ~producer:(Crux.return producer)
      ~target:(Crux.map sink ~f:snd)
      ~on_item:
        (Crux.map config ~f:(fun ((_, mapper), _) item ->
             mapped_multipliers := !mapped_multipliers @ [ mapper ];
             Item (item * mapper)))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> Completed
          | Crux.Source.Failed message -> Failed message))
  in
  let source =
    match fail_mapper with
    | None -> source
    | Some fail_mapper ->
        Crux.map
          (Crux.both source
             (Crux.map config ~f:(fun ((_, mapper), _) -> mapper)))
          ~f:(fun ((), mapper) ->
            if mapper = fail_mapper then
              failwith "source mapper rollback probe";
            ())
  in
  let root =
    Projection.root ~projection_capacity:1 ~ingress_capacity:16 ~request_capacity:1
      (Crux.both config (Crux.both sink source))
  in
  let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
  start post_commit;
  let ((_, config_endpoint), _) = output in
  {
    root;
    commands;
    openings;
    opened_specs;
    mapped_multipliers;
    config_endpoint;
  }

let source_send_command harness command =
  run_ok
    (Eta.Queue.send harness.commands command
    |> Eta.Effect.or_die (function
         | `Closed -> Failure "source command queue closed"
         | `Dropped -> Failure "unbounded source command queue dropped"
         | `Closed_with_error (_ : Crux.never) -> .))

let rec await_source_commit harness attempts =
  if attempts = 0 then failwith "source action did not reach ingress"
  else
    match run_ok (Crux.Root.advance harness.root) with
    | Ok (Crux.Root.Committed { commit; post_commit }) ->
        let output = output_of_commit commit in
        start post_commit;
        output
    | Ok Crux.Root.Idle ->
        Eio.Fiber.yield ();
        await_source_commit harness (attempts - 1)
    | Ok (Crux.Root.Rejected _) ->
        await_source_commit harness (attempts - 1)
    | Ok (Crux.Root.Stopped _) | Ok (Crux.Root.Failed _) | Error _ ->
        failwith "source root terminated while awaiting output"

let source_update_config harness value =
  send harness.config_endpoint value;
  let output, post_commit = committed (run_ok (Crux.Root.advance harness.root)) in
  start post_commit;
  output

let stop_source_harness harness =
  Crux.Root.request_stop harness.root;
  match run_ok (Crux.Root.advance harness.root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start post_commit
  | _ -> failwith "source root did not stop"

let qcheck_source_spec_identity =
  let specs =
    let open QCheck.Gen in
    list_size (0 -- 20) (0 -- 4)
  in
  QCheck.Test.make ~name:"qcheck_source_spec_identity" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) specs)
    (fun specs ->
      let specs = 1 :: 2 :: specs in
      let spec_cutoff =
        Crux.Cutoff.of_equal (fun published candidate ->
            candidate = published + 1)
      in
      let harness =
        make_source_harness ~spec_cutoff ~spec:0 ~mapper:1 ()
      in
      let _, expected_specs =
        List.fold_left
          (fun (published, expected_specs) spec ->
            ignore (source_update_config harness (spec, 1));
            if spec = published + 1 then (published, expected_specs)
            else (spec, expected_specs @ [ spec ]))
          (0, [ 0 ]) specs
      in
      let observed = !(harness.openings) in
      let observed_specs = !(harness.opened_specs) in
      stop_source_harness harness;
      observed = List.length expected_specs
      && observed_specs = expected_specs)

let source_sample =
  let open QCheck.Gen in
  QCheck.make
    ~print:(fun (mapper, item) ->
      Printf.sprintf "{mapper=%d; item=%d}" mapper item)
    (pair (-10 -- 10) (-100 -- 100))

let qcheck_source_latest_mapper =
  QCheck.Test.make ~name:"qcheck_source_latest_mapper" ~count:100
    source_sample
    (fun (mapper, item) ->
      let harness = make_source_harness ~spec:0 ~mapper:1 () in
      ignore (source_update_config harness (0, mapper));
      source_send_command harness (Emit item);
      let _, ((observations, _), _) = await_source_commit harness 100 in
      let openings = !(harness.openings) in
      stop_source_harness harness;
      let committed_result =
        observations = [ Item (item * mapper) ]
        && openings = 1
        && !(harness.mapped_multipliers) = [ mapper ]
      in
      let failing_mapper = if mapper = 1 then 2 else mapper in
      let rollback =
        make_source_harness ~fail_mapper:failing_mapper ~spec:0 ~mapper:1 ()
      in
      send rollback.config_endpoint (0, failing_mapper);
      let crash_post =
        match run_ok (Crux.Root.advance rollback.root) with
        | Ok (Crux.Root.Failed { post_commit; _ }) -> post_commit
        | _ -> failwith "source mapper rollback probe did not fail"
      in
      source_send_command rollback (Emit item);
      let rec await_mapping attempts =
        if !(rollback.mapped_multipliers) <> [] then ()
        else if attempts = 0 then
          failwith "source mapper rollback probe did not emit"
        else (
          Eio.Fiber.yield ();
          await_mapping (attempts - 1))
      in
      await_mapping 100;
      let rollback_result =
        !(rollback.mapped_multipliers) = [ 1 ]
      in
      start crash_post;
      committed_result && rollback_result)

let qcheck_source_terminal_outcome =
  QCheck.Test.make ~name:"qcheck_source_terminal_outcome" ~count:100
    QCheck.(pair bool string_small)
    (fun (complete, message) ->
      let harness = make_source_harness ~spec:0 ~mapper:1 () in
      source_send_command harness
        (if complete then Complete else Fail message);
      let _, ((observations, _), _) = await_source_commit harness 100 in
      ignore (source_update_config harness (0, 2));
      let idle =
        match run_ok (Crux.Root.advance harness.root) with
        | Ok Crux.Root.Idle -> true
        | _ -> false
      in
      let openings = !(harness.openings) in
      stop_source_harness harness;
      observations
      = [ if complete then Completed else Failed message ]
      && openings = 1 && idle)

let qcheck_transition_snapshot =
  (* Generated class: bounded initial input/model, committed replacement input,
     and one action. Observation boundary: apply-call arguments/count, committed
     output, and transition-effect eligibility before and after post-commit. *)
  let sample =
    let open QCheck.Gen in
    quad (-20 -- 20) (-20 -- 20) (-20 -- 20) (-10 -- 10)
  in
  QCheck.Test.make ~name:"qcheck_transition_snapshot" ~count:100
    (QCheck.make
       ~print:(fun (initial_input, next_input, initial_model, action) ->
         Printf.sprintf
           "{initial_input=%d; next_input=%d; initial_model=%d; action=%d}"
           initial_input next_input initial_model action)
       sample)
    (fun (initial_input, next_input, initial_model, action) ->
      let calls = ref [] in
      let effect_started = ref false in
      let input =
        Crux.State_machine.create (Crux.return ())
          ~default_model:initial_input
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let machine =
        Crux.State_machine.create (Crux.map input ~f:fst)
          ~default_model:initial_model
          ~apply_action:(fun ~self:_ ~input ~model ~action ->
            calls := (input, model, action) :: !calls;
            ( model + (input * action),
              Some (Eta.Effect.sync (fun () -> effect_started := true)) ))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
          (Crux.both input machine)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let (_, input_endpoint), (_, machine_endpoint) = initial in
      send input_endpoint next_input;
      let _, input_post = committed (run_ok (Crux.Root.advance root)) in
      start input_post;
      send machine_endpoint action;
      let output, action_post = committed (run_ok (Crux.Root.advance root)) in
      let before_post = not !effect_started in
      let (observed_input, _), (observed_model, _) = output in
      start action_post;
      let after_post = !effect_started in
      stop_root root;
      observed_input = next_input
      && observed_model = initial_model + (next_input * action)
      && List.rev !calls = [ (next_input, initial_model, action) ]
      && before_post && after_post)

let qcheck_one_event_advancement =
  (* Generated class: a nonempty FIFO action list and both control-priority
     choices. Observation boundary: apply-call count and every prefix output, or
     zero application calls when stop wins before the first queued action. *)
  let sample =
    let open QCheck.Gen in
    pair bool (list_size (1 -- 12) (-9 -- 9))
  in
  QCheck.Test.make ~name:"qcheck_one_event_advancement" ~count:100
    (QCheck.make
       ~print:(fun (stop_first, actions) ->
         Printf.sprintf "{stop_first=%b; actions=%s}" stop_first
           (QCheck.Print.(list int) actions))
       sample)
    (fun (stop_first, actions) ->
      let calls = ref 0 in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            incr calls;
            ((model * 31) + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:12 ~request_capacity:1 machine
      in
      let (_, endpoint), initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      List.iter (send endpoint) actions;
      if stop_first then (
        Crux.Root.request_stop root;
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Stopped { post_commit }) ->
            start post_commit;
            !calls = 0 && run_ok (Crux.Root.advance root) = Error Crux.Root.Closed
        | _ -> false)
      else
        let expected = ref 0 in
        let one_per_step =
          List.mapi
            (fun index action ->
              expected := (!expected * 31) + action;
              let (model, _), post_commit =
                committed (run_ok (Crux.Root.advance root))
              in
              let before_next = !calls = index + 1 in
              start post_commit;
              before_next && model = !expected)
            actions
          |> List.for_all Fun.id
        in
        let idle = run_ok (Crux.Root.advance root) = Ok Crux.Root.Idle in
        stop_root root;
        one_per_step && !calls = List.length actions && idle)

let qcheck_projection_image_per_commit =
  (* Generated class: nonempty bounded action lists forced to contain an
     equal-model action. Observation boundary: exact committed-output
     cardinality and value sequence, including the unchanged first output. *)
  let sample =
    let open QCheck.Gen in
    map (fun rest -> 0 :: rest) (list_size (0 -- 11) (-2 -- 2))
  in
  QCheck.Test.make ~name:"qcheck_projection_image_per_commit" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) sample)
    (fun actions ->
      let calls = ref 0 in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            incr calls;
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:12 ~request_capacity:1 machine
      in
      let (_, endpoint), initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      List.iter (send endpoint) actions;
      let outputs =
        List.map
          (fun _ ->
            let (model, _), post_commit =
              committed (run_ok (Crux.Root.advance root))
            in
            start post_commit;
            model)
          actions
      in
      let expected =
        actions
        |> List.fold_left
             (fun (model, outputs) action ->
               let model = model + action in
               (model, model :: outputs))
             (0, [])
        |> snd |> List.rev
      in
      stop_root root;
      !calls = List.length actions && outputs = expected
      && List.hd outputs = 0)

let qcheck_lifecycle_once_per_interval =
  let values =
    let open QCheck.Gen in
    list_size (0 -- 20) bool
  in
  QCheck.Test.make ~name:"qcheck_lifecycle_once_per_interval" ~count:100
    (QCheck.make ~print:QCheck.Print.(list bool) values)
    (fun values ->
      let starts = ref 0 in
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let lifecycle =
        Crux.lifecycle
          (Crux.return (Eta.Effect.sync (fun () -> incr starts)))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun active ->
            if active then lifecycle else Crux.return ())
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (Crux.both selector selected)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let (_, endpoint), _ = initial in
      List.iter
        (fun active ->
          send endpoint active;
          let _, post_commit = committed (run_ok (Crux.Root.advance root)) in
          start post_commit)
        values;
      let _, expected =
        List.fold_left
          (fun (previous, count) active ->
            (active, count + Bool.to_int ((not previous) && active)))
          (true, 1) values
      in
      let rec await_starts attempts =
        if !starts = expected then ()
        else if attempts = 0 then
          failwith
            (Printf.sprintf "expected %d lifecycle starts, observed %d"
               expected !starts)
        else (
          Eio.Fiber.yield ();
          await_starts (attempts - 1))
      in
      await_starts 100;
      Crux.Root.request_stop root;
      (match run_ok (Crux.Root.advance root) with
      | Ok (Crux.Root.Stopped { post_commit }) -> start post_commit
      | _ -> failwith "lifecycle root did not stop");
      !starts = expected)

let int_codec =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
    ~decode:(fun bytes ->
      match int_of_string_opt (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "expected an integer" })

let exported_counter ~capacity =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let export =
    Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
      ~codec:int_codec
  in
  let root =
    Projection.root ~projection_capacity:1 ~ingress_capacity:capacity ~request_capacity:1
      (Crux.both machine export)
  in
  let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
  start post_commit;
  (root, output)

let qcheck_ingress_fifo_admission =
  let sample =
    let open QCheck.Gen in
    triple (-100 -- 100) (-100 -- 100) (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_ingress_fifo_admission" ~count:100
    (QCheck.make
       ~print:(fun (first, waiter, nonblocking) ->
         Printf.sprintf "{first=%d; waiter=%d; nonblocking=%d}" first waiter
           nonblocking)
       sample)
    (fun (first, waiter, nonblocking) ->
      let root, ((_, endpoint), export) = exported_counter ~capacity:1 in
      send endpoint first;
      let waiter_entered = Eta.Promise.create () in
      let waiting_send =
        let open Eta.Syntax in
        let* _ = Eta.Promise.resolve waiter_entered (Eta.Exit.Ok ()) in
        Crux.Endpoint.send endpoint waiter
        |> Eta.Effect.or_die (function
             | Crux.Endpoint.Ingress_closed -> Failure "ingress closed")
      in
      let observe =
        let open Eta.Syntax in
        let* () = Eta.Promise.await waiter_entered in
        let* () = Eta.Effect.yield in
        let* nonblocking_result =
          Eta.Effect.sync (fun () ->
              Crux.Exported_endpoint.try_invoke export nonblocking)
        in
        let* first_model, post_commit =
          Eta.Effect.sync (fun () ->
              match run_ok (Crux.Root.advance root) with
                | Ok (Crux.Root.Committed { commit; post_commit }) ->
                    let ((model, _), _) = output_of_commit commit in
                  (model, post_commit)
              | _ -> failwith "first queued action did not commit")
        in
        let* _ =
          Crux.Post_commit.start post_commit
          |> Eta.Effect.or_die (function
               | Crux.Post_commit.Already_started ->
                   Failure "post-commit token started twice")
        in
        Eta.Effect.pure (nonblocking_result, first_model)
      in
      let _, (nonblocking_result, first_model) =
        run_ok (Eta.Effect.par waiting_send observe)
      in
      let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
      start post_commit;
      let (second_model, _), _ = output in
      stop_root root;
      nonblocking_result = Ok (Error Crux.Exported_endpoint.Full)
      && first_model = first
      && second_model = first + waiter)

let qcheck_capacity_bounds =
  let sample =
    let open QCheck.Gen in
    pair (1 -- 12) (list_size (1 -- 12) (-20 -- 20))
  in
  QCheck.Test.make ~name:"qcheck_capacity_bounds" ~count:100
    (QCheck.make
       ~print:(fun (capacity, values) ->
         Printf.sprintf "{capacity=%d; values=%s}" capacity
           (QCheck.Print.list QCheck.Print.int values))
       sample)
    (fun (capacity, generated) ->
      let values =
        List.init capacity (fun index ->
            List.nth generated (index mod List.length generated))
      in
      let root, ((_model, _endpoint), export) =
        exported_counter ~capacity
      in
      let admissions =
        List.map
          (fun value -> Crux.Exported_endpoint.try_invoke export value)
          values
      in
      let overflow = Crux.Exported_endpoint.try_invoke export 999 in
      let final_model =
        List.fold_left
          (fun _ _ ->
            let output, post_commit =
              committed (run_ok (Crux.Root.advance root))
            in
            start post_commit;
            let (model, _), _ = output in
            model)
          0 values
      in
      stop_root root;
      List.for_all
        (fun result -> result = Ok (Ok (Ok ())))
        admissions
      && overflow = Ok (Error Crux.Exported_endpoint.Full)
      && final_model = List.fold_left ( + ) 0 values)

let qcheck_endpoint_contramap =
  let values =
    let open QCheck.Gen in
    list_size (0 -- 20) (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_endpoint_contramap" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) values)
    (fun values ->
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1 machine
      in
      let (initial_model, endpoint), initial_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start initial_post;
      let contramapped =
        Crux.Endpoint.contramap endpoint ~f:(fun (value, ignored) ->
            value + ignored - ignored)
      in
      let final_model =
        List.fold_left
          (fun _ value ->
            send contramapped (value, 17);
            let (model, _), post_commit =
              committed (run_ok (Crux.Root.advance root))
            in
            start post_commit;
            model)
          initial_model values
      in
      stop_root root;
      final_model = List.fold_left ( + ) 0 values)

let bind_description () =
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let child default_model =
    Crux.State_machine.create (Crux.return ()) ~default_model
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let present = child 10 in
  let absent = child 20 in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun value ->
        if value then present else absent)
  in
  Crux.both selector selected

let bind_commands =
  let open QCheck.Gen in
  list_size (0 -- 20) (pair bool (-10 -- 10))

let print_bind_commands =
  QCheck.Print.list (fun (switch, value) ->
      Printf.sprintf "%s(%d)" (if switch then "select" else "apply") value)

let qcheck_bind_child_identity =
  QCheck.Test.make ~name:"qcheck_bind_child_identity" ~count:100
    (QCheck.make ~print:print_bind_commands bind_commands)
    (fun commands ->
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (bind_description ())
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, selector_endpoint), (_, initial_child_endpoint)) = initial in
      let selected = ref true in
      let expected_model = ref 10 in
      let child_endpoint = ref initial_child_endpoint in
      List.iter
        (fun (switch, value) ->
          if switch then (
            let next_selected = value mod 2 = 0 in
            send selector_endpoint next_selected;
            let output, post_commit =
              committed (run_ok (Crux.Root.advance root))
            in
            start post_commit;
            let _, (model, endpoint) = output in
            if next_selected <> !selected then
              expected_model := if next_selected then 10 else 20;
            selected := next_selected;
            child_endpoint := endpoint;
            if model <> !expected_model then
              failwith "bind changed or retained the wrong child model")
          else (
            send !child_endpoint value;
            let output, post_commit =
              committed (run_ok (Crux.Root.advance root))
            in
            start post_commit;
            expected_model := !expected_model + value;
            let _, (model, endpoint) = output in
            child_endpoint := endpoint;
            if model <> !expected_model then
              failwith "bind child lost continuous model state"))
        commands;
      stop_root root;
      true)

let qcheck_active_disposed_states =
  let deltas =
    let open QCheck.Gen in
    list_size (0 -- 10) (-10 -- 10)
  in
  QCheck.Test.make ~name:"qcheck_active_disposed_states" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) deltas)
    (fun deltas ->
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1
          (bind_description ())
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, selector_endpoint), (_, initial_endpoint)) = initial in
      let selected = ref true in
      let endpoint = ref initial_endpoint in
      List.iter
        (fun delta ->
          let old_endpoint = !endpoint in
          selected := not !selected;
          send selector_endpoint !selected;
          let output, post_commit =
            committed (run_ok (Crux.Root.advance root))
          in
          start post_commit;
          let _, (_, fresh_endpoint) = output in
          endpoint := fresh_endpoint;
          send old_endpoint delta;
          (match run_ok (Crux.Root.advance root) with
          | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> ()
          | _ -> failwith "disposed bind endpoint remained active");
          send fresh_endpoint delta;
          let output, post_commit =
            committed (run_ok (Crux.Root.advance root))
          in
          start post_commit;
          let _, (model, _) = output in
          let default_model = if !selected then 10 else 20 in
          if model <> default_model + delta then
            failwith "re-entered bind child did not have fresh state")
        deltas;
      stop_root root;
      true)

let qcheck_committed_dependencies_only =
  (* Generated class: bounded committed replacements and both stabilization
     outcomes. Observation boundary: [map]/[both]/[bind] deliveries and absence
     of delivery after the failing stabilization. *)
  let sample =
    let open QCheck.Gen in
    map
      (fun (initial, delta) ->
        (initial, initial + delta))
      (pair (-20 -- 20)
         (oneof [ -20 -- -1; 1 -- 20 ]))
  in
  QCheck.Test.make ~name:"qcheck_committed_dependencies_only" ~count:100
    (QCheck.make
       ~print:(fun (initial, replacement) ->
         Printf.sprintf
           "{initial=%d; replacement=%d}"
           initial replacement)
       sample)
    (fun (initial, replacement) ->
      let observe fail =
        let fail_on_replacement = ref false in
        let input =
          Crux.State_machine.create (Crux.return ())
            ~default_model:initial
            ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
              (action, None))
        in
        let mapped = Crux.map input ~f:fst in
        let bound =
          Crux.bind mapped ~f:(fun value ->
              Crux.return (value * 2))
        in
        let checked =
          Crux.map mapped ~f:(fun value ->
              if !fail_on_replacement then
                raise
                  (Failure
                     "generated failed stabilization");
              value)
        in
        let description =
          Crux.both input
            (Crux.both (Crux.both mapped bound) checked)
        in
        let root =
          Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
            description
        in
        let driver =
          Crux.Driver.create (Crux.Driver.Binding.identity []) root
        in
        let initial_delivery =
          match run_ok (Crux.Driver.poll driver) with
          | Some (Crux.Driver.Deliver delivery) -> delivery
          | Some _ | None ->
              failwith "dependency root did not deliver initial output"
        in
        let (initial_model, endpoint),
            ((initial_mapped, initial_bound), initial_checked) =
          output_of_delivery initial_delivery
        in
        ignore
          (run_ok
             (Crux.Driver.Delivery.delivered initial_delivery));
        fail_on_replacement := fail;
        send endpoint replacement;
        let replacement_observed =
          match run_ok (Crux.Driver.poll driver), fail with
          | Some (Crux.Driver.Deliver delivery), false ->
              let
                (model, _),
                ((mapped, bound), checked)
              =
                output_of_delivery delivery
              in
              ignore
                (run_ok
                   (Crux.Driver.Delivery.delivered delivery));
              model = replacement && mapped = replacement
              && bound = replacement * 2
              && checked = replacement
          | Some (Crux.Driver.Crash_detected _), true -> (
              match run_ok (Crux.Driver.poll driver) with
              | Some
                  (Crux.Driver.Closed
                    (Crux.Driver.Crashed
                      { teardown_settled = true; _ })) ->
                  true
              | Some _ | None -> false)
          | (Some _ | None), _ -> false
        in
        if not fail then (
          Crux.Driver.request_stop driver;
          match run_ok (Crux.Driver.poll driver) with
          | Some (Crux.Driver.Closed Crux.Driver.Stopped) ->
              ()
          | Some _ | None ->
              failwith "dependency root did not stop");
        initial_model = initial
        && initial_mapped = initial
        && initial_bound = initial * 2
        && initial_checked = initial
        && replacement_observed
      in
      observe false && observe true)

let qcheck_post_commit_fence =
  let actions =
    let open QCheck.Gen in
    list_size (0 -- 20) (-10 -- 10)
  in
  QCheck.Test.make ~name:"qcheck_post_commit_fence" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) actions)
    (fun actions ->
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:32 ~request_capacity:1 machine
      in
      let (_, endpoint), initial_post =
        committed (run_ok (Crux.Root.advance root))
      in
      let initial_fenced =
        run_ok (Crux.Root.advance root) = Error Crux.Root.Awaiting_post_commit
      in
      start initial_post;
      let all_fenced =
        List.for_all
          (fun action ->
            send endpoint action;
            let _, post_commit = committed (run_ok (Crux.Root.advance root)) in
            let fenced =
              run_ok (Crux.Root.advance root)
              = Error Crux.Root.Awaiting_post_commit
            in
            start post_commit;
            fenced)
          actions
      in
      stop_root root;
      initial_fenced && all_fenced)

let qcheck_assoc_rollback =
  let sample =
    let open QCheck.Gen in
    pair (-100 -- 99) (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_assoc_rollback" ~count:100
    (QCheck.make
       ~print:(fun (key, data) ->
         Printf.sprintf "{retained_key=%d; data=%d}" key data)
       sample)
    (fun (retained_key, data) ->
      let failing_key = retained_key + 1 in
      let provisional = ref None in
      let parent =
        Crux.State_machine.create (Crux.return ())
          ~default_model:(Int_map.singleton retained_key data)
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let module Assoc = Crux.Assoc (Int) in
      let children =
        Assoc.assoc (Crux.map parent ~f:fst)
          ~f:(fun ~key ~data:_ ->
            let child =
              Crux.State_machine.create (Crux.return ()) ~default_model:0
                ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
                  (model + action, None))
            in
            Crux.Exported_endpoint.create (Crux.map child ~f:snd)
              ~codec:int_codec
            |> Crux.map ~f:(fun export ->
                   if key = failing_key then (
                     provisional := Some export;
                     raise Exit);
                   export))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
          (Crux.both parent children)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, parent_endpoint), initial_children) = initial in
      let retained = int_map_find retained_key initial_children in
      send parent_endpoint
        (Int_map.set failing_key (data + 1)
           (Int_map.singleton retained_key data));
      let failed_post =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Failed { post_commit; _ }) -> post_commit
        | _ -> failwith "provisional assoc defect did not fail the root"
      in
      let retained_result =
        Crux.Exported_endpoint.try_invoke retained 1
      in
      let provisional_result =
        match !provisional with
        | Some export -> Crux.Exported_endpoint.try_invoke export 1
        | None -> failwith "failing assoc child was not constructed"
      in
      (match run_ok
               (Crux.Post_commit.start failed_post
               |> Eta.Effect.or_die (function
                    | Crux.Post_commit.Already_started ->
                        Failure "post-commit token started twice"))
       with
      | Crux.Post_commit.Crash_settled _ -> ()
      | _ -> failwith "assoc rollback crash did not settle");
      retained_result
      = Ok (Ok (Error Crux.Endpoint.Ingress_closed))
      && provisional_result = Error Crux.Exported_endpoint.Revoked)

let qcheck_assoc_lifecycle_order =
  let counts =
    let open QCheck.Gen in
    pair (1 -- 8) (1 -- 8)
  in
  QCheck.Test.make ~name:"qcheck_assoc_lifecycle_order" ~count:100
    (QCheck.make
       ~print:(fun (removed, added) ->
         Printf.sprintf "{removed=%d; added=%d}" removed added)
       counts)
    (fun (removed_count, added_count) ->
      let map_from start count =
        List.init count (fun offset -> (start + offset, offset))
        |> List.fold_left
             (fun map (key, data) -> Int_map.set key data map)
             Int_map.empty
      in
      let initial_map = map_from 0 removed_count in
      let replacement_map = map_from 100 added_count in
      let parent =
        Crux.State_machine.create (Crux.return ())
          ~default_model:initial_map
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let module Assoc = Crux.Assoc (Int) in
      let children =
        Assoc.assoc (Crux.map parent ~f:fst)
          ~f:(fun ~key:_ ~data:_ ->
            let child =
              Crux.State_machine.create (Crux.return ()) ~default_model:0
                ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
                  (model + action, None))
            in
            Crux.Exported_endpoint.create (Crux.map child ~f:snd)
              ~codec:int_codec)
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:added_count ~request_capacity:1
          (Crux.both parent children)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, parent_endpoint), old_children) = initial in
      send parent_endpoint replacement_map;
      let replacement, replacement_post =
        committed (run_ok (Crux.Root.advance root))
      in
      let _, new_children = replacement in
      let removed_before_added =
        Int_map.to_list old_children
        |> List.for_all (fun (_, export) ->
               Crux.Exported_endpoint.try_invoke export 1
               = Error Crux.Exported_endpoint.Revoked)
      in
      let additions_active =
        Int_map.to_list new_children
        |> List.for_all (fun (_, export) ->
               Crux.Exported_endpoint.try_invoke export 1
               = Ok (Ok (Ok ())))
      in
      Crux.Root.request_stop root;
      (match run_ok
               (Crux.Post_commit.start replacement_post
               |> Eta.Effect.or_die (function
                    | Crux.Post_commit.Already_started ->
                        Failure "post-commit token started twice"))
       with
      | Crux.Post_commit.Stop_settled -> ()
      | _ -> failwith "pending assoc batch did not convert to stop");
      removed_before_added && additions_active)

let qcheck_cause_classification =
  QCheck.Test.make ~name:"qcheck_cause_classification" ~count:100
    QCheck.bool
    (fun fatal ->
      let program =
        if fatal then Eta.Effect.die_message "generated owned defect"
        else Eta.Effect.never
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
          (Crux.lifecycle (Crux.return program))
      in
      let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      if fatal then (
        let rec await_failure attempts =
          if attempts = 0 then failwith "fatal owned cause was not observed"
          else
            match run_ok (Crux.Root.advance root) with
            | Ok (Crux.Root.Failed { post_commit; _ }) -> post_commit
            | Ok Crux.Root.Idle ->
                Eio.Fiber.yield ();
                await_failure (attempts - 1)
            | _ -> failwith "fatal owned cause produced a non-crash outcome"
        in
        let post_commit = await_failure 100 in
        match run_ok
                (Crux.Post_commit.start post_commit
                |> Eta.Effect.or_die (function
                     | Crux.Post_commit.Already_started ->
                         Failure "post-commit token started twice"))
        with
        | Crux.Post_commit.Crash_settled _ -> true
        | _ -> false)
      else (
        Crux.Root.request_stop root;
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Stopped { post_commit }) -> (
            match run_ok
                    (Crux.Post_commit.start post_commit
                    |> Eta.Effect.or_die (function
                         | Crux.Post_commit.Already_started ->
                             Failure "post-commit token started twice"))
            with
            | Crux.Post_commit.Stop_settled -> true
            | _ -> false)
        | _ -> false))

let qcheck_export_generation =
  QCheck.Test.make ~name:"qcheck_export_generation" ~count:100
    (QCheck.int_range (-100) 100)
    (fun payload ->
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let child =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let exported =
        Crux.Exported_endpoint.create (Crux.map child ~f:snd)
          ~codec:int_codec
      in
      let active =
        Crux.map (Crux.both child exported)
          ~f:(fun ((model, _), export) -> Some (model, export))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
            if enabled then active else Crux.return None)
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
          (Crux.both selector selected)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, selector_endpoint), initial_export) = initial in
      let _, old_export = Option.get initial_export in
      send selector_endpoint true;
      let retained_output, retained_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start retained_post;
      let _, retained_export = retained_output in
      let _, retained_export = Option.get retained_export in
      let retained_same = retained_export == old_export in
      send selector_endpoint false;
      let _, removed_post = committed (run_ok (Crux.Root.advance root)) in
      start removed_post;
      let old_revoked =
        Crux.Exported_endpoint.try_invoke old_export payload
        = Error Crux.Exported_endpoint.Revoked
      in
      send selector_endpoint true;
      let reentered_output, reentered_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start reentered_post;
      let _, reentered_export = reentered_output in
      let _, fresh_export = Option.get reentered_export in
      let fresh_generation = fresh_export != old_export in
      let accepted =
        Crux.Exported_endpoint.try_invoke fresh_export payload
        = Ok (Ok (Ok ()))
      in
      let child_model, action_post =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Committed { commit; post_commit }) ->
            let model =
              match output_of_commit commit with
              | _, Some (model, _) -> model
              | _, None ->
                  failwith "fresh export disappeared before invocation"
            in
            (model, post_commit)
        | _ -> failwith "fresh export invocation did not commit"
      in
      start action_post;
      stop_root root;
      retained_same && old_revoked && fresh_generation && accepted
      && child_model = payload)

let qcheck_export_rebinding =
  let sample =
    let open QCheck.Gen in
    pair (-100 -- 100) (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_export_rebinding" ~count:100
    (QCheck.make
       ~print:(fun (first, second) ->
         Printf.sprintf "{first=%d; second=%d}" first second)
       sample)
    (fun (first, second) ->
      let codec_calls = ref 0 in
      let codec =
        Crux.Codec.make
          ~encode:(fun value ->
            incr codec_calls;
            Ok (Bytes.of_string (string_of_int value)))
          ~decode:(fun bytes ->
            incr codec_calls;
            match int_of_string_opt (Bytes.to_string bytes) with
            | Some value -> Ok value
            | None -> Error { Crux.Codec.message = "invalid integer" })
      in
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let counter () =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let left = counter () in
      let right = counter () in
      let target =
        Crux.map
          (Crux.both (Crux.map selector ~f:fst)
             (Crux.both (Crux.map left ~f:snd)
                (Crux.map right ~f:snd)))
          ~f:(fun (use_left, (left, right)) ->
            if use_left then left else right)
      in
      let export = Crux.Exported_endpoint.create target ~codec in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
          (Crux.both selector
             (Crux.both left (Crux.both right export)))
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, selector_endpoint), ((_, _), ((_, _), exported))) =
        initial
      in
      let first_accepted =
        Crux.Exported_endpoint.try_invoke exported first
        = Ok (Ok (Ok ()))
      in
      let first_output, first_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, ((left_model, _), _) = first_output in
      send selector_endpoint false;
      let rebound_output, rebound_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start rebound_post;
      let _, (_, (_, rebound_export)) = rebound_output in
      let retained_export = rebound_export == exported in
      let second_accepted =
        Crux.Exported_endpoint.try_invoke rebound_export second
        = Ok (Ok (Ok ()))
      in
      let second_output, second_post =
        committed (run_ok (Crux.Root.advance root))
      in
      start second_post;
      let _, (_, ((right_model, _), _)) = second_output in
      stop_root root;
      first_accepted && second_accepted && retained_export
      && left_model = first && right_model = second
      && !codec_calls = 0)

let request_operation =
  Crux.Host_operation.define ~name:"test.increment"
    ~request:int_codec ~response:int_codec

let prepare_request_driver ~request_capacity =
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack request_operation ]
  in
  let root =
    Projection.root ~projection_capacity:1 ~ingress_capacity:8 ~request_capacity
      (Crux.return ())
  in
  let driver = Crux.Driver.create binding root in
  let delivery =
    match run_ok (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> failwith "request driver did not produce initial output"
  in
  ignore
    (run_ok
       (Crux.Driver.Delivery.delivered delivery
       |> Eta.Effect.map (fun _ -> ())));
  let requester =
    Crux.Driver.Binding.requester binding request_operation
  in
  (driver, requester)

let rec await_request_event driver =
  let open Eta.Syntax in
  let* event = Crux.Driver.poll driver in
  match event with
  | Some (Crux.Driver.Request request) -> Eta.Effect.pure request
  | Some _ | None ->
      let* () = Eta.Effect.yield in
      await_request_event driver

let stop_request_driver driver =
  Crux.Driver.request_stop driver;
  let rec await_closed attempts =
    if attempts = 0 then failwith "request driver did not close"
    else
      match run_ok (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
      | Some _ | None ->
          Eio.Fiber.yield ();
          await_closed (attempts - 1)
  in
  await_closed 100

let qcheck_request_first_resolution =
  QCheck.Test.make ~name:"qcheck_request_first_resolution" ~count:100
    (QCheck.int_range (-100) 100)
    (fun request ->
      let driver, requester =
        prepare_request_driver ~request_capacity:1
      in
      let request_effect =
        Crux.Requester.request requester request
        |> Eta.Effect.or_die (function
             | Crux.Requester.Ingress_closed ->
                 Failure "request ingress closed"
             | Crux.Requester.Encode_failed _ ->
                 Failure "request encode failed"
             | Crux.Requester.Decode_failed _ ->
                 Failure "request decode failed"
             | Crux.Requester.Dispatch_failed ->
                 Failure "request dispatch failed"
             | Crux.Requester.Closed _ ->
                 Failure "request unexpectedly closed")
      in
      let host_effect =
        let open Eta.Syntax in
        let* event = await_request_event driver in
        let second_resolution = ref None in
        let* handled =
          Crux.Request.Driver_event.handle event request_operation
            ~f:(fun value ~resolve ~on_cancel:_ ->
              let* first = resolve (value + 1) in
              let* second = resolve (value + 2) in
              second_resolution := Some (first, second);
              Eta.Effect.unit)
        in
        let* completion =
          Crux.Request.Driver_event.accepted event
        in
        Eta.Effect.pure
          (handled, completion, !second_resolution)
      in
      let response, (handled, completion, resolutions) =
        run_ok (Eta.Effect.par request_effect host_effect)
      in
      stop_request_driver driver;
      response = request + 1
      && handled = Crux.Request.Driver_event.Handled
      && completion = Ok ()
      && resolutions
         = Some (Ok (), Error Crux.Request.Not_pending))

let resolve_request_event event =
  let open Eta.Syntax in
  let* handled =
    Crux.Request.Driver_event.handle event request_operation
      ~f:(fun value ~resolve ~on_cancel:_ ->
        let* _ = resolve (value + 1000) in
        Eta.Effect.unit)
  in
  let* completion = Crux.Request.Driver_event.accepted event in
  match handled, completion with
  | Crux.Request.Driver_event.Handled, Ok () -> Eta.Effect.unit
  | Crux.Request.Driver_event.Different_operation, _
  | Crux.Request.Driver_event.Already_handled, _
  | Crux.Request.Driver_event.Closed _, _
  | _, Error Crux.Request.Driver_event.Already_completed ->
      Eta.Effect.die_message "request event did not complete once"

let qcheck_request_capacity =
  QCheck.Test.make ~name:"qcheck_request_capacity" ~count:100
    (QCheck.int_range 1 5)
    (fun capacity ->
      let driver, requester =
        prepare_request_driver ~request_capacity:capacity
      in
      let completed = ref 0 in
      List.init (capacity + 1) Fun.id
      |> List.map (fun value ->
             Crux.Requester.request requester value
             |> Eta.Effect.to_result
             |> Eta.Effect.map (fun _ -> incr completed)
             |> Eta.Spi.daemon)
      |> Eta.Effect.concat
      |> run_ok;
      let rec collect count events attempts =
        if count = capacity then List.rev events
        else if attempts = 0 then
          failwith "request slots were not admitted"
        else
          match run_ok (Crux.Driver.poll driver) with
          | Some (Crux.Driver.Request event) ->
              collect (count + 1) (event :: events) attempts
          | Some _ | None ->
              Eio.Fiber.yield ();
              collect count events (attempts - 1)
      in
      let admitted = collect 0 [] 100 in
      let bounded =
        match run_ok (Crux.Driver.poll driver) with
        | None -> true
        | Some _ -> false
      in
      let first, rest =
        match admitted with
        | first :: rest -> (first, rest)
        | [] -> assert false
      in
      run_ok (resolve_request_event first);
      let rec await_last attempts =
        if attempts = 0 then failwith "released request slot was not reused"
        else
          match run_ok (Crux.Driver.poll driver) with
          | Some (Crux.Driver.Request event) -> event
          | Some _ | None ->
              Eio.Fiber.yield ();
              await_last (attempts - 1)
      in
      let last = await_last 100 in
      List.iter
        (fun event -> run_ok (resolve_request_event event))
        (rest @ [ last ]);
      let rec await_completions attempts =
        if !completed = capacity + 1 then true
        else if attempts = 0 then false
        else (
          Eio.Fiber.yield ();
          await_completions (attempts - 1))
      in
      let all_completed = await_completions 100 in
      stop_request_driver driver;
      bounded && all_completed)

let qcheck_driver_one_advancement =
  QCheck.Test.make ~name:"qcheck_driver_one_advancement" ~count:100
    (QCheck.int_range (-100) 100)
    (fun payload ->
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let child =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
            if enabled then Crux.map child ~f:Option.some
            else Crux.return None)
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
          (Crux.both selector selected)
      in
      let driver =
        Crux.Driver.create (Crux.Driver.Binding.identity []) root
      in
      let initial_delivery =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) -> delivery
        | _ -> failwith "driver did not deliver initial output"
      in
      let ((_, selector_endpoint), selected_output) =
        output_of_delivery initial_delivery
      in
      let _, child_endpoint = Option.get selected_output in
      ignore
        (run_ok (Crux.Driver.Delivery.delivered initial_delivery));
      run_ok
        (Crux.Endpoint.send selector_endpoint false
        |> Eta.Effect.or_die (function
             | Crux.Endpoint.Ingress_closed ->
                 Failure "selector ingress closed"));
      run_ok
        (Crux.Endpoint.send child_endpoint payload
        |> Eta.Effect.or_die (function
             | Crux.Endpoint.Ingress_closed ->
                 Failure "child ingress closed"));
      let structural_delivery =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) -> delivery
        | _ -> failwith "driver did not report structural advancement"
      in
      let (_, selected_after_one) =
        output_of_delivery structural_delivery
      in
      ignore
        (run_ok
           (Crux.Driver.Delivery.delivered structural_delivery));
      let stale_reported =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Rejected Crux.Root.Stale_endpoint) -> true
        | _ -> false
      in
      let no_extra_commit =
        match run_ok (Crux.Driver.poll driver) with
        | None -> true
        | Some _ -> false
      in
      stop_request_driver driver;
      Option.is_none selected_after_one && stale_reported
      && no_extra_commit)

let qcheck_delivery_token =
  QCheck.Test.make ~name:"qcheck_delivery_token" ~count:100
    (QCheck.int_range (-100) 100)
    (fun expected ->
      let lifecycle_started = ref false in
      let description =
        Crux.both (Crux.return expected)
          (Crux.lifecycle
             (Crux.return
                (Eta.Effect.sync (fun () ->
                     lifecycle_started := true))))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
          description
      in
      let driver =
        Crux.Driver.create (Crux.Driver.Binding.identity []) root
      in
      let delivery =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) -> delivery
        | _ -> failwith "driver did not produce delivery token"
      in
      let complete_output =
        fst (output_of_delivery delivery) = expected
      in
      let gated_before = not !lifecycle_started in
      let first =
        run_ok (Crux.Driver.Delivery.delivered delivery)
      in
      Eio.Fiber.yield ();
      let started_after = !lifecycle_started in
      let second =
        run_ok (Crux.Driver.Delivery.delivered delivery)
      in
      stop_request_driver driver;
      complete_output && gated_before && first = Ok ()
      && started_after
      && second
         = Error Crux.Driver.Delivery.Already_completed)

type request_closure_case =
  | Owner_disposal
  | Root_stop
  | Root_crash

let pp_request_closure_case = function
  | Owner_disposal -> "owner-disposal"
  | Root_stop -> "root-stop"
  | Root_crash -> "root-crash"

let qcheck_request_closure_reasons =
  let sample =
    let open QCheck.Gen in
    pair
      (oneof_list [ Owner_disposal; Root_stop; Root_crash ])
      (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_request_closure_reasons" ~count:100
    (QCheck.make
       ~print:(fun (case, payload) ->
         Printf.sprintf "{case=%s; payload=%d}"
           (pp_request_closure_case case)
           payload)
       sample)
    (fun (case, payload) ->
      let binding =
        Crux.Driver.Binding.identity
          [ Crux.Host_operation.Pack request_operation ]
      in
      let requester =
        Crux.Driver.Binding.requester binding request_operation
      in
      let request_program =
        Crux.Requester.request requester payload
        |> Eta.Effect.to_result
        |> Eta.Effect.map (fun _ -> ())
      in
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
            if enabled then
              Crux.lifecycle (Crux.return request_program)
              |> Crux.map ~f:Option.some
            else Crux.return None)
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
          (Crux.both selector selected)
      in
      let driver = Crux.Driver.create binding root in
      let initial =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) -> delivery
        | _ -> failwith "closure-reason driver did not start"
      in
      let ((_, selector_endpoint), _) =
        output_of_delivery initial
      in
      ignore (run_ok (Crux.Driver.Delivery.delivered initial));
      let event = run_ok (await_request_event driver) in
      let observed_reason = ref None in
      let handled =
        run_ok
          (Crux.Request.Driver_event.handle event request_operation
             ~f:(fun _ ~resolve:_ ~on_cancel ->
               on_cancel (fun reason ->
                   observed_reason := Some reason);
               Eta.Effect.unit))
      in
      let accepted =
        run_ok (Crux.Request.Driver_event.accepted event)
      in
      let expected =
        match case with
        | Owner_disposal ->
            run_ok
              (Crux.Endpoint.send selector_endpoint false
              |> Eta.Effect.or_die (function
                   | Crux.Endpoint.Ingress_closed ->
                       Failure "selector ingress closed"));
            let delivery =
              match run_ok (Crux.Driver.poll driver) with
              | Some (Crux.Driver.Deliver delivery) -> delivery
              | _ -> failwith "owner disposal did not commit"
            in
            ignore
              (run_ok
                 (Crux.Driver.Delivery.delivered delivery));
            Crux.Request.Owner_disposed
        | Root_stop ->
            Crux.Driver.request_stop driver;
            (match run_ok (Crux.Driver.poll driver) with
            | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
            | _ -> failwith "stopped request root did not close");
            Crux.Request.Root_stopped
        | Root_crash ->
            run_ok
              (Crux.Endpoint.send selector_endpoint true
              |> Eta.Effect.or_die (function
                   | Crux.Endpoint.Ingress_closed ->
                       Failure "selector ingress closed"));
            let delivery =
              match run_ok (Crux.Driver.poll driver) with
              | Some (Crux.Driver.Deliver delivery) -> delivery
              | _ -> failwith "crash trigger did not commit"
            in
            let cause =
              Crux.Failure.Packed_cause.make
                ~pp_error:Format.pp_print_string
                (Eta.Cause.fail "adapter failed")
            in
            ignore
              (run_ok
                 (Crux.Driver.Delivery.failed delivery cause));
            (match run_ok (Crux.Driver.poll driver) with
            | Some (Crux.Driver.Crash_detected _) -> ()
            | _ -> failwith "request root crash was not detected");
            (match run_ok (Crux.Driver.poll driver) with
            | Some
                (Crux.Driver.Closed (Crux.Driver.Crashed _)) ->
                ()
            | _ -> failwith "request root crash did not settle");
            Crux.Request.Root_crashed
      in
      let rec await_reason attempts =
        match !observed_reason with
        | Some reason -> Some reason
        | None when attempts = 0 -> None
        | None ->
            Eio.Fiber.yield ();
            await_reason (attempts - 1)
      in
      let reason = await_reason 100 in
      (match case with
      | Owner_disposal -> stop_request_driver driver
      | Root_stop | Root_crash -> ());
      handled = Crux.Request.Driver_event.Handled
      && accepted = Ok ()
      && reason = Some expected)

let wire_failure =
  let record =
    {
      Crux.Failure.cause = Eta.Cause.Portable.Fail "redacted";
      origin = Crux.Failure.Owned_work;
      trigger = Crux.Failure.Lifecycle_program;
      position = 0L;
    }
  in
  { Crux.Failure.primary = record; secondary = [] }

let wire_frame family seq =
  let bytes = Bytes.of_string "x" in
  match family mod 16 with
  | 0 ->
      Crux.Wire.Frame.Projection_deliver
        {
          seq;
          reason = `Advancement;
          content =
            Updates
              [
                Attached
                  {
                    kind = "generated";
                    key = Bytes.empty;
                    incarnation = 1L;
                    value = bytes;
                  };
              ];
        }
  | 1 ->
      Projection_result { seq; reply_to = 0l; result = `Accepted }
  | 2 -> Crash_notify { seq; failure = wire_failure }
  | 3 ->
      Crash_result { seq; reply_to = 0l; result = `Accepted }
  | 4 -> Endpoint_invoke { seq; handle = bytes; payload = bytes }
  | 5 ->
      Endpoint_result { seq; reply_to = 0l; result = `Accepted }
  | 6 -> Request_start { seq; handle = bytes; payload = bytes }
  | 7 ->
      Request_start_result
        {
          seq;
          reply_to = 0l;
          result = `Request_capacity_full;
        }
  | 8 ->
      Request_dispatch
        {
          seq;
          request = bytes;
          operation = "test.operation";
          payload = bytes;
        }
  | 9 ->
      Request_dispatch_result
        { seq; reply_to = 0l; accepted = true }
  | 10 -> Request_resolve { seq; request = bytes; payload = bytes }
  | 11 ->
      Request_resolve_result
        {
          seq;
          reply_to = 0l;
          result = `Identity `Accepted;
        }
  | 12 -> Request_cancel { seq; request = bytes }
  | 13 ->
      Request_cancel_result
        { seq; reply_to = 0l; result = `Accepted }
  | 14 -> Request_resolved { seq; request = bytes; payload = bytes }
  | _ ->
      Request_closed
        {
          seq;
          request = bytes;
          reason = Crux.Request.Session_closed;
        }

module Sequence_format = struct
  let encode _ = Bytes.empty

  let decode bytes =
    match String.split_on_char ',' (Bytes.to_string bytes) with
    | [ sequence; family ] -> (
        match
          Int64.of_string_opt sequence,
          int_of_string_opt family
        with
        | Some sequence, Some family
          when sequence >= 0L && sequence <= 0xffff_ffffL ->
            Ok (wire_frame family (Int64.to_int32 sequence))
        | _ -> Error Crux.Wire.Malformed_frame)
    | _ -> Error Crux.Wire.Malformed_frame
end

let encoded_sequence family sequence =
  Bytes.of_string
    (Printf.sprintf "%Ld,%d" sequence family)

let qcheck_wire_sequence =
  QCheck.Test.make ~name:"qcheck_wire_sequence" ~count:100
    (QCheck.int_range 0 8)
    (fun rotation ->
      let command_families =
        [| 0; 2; 4; 6; 8; 10; 12; 14; 15 |]
      in
      let _candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:64
          ~format:(module Sequence_format)
      in
      let accepted =
        List.init 9 Fun.id
        |> List.for_all (fun index ->
               run_ok
                 (Crux.Serialized_session.receive peer
                    (encoded_sequence
                       command_families.
                         ((rotation + index) mod 9)
                       (Int64.of_int index)))
               = Ok ())
      in
      let skipped =
        run_ok
          (Crux.Serialized_session.receive peer
             (encoded_sequence
                command_families.(rotation)
                10L))
      in
      let after_close =
        run_ok
          (Crux.Serialized_session.receive peer
             (encoded_sequence
                command_families.(rotation)
                9L))
      in
      accepted
      && skipped
         = Error
             (Crux.Serialized_session.Protocol_error
                Crux.Wire.Bad_sequence)
      && after_close
         = Error Crux.Serialized_session.Session_closed)

type malformed_envelope =
  | Json_duplicate
  | Json_unknown
  | Json_missing
  | Json_wrong_type
  | Json_noncanonical_bytes
  | Sexp_nested
  | Sexp_wrong_arity
  | Sexp_noncanonical_bytes

let pp_malformed_envelope = function
  | Json_duplicate -> "json-duplicate"
  | Json_unknown -> "json-unknown"
  | Json_missing -> "json-missing"
  | Json_wrong_type -> "json-wrong-type"
  | Json_noncanonical_bytes -> "json-noncanonical-bytes"
  | Sexp_nested -> "sexp-nested"
  | Sexp_wrong_arity -> "sexp-wrong-arity"
  | Sexp_noncanonical_bytes -> "sexp-noncanonical-bytes"

let qcheck_exact_envelope_grammars =
  let cases =
    [
      Json_duplicate;
      Json_unknown;
      Json_missing;
      Json_wrong_type;
      Json_noncanonical_bytes;
      Sexp_nested;
      Sexp_wrong_arity;
      Sexp_noncanonical_bytes;
    ]
  in
  QCheck.Test.make ~name:"qcheck_exact_envelope_grammars"
    ~count:100
    (QCheck.make ~print:pp_malformed_envelope
       (QCheck.Gen.oneof_list cases))
    (fun case ->
      let decoded =
        match case with
        | Json_duplicate ->
            Eta_crux_json.Format.decode
              (Bytes.of_string
                 {|{"seq":0,"tag":"request.cancel","request":"","seq":0}|})
        | Json_unknown ->
            Eta_crux_json.Format.decode
              (Bytes.of_string
                 {|{"seq":0,"tag":"request.cancel","request":"","extra":true}|})
        | Json_missing ->
            Eta_crux_json.Format.decode
              (Bytes.of_string
                 {|{"seq":0,"tag":"request.cancel"}|})
        | Json_wrong_type ->
            Eta_crux_json.Format.decode
              (Bytes.of_string
                 {|{"seq":0,"tag":"request.cancel","request":42}|})
        | Json_noncanonical_bytes ->
            Eta_crux_json.Format.decode
              (Bytes.of_string
                 {|{"seq":0,"tag":"request.cancel","request":"eA=="}|})
        | Sexp_nested ->
            Eta_crux_sexp.Format.decode
              (Bytes.of_string "(0 request.cancel (eA))")
        | Sexp_wrong_arity ->
            Eta_crux_sexp.Format.decode
              (Bytes.of_string "(0 request.cancel)")
        | Sexp_noncanonical_bytes ->
            Eta_crux_sexp.Format.decode
              (Bytes.of_string "(0 request.cancel eA==)")
      in
      Result.is_error decoded)

type reply_correlation_case =
  | Exact_reply
  | Unknown_reply
  | Wrong_result_family

let pp_reply_correlation_case = function
  | Exact_reply -> "exact"
  | Unknown_reply -> "unknown"
  | Wrong_result_family -> "wrong-family"

let qcheck_wire_reply_correlation =
  let sample =
    let open QCheck.Gen in
    pair
      (oneof_list
         [ Exact_reply; Unknown_reply; Wrong_result_family ])
      (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_wire_reply_correlation"
    ~count:100
    (QCheck.make
       ~print:(fun (case, output) ->
         Printf.sprintf "{case=%s; output=%d}"
           (pp_reply_correlation_case case)
           output)
       sample)
    (fun (case, output) ->
      let candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:1024
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
          (Crux.return output)
      in
      let driver = Crux.Driver.create binding root in
      let transport_owned =
        run_ok (Crux.Driver.poll driver) = None
      in
      let command =
        match
          run_ok (Crux.Serialized_session.poll_outgoing peer)
        with
        | Some bytes -> Eta_crux_json.Format.decode bytes
        | None -> Error Crux.Wire.Malformed_frame
      in
      let command_sequence =
        match command with
        | Ok (Crux.Wire.Frame.Projection_deliver { seq; _ }) -> seq
        | Ok _ | Error _ -> Int32.minus_one
      in
      let response =
        match case with
        | Exact_reply ->
            Crux.Wire.Frame.Projection_result
              {
                seq = 0l;
                reply_to = command_sequence;
                result = `Accepted;
              }
        | Unknown_reply ->
            Crux.Wire.Frame.Projection_result
              {
                seq = 0l;
                reply_to = Int32.add command_sequence 1l;
                result = `Accepted;
              }
        | Wrong_result_family ->
            Crux.Wire.Frame.Endpoint_result
              {
                seq = 0l;
                reply_to = command_sequence;
                result = `Accepted;
              }
      in
      let received =
        run_ok
          (Crux.Serialized_session.receive peer
             (Eta_crux_json.Format.encode response))
      in
      let expected =
        match case with
        | Exact_reply -> Ok ()
        | Unknown_reply ->
            Error
              (Crux.Serialized_session.Protocol_error
                 Crux.Wire.Unknown_reply)
        | Wrong_result_family ->
            Error
              (Crux.Serialized_session.Protocol_error
                 Crux.Wire.Wrong_result_family)
      in
      let closed_after_protocol_error =
        match case with
        | Exact_reply ->
            run_ok (Crux.Driver.poll driver) = None
        | Unknown_reply | Wrong_result_family ->
            run_ok
              (Crux.Serialized_session.receive peer
                 (Bytes.of_string "{}"))
            = Error Crux.Serialized_session.Session_closed
      in
      Crux.Driver.request_stop driver;
      (match case with
      | Exact_reply ->
          ignore (run_ok (Crux.Driver.poll driver))
      | Unknown_reply | Wrong_result_family -> ());
      transport_owned && command_sequence = 0l
      && received = expected && closed_after_protocol_error)

type malformed_frame_case =
  | Malformed_envelope
  | Bad_incoming_sequence
  | Unknown_result_reply

let pp_malformed_frame_case = function
  | Malformed_envelope -> "malformed-envelope"
  | Bad_incoming_sequence -> "bad-sequence"
  | Unknown_result_reply -> "unknown-reply"

let qcheck_malformed_frame_isolation =
  let sample =
    let open QCheck.Gen in
    pair
      (oneof_list
         [
           Malformed_envelope;
           Bad_incoming_sequence;
           Unknown_result_reply;
         ])
      (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_malformed_frame_isolation"
    ~count:100
    (QCheck.make
       ~print:(fun (case, model) ->
         Printf.sprintf "{case=%s; model=%d}"
           (pp_malformed_frame_case case)
           model)
       sample)
    (fun (case, model) ->
      let candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:1024
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
          (Crux.return model)
      in
      let driver = Crux.Driver.create binding root in
      ignore (run_ok (Crux.Driver.poll driver));
      let command =
        run_ok (Crux.Serialized_session.poll_outgoing peer)
      in
      let malformed =
        match case with
        | Malformed_envelope -> Bytes.of_string "{}"
        | Bad_incoming_sequence ->
            Crux.Wire.Frame.Projection_result
              {
                seq = 1l;
                reply_to = 0l;
                result = `Accepted;
              }
            |> Eta_crux_json.Format.encode
        | Unknown_result_reply ->
            Crux.Wire.Frame.Projection_result
              {
                seq = 0l;
                reply_to = 1l;
                result = `Accepted;
              }
            |> Eta_crux_json.Format.encode
      in
      let rejected =
        Result.is_error
          (run_ok
             (Crux.Serialized_session.receive peer malformed))
      in
      let no_reply =
        run_ok (Crux.Serialized_session.poll_outgoing peer) = None
      in
      let no_application_change =
        run_ok (Crux.Root.advance root)
        = Error Crux.Root.Driver_attached
      in
      Option.is_some command && rejected && no_reply
      && no_application_change)

type closed_outcome_case =
  | Malformed_endpoint
  | Malformed_request_export
  | Unknown_request_resolution
  | Unknown_request_cancellation

let pp_closed_outcome_case = function
  | Malformed_endpoint -> "malformed-endpoint"
  | Malformed_request_export -> "malformed-request-export"
  | Unknown_request_resolution -> "unknown-request-resolution"
  | Unknown_request_cancellation -> "unknown-request-cancellation"

let qcheck_wire_closed_outcomes =
  let sample =
    let open QCheck.Gen in
    pair
      (oneof_list
         [
           Malformed_endpoint;
           Malformed_request_export;
           Unknown_request_resolution;
           Unknown_request_cancellation;
         ])
      (-100 -- 100)
  in
  QCheck.Test.make ~name:"qcheck_wire_closed_outcomes"
    ~count:100
    (QCheck.make
       ~print:(fun (case, payload) ->
         Printf.sprintf "{case=%s; payload=%d}"
           (pp_closed_outcome_case case)
           payload)
       sample)
    (fun (case, payload) ->
      let candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:1024
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
          (Crux.return payload)
      in
      let driver = Crux.Driver.create binding root in
      ignore (run_ok (Crux.Driver.poll driver));
      let output_sequence =
        match
          run_ok (Crux.Serialized_session.poll_outgoing peer)
        with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok (Crux.Wire.Frame.Projection_deliver { seq; _ }) -> seq
            | Ok _ | Error _ -> Int32.minus_one)
        | None -> Int32.minus_one
      in
      let token = Bytes.of_string (Printf.sprintf "missing-%d" payload) in
      let command =
        match case with
        | Malformed_endpoint ->
            Crux.Wire.Frame.Endpoint_invoke
              { seq = 0l; handle = token; payload = Bytes.empty }
        | Malformed_request_export ->
            Crux.Wire.Frame.Request_start
              { seq = 0l; handle = token; payload = Bytes.empty }
        | Unknown_request_resolution ->
            Crux.Wire.Frame.Request_resolve
              { seq = 0l; request = token; payload = Bytes.empty }
        | Unknown_request_cancellation ->
            Crux.Wire.Frame.Request_cancel
              { seq = 0l; request = token }
      in
      let admitted =
        run_ok
          (Crux.Serialized_session.receive peer
             (Eta_crux_json.Format.encode command))
        = Ok ()
      in
      ignore (run_ok (Crux.Driver.poll driver));
      let closed_outcome =
        match
          run_ok (Crux.Serialized_session.poll_outgoing peer)
        with
        | None -> false
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes, case with
            | Ok
                (Crux.Wire.Frame.Endpoint_result
                  { reply_to = 0l; result = `Malformed_handle; _ }),
              Malformed_endpoint ->
                true
            | Ok
                (Crux.Wire.Frame.Request_start_result
                  { reply_to = 0l; result = `Malformed_handle; _ }),
              Malformed_request_export ->
                true
            | Ok
                (Crux.Wire.Frame.Request_resolve_result
                  {
                    reply_to = 0l;
                    result = `Identity `Unknown_request;
                    _;
                  }),
              Unknown_request_resolution ->
                true
            | Ok
                (Crux.Wire.Frame.Request_cancel_result
                  { reply_to = 0l; result = `Unknown_request; _ }),
              Unknown_request_cancellation ->
                true
            | _ -> false)
      in
      let acknowledgment =
        Crux.Wire.Frame.Projection_result
          {
            seq = 1l;
            reply_to = output_sequence;
            result = `Accepted;
          }
        |> Eta_crux_json.Format.encode
      in
      let session_remained_open =
        run_ok
          (Crux.Serialized_session.receive peer acknowledgment)
        = Ok ()
      in
      ignore (run_ok (Crux.Driver.poll driver));
      Crux.Driver.request_stop driver;
      ignore (run_ok (Crux.Driver.poll driver));
      admitted && output_sequence = 0l && closed_outcome
      && session_remained_open)

module Bounds_format = struct
  let encode _ = Bytes.empty

  let decode bytes =
    let value = Bytes.to_string bytes in
    if String.length value < 2 then Error Crux.Wire.Malformed_frame
    else
      match
        value.[0],
        int_of_string_opt
          (String.sub value 1 (String.length value - 1))
      with
      | 'E', Some length when length >= 0 ->
          Ok
            (Crux.Wire.Frame.Endpoint_invoke
              {
                seq = 0l;
                handle = Bytes.make length 'h';
                payload = Bytes.empty;
              })
      | 'R', Some length when length >= 0 ->
          Ok
            (Crux.Wire.Frame.Request_cancel
              { seq = 0l; request = Bytes.make length 'r' })
      | _ -> Error Crux.Wire.Malformed_frame
end

type wire_bound_case =
  | Incoming_frame_bound
  | Endpoint_handle_bound
  | Request_token_bound
  | Outgoing_frame_bound

let pp_wire_bound_case = function
  | Incoming_frame_bound -> "incoming-frame"
  | Endpoint_handle_bound -> "endpoint-handle"
  | Request_token_bound -> "request-token"
  | Outgoing_frame_bound -> "outgoing-frame"

let qcheck_wire_bounds =
  let sample =
    let open QCheck.Gen in
    pair
      (oneof_list
         [
           Incoming_frame_bound;
           Endpoint_handle_bound;
           Request_token_bound;
           Outgoing_frame_bound;
         ])
      (1 -- 80)
  in
  QCheck.Test.make ~name:"qcheck_wire_bounds" ~count:100
    (QCheck.make
       ~print:(fun (case, size) ->
         Printf.sprintf "{case=%s; size=%d}"
           (pp_wire_bound_case case)
           size)
       sample)
    (fun (case, size) ->
      match case with
      | Incoming_frame_bound ->
          let _candidate, peer =
            Crux.Serialized_session.candidate ~max_frame_bytes:size
              ~format:(module Bounds_format)
          in
          run_ok
            (Crux.Serialized_session.receive peer
               (Bytes.make (size + 1) 'x'))
          = Error
              (Crux.Serialized_session.Protocol_error
                 Crux.Wire.Frame_too_large)
      | Endpoint_handle_bound | Request_token_bound ->
          let _candidate, peer =
            Crux.Serialized_session.candidate ~max_frame_bytes:64
              ~format:(module Bounds_format)
          in
          let marker =
            match case with
            | Endpoint_handle_bound -> 'E'
            | Request_token_bound -> 'R'
            | Incoming_frame_bound | Outgoing_frame_bound ->
                assert false
          in
          let received =
            run_ok
              (Crux.Serialized_session.receive peer
                 (Bytes.of_string
                    (Printf.sprintf "%c%d" marker size)))
          in
          if size <= 64 then received = Ok ()
          else
            received
            = Error
                (Crux.Serialized_session.Protocol_error
                   Crux.Wire.Invalid_field)
      | Outgoing_frame_bound ->
          let candidate, peer =
            Crux.Serialized_session.candidate ~max_frame_bytes:size
              ~format:(module Eta_crux_json.Format)
          in
          let _bytes_codec =
            Crux.Codec.make ~encode:(fun bytes -> Ok bytes)
              ~decode:(fun bytes -> Ok bytes)
          in
          let binding, _admin =
            Crux.Driver.Binding.serialized
              ~operations:[] ~session:candidate
          in
          let root =
            Projection.root ~projection_capacity:1 ~ingress_capacity:1
              ~request_capacity:1
              (Crux.return (Bytes.make size 'x'))
          in
          let driver = Crux.Driver.create binding root in
          ignore (run_ok (Crux.Driver.poll driver));
          run_ok (Crux.Serialized_session.poll_outgoing peer) = None
          && run_ok
               (Crux.Serialized_session.receive peer Bytes.empty)
             = Error Crux.Serialized_session.Session_closed)

let bytes_contains bytes needle =
  let haystack = Bytes.to_string bytes in
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop offset =
    if offset + needle_length > haystack_length then false
    else if
      String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0

let qcheck_wire_redaction =
  let sample =
    let open QCheck.Gen in
    triple (-1000 -- 1000) (-1000 -- 1000)
      (-1000 -- 1000)
  in
  QCheck.Test.make ~name:"qcheck_wire_redaction" ~count:100
    (QCheck.make
       ~print:(fun (diagnostic, model, action) ->
         Printf.sprintf
           "{diagnostic=%d; model=%d; action=%d}"
           diagnostic model action)
       sample)
    (fun (diagnostic_number, model_number, action_number) ->
      let diagnostic =
        Printf.sprintf "local-decoder-diagnostic-%d"
          diagnostic_number
      in
      let model =
        Printf.sprintf "private-model-value-%d" model_number
      in
      let action =
        Printf.sprintf "private-action-value-%d" action_number
      in
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:model
          ~apply_action:(fun ~self:_ ~input:() ~model:_
                            ~action ->
            (action, None))
      in
      let payload_codec =
        Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
          ~decode:(fun _ ->
            Error { Crux.Codec.message = diagnostic })
      in
      let export =
        Crux.Exported_endpoint.create
          (Crux.map machine ~f:snd)
          ~codec:payload_codec
      in
      let description = Crux.both machine export in
      let output_codec =
        Crux.Codec.make
          ~encode:(fun ((model, _endpoint), export) ->
            let handle =
              Crux.Exported_endpoint.remote_handle export
            in
            Ok
              (Bytes.concat (Bytes.of_string "\000")
                 [ Bytes.of_string model; handle ]))
          ~decode:(fun _ ->
            Error
              {
                Crux.Codec.message =
                  "redaction test output is encode-only";
              })
      in
      let projection =
        Typed_projection.create ~name:"wire-redaction"
          ~codec:output_codec ~value_equal:( == )
          ~cutoff:Crux.Cutoff.never
      in
      let candidate, peer =
        Crux.Serialized_session.candidate
          ~max_frame_bytes:2048
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let root =
        Typed_projection.root projection ~projection_capacity:1
          ~ingress_capacity:1 ~request_capacity:1 description
      in
      let driver = Crux.Driver.create binding root in
      ignore (run_ok (Crux.Driver.poll driver));
      let output_sequence, handle =
        match
          run_ok
            (Crux.Serialized_session.poll_outgoing peer)
        with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok
                (Crux.Wire.Frame.Projection_deliver
                  { seq; content; _ }) ->
                let output = projection_content_value content in
                let separator =
                  Bytes.index output '\000'
                in
                ( seq,
                  Bytes.sub output (separator + 1)
                    (Bytes.length output - separator - 1) )
            | Ok _ | Error _ ->
                failwith "redaction output frame malformed")
        | None -> failwith "redaction output frame missing"
      in
      let acknowledgment =
        Crux.Wire.Frame.Projection_result
          {
            seq = 0l;
            reply_to = output_sequence;
            result = `Accepted;
          }
        |> Eta_crux_json.Format.encode
      in
      ignore
        (run_ok
           (Crux.Serialized_session.receive peer
              acknowledgment));
      ignore (run_ok (Crux.Driver.poll driver));
      let invocation =
        Crux.Wire.Frame.Endpoint_invoke
          {
            seq = 1l;
            handle;
            payload = Bytes.of_string action;
          }
        |> Eta_crux_json.Format.encode
      in
      ignore
        (run_ok
           (Crux.Serialized_session.receive peer invocation));
      ignore (run_ok (Crux.Driver.poll driver));
      let redacted =
        match
          run_ok
            (Crux.Serialized_session.poll_outgoing peer)
        with
        | Some bytes ->
            let exact_result =
              match Eta_crux_json.Format.decode bytes with
              | Ok
                  (Crux.Wire.Frame.Endpoint_result
                    { result = `Malformed_payload; _ }) ->
                  true
              | Ok _ | Error _ -> false
            in
            exact_result
            && not (bytes_contains bytes diagnostic)
            && not (bytes_contains bytes model)
            && not (bytes_contains bytes action)
        | None -> false
      in
      Crux.Driver.request_stop driver;
      ignore (run_ok (Crux.Driver.poll driver));
      redacted)

let crux_test_shell =
  {
    Eta_crux_test.Test_shell.pp_error =
      (fun _ (error : Crux.never) ->
        match error with _ -> .);
    deliver = (fun _ -> Eta.Effect.unit);
    request_event = (fun _ -> Eta.Effect.unit);
    crash_detected = (fun _ -> Eta.Effect.unit);
  }

let qcheck_bounded_drain =
  QCheck.Test.make ~name:"qcheck_bounded_drain" ~count:100
    (QCheck.int_range 1 20)
    (fun limit ->
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self ~input:() ~model ~action ->
            ( model + action,
              Some
                (Crux.Endpoint.send self action
                |> Eta.Effect.ignore_errors) ))
      in
      let seed =
        Crux.lifecycle
          (Crux.map machine ~f:(fun (_, endpoint) ->
               Crux.Endpoint.send endpoint 1
               |> Eta.Effect.ignore_errors))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:4
          ~request_capacity:1
          (Crux.map (Crux.both machine seed) ~f:fst)
      in
      let clock = Eta_test.Test_clock.create () in
      let handle =
        Eta_crux_test.Handle.create
          ~clock
          ~incoming:Eta_crux_test.Incoming.none
          ~shell:crux_test_shell root
      in
      let reached_limit =
        match
          run_ok
            (Eta_crux_test.Handle.drain handle
               ~max_steps:limit)
        with
        | Ok
            {
              Eta_crux_test.Handle.status =
                Limit_reached;
              _;
            } ->
            true
        | Ok _ | Error _ -> false
      in
      let still_usable =
        match run_ok (Eta_crux_test.Handle.frame handle) with
        | Ok
            {
              Eta_crux_test.Handle.outcome =
                Committed _;
              _;
            } ->
            true
        | Ok _ | Error _ -> false
      in
      ignore (run_ok (Eta_crux_test.Handle.stop handle));
      reached_limit && still_usable)

type controlled_action =
  | Controlled_item of int
  | Controlled_terminal

let controlled_source_root controlled =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:[]
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        match action with
        | Controlled_item item ->
            (model @ [ item ], None)
        | Controlled_terminal -> (model, None))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal (fun () () -> true))
      ~spec:(Crux.return ())
      ~producer:
        (Crux.return
           (Eta_crux_test.Controlled_source.producer controlled))
      ~target:(Crux.map machine ~f:snd)
      ~on_item:
        (Crux.return (fun item -> Controlled_item item))
      ~on_terminal:
        (Crux.return (fun _ -> Controlled_terminal))
  in
  Projection.root ~projection_capacity:1 ~ingress_capacity:16 ~request_capacity:1
    (Crux.map (Crux.both machine source) ~f:fst)

let start_controlled_source root controlled =
  let _, post_commit = committed (run_ok (Crux.Root.advance root)) in
  let opening_settled = Eta.Promise.create () in
  ignore
    (run_ok
       (Eta.Spi.daemon
          (let open Eta.Syntax in
           let* exit =
             Crux.Post_commit.start post_commit
             |> Eta.Effect.or_die (function
                  | Crux.Post_commit.Already_started ->
                      Failure
                        "controlled source post-commit started twice")
             |> Eta.Effect.map (fun _ -> ())
             |> Eta.Effect.to_exit
           in
           let+ _ =
             Eta.Promise.resolve opening_settled exit
           in
           ())));
  let incarnation =
    run_ok
      (Eta_crux_test.Controlled_source.await_incarnation
         controlled)
  in
  let opened =
    Eta_crux_test.Controlled_source.open_ incarnation
    = Ok ()
  in
  ignore (run_ok (Eta.Promise.await opening_settled));
  (incarnation, opened)

let rec await_controlled_commit root attempts =
  if attempts = 0 then
    failwith "controlled source action did not reach ingress"
  else
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Committed { commit; post_commit }) ->
        let output = output_of_commit commit in
        start post_commit;
        output
    | Ok Crux.Root.Idle ->
        ignore (run_ok Eta.Effect.yield);
        await_controlled_commit root (attempts - 1)
    | Ok (Crux.Root.Rejected _) ->
        await_controlled_commit root (attempts - 1)
    | Ok (Crux.Root.Stopped _)
    | Ok (Crux.Root.Failed _)
    | Error _ ->
        failwith
          "controlled source root terminated while awaiting output"

let observe_controlled_effects inputs =
  let controlled :
      (int, unit, string) Eta_test.Controlled.t =
    Eta_test.Controlled.create ()
  in
  let open Eta.Syntax in
  let observation =
    let* () =
      inputs
      |> List.map (fun input ->
             Eta.Spi.daemon
               (Eta_test.Controlled.eff controlled input
               |> Eta.Effect.ignore_errors))
      |> Eta.Effect.concat
    in
    let rec collect count calls =
      if count = 0 then Eta.Effect.pure (List.rev calls)
      else
        let* call = Eta_test.Controlled.await_call controlled in
        collect (count - 1) (call :: calls)
    in
    let* calls = collect (List.length inputs) [] in
    let observed =
      List.map Eta_test.Controlled.input calls
    in
    let completions =
      List.map
        (fun call -> Eta_test.Controlled.succeed call ())
        calls
    in
    let one_shot =
      match calls with
      | [] -> true
      | call :: _ ->
          Eta_test.Controlled.succeed call ()
          = Error Eta_test.Controlled.Not_pending
    in
    let statuses =
      List.for_all
        (fun call ->
          Eta_test.Controlled.status call
          = Eta_test.Controlled.Succeeded)
        calls
    in
    Eta.Effect.pure
      (observed = inputs
      && List.for_all (( = ) (Ok ())) completions
      && one_shot && statuses)
  in
  let fifo_and_one_shot = run_ok observation in
  let cancellation =
    let loser =
      Eta_test.Controlled.eff controlled max_int
      |> Eta.Effect.or_die (fun error -> Failure error)
      |> Eta.Effect.map (fun () -> `Unexpected)
    in
    let observer =
      let* call = Eta_test.Controlled.await_call controlled in
      Eta.Effect.pure (`Observed call)
    in
    run_ok (Eta.Effect.race [ loser; observer ])
  in
  let cancelled =
    match cancellation with
    | `Observed call ->
        Eta_test.Controlled.status call
        = Eta_test.Controlled.Cancelled
        && Eta_test.Controlled.succeed call ()
           = Error Eta_test.Controlled.Not_pending
    | `Unexpected -> false
  in
  Eta_test.Controlled.expect_no_pending controlled;
  fifo_and_one_shot && cancelled

let observe_controlled_source inputs =
  let controlled = Eta_crux_test.Controlled_source.create () in
  let root = controlled_source_root controlled in
  let incarnation, opened =
    start_controlled_source root controlled
  in
  let observed =
    List.fold_left
      (fun _ item ->
        ignore
          (run_ok
             (Eta_crux_test.Controlled_source.emit incarnation
                item
             |> Eta.Effect.or_die (function
                  | Eta_crux_test.Controlled_source.Control _ ->
                      Failure "controlled source is not running"
                  | Eta_crux_test.Controlled_source.Admission
                      Crux.Endpoint.Ingress_closed ->
                      Failure "controlled source ingress closed")));
        fst (await_controlled_commit root 100))
      [] inputs
  in
  let completed =
    Eta_crux_test.Controlled_source.complete incarnation
    = Ok ()
  in
  let one_shot =
    match
      Eta_crux_test.Controlled_source.complete incarnation
    with
    | Error
        (Eta_crux_test.Controlled_source.Wrong_state
          Eta_crux_test.Controlled_source.Completed) ->
        true
    | Ok () | Error _ -> false
  in
  ignore (await_controlled_commit root 100);
  stop_root root;
  Eta_crux_test.Controlled_source.expect_no_pending controlled;

  let cancelled_control =
    Eta_crux_test.Controlled_source.create ()
  in
  let cancelled_root =
    controlled_source_root cancelled_control
  in
  let cancelled_incarnation, cancellation_opened =
    start_controlled_source cancelled_root cancelled_control
  in
  stop_root cancelled_root;
  Eta_crux_test.Controlled_source.expect_no_pending
    cancelled_control;
  opened && observed = inputs && completed && one_shot
  && cancellation_opened
  && Eta_crux_test.Controlled_source.state incarnation
     = Eta_crux_test.Controlled_source.Completed
  && Eta_crux_test.Controlled_source.state
       cancelled_incarnation
     = Eta_crux_test.Controlled_source.Cancelled

let qcheck_controlled_dependencies =
  let inputs =
    let open QCheck.Gen in
    list_size (0 -- 12) (-100 -- 100)
  in
  (* Generated class: bounded integer input lists. Observation boundary:
     FIFO call/incarnation queues, one-shot status, committed root
     output, and cancellation status after complete root settlement. *)
  QCheck.Test.make ~name:"qcheck_controlled_dependencies"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) inputs)
    (fun inputs ->
      observe_controlled_effects inputs
      && observe_controlled_source inputs)

let qcheck_latest_committed_snapshot =
  let actions =
    let open QCheck.Gen in
    list_size (0 -- 20) (-3 -- 3)
  in
  (* Generated class: bounded integer action traces, including output-equal
     zero actions. Observation boundary: the synchronous pull query, driver
     delivery events, and delivery-token completion. *)
  QCheck.Test.make ~name:"qcheck_latest_committed_snapshot"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) actions)
    (fun actions ->
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1 machine
      in
      let driver =
        Crux.Driver.create
          (Crux.Driver.Binding.identity []) root
      in
      let observe expected =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) ->
            let pulled =
              latest_committed_snapshot driver
            in
            let still_delivering =
              run_ok (Crux.Driver.poll driver) = None
            in
            let delivered =
              run_ok
                (Crux.Driver.Delivery.delivered delivery)
              = Ok ()
            in
            (match pulled with
            | Some (model, _) -> model = expected
            | None -> false)
            && fst (output_of_delivery delivery) = expected
            && still_delivering && delivered
        | Some _ | None -> false
      in
      let before =
        latest_committed_snapshot driver = None
      in
      let initial = observe 0 in
      let _, endpoint =
        Option.get
          (latest_committed_snapshot driver)
      in
      let _, all_observed =
        List.fold_left
          (fun (expected, valid) action ->
            let admitted =
              run_ok
                (Crux.Endpoint.send endpoint action
                |> Eta.Effect.or_die (fun _ ->
                       Invalid_argument "ingress closed"))
              = ()
            in
            let expected = expected + action in
            (expected, valid && admitted && observe expected))
          (0, true) actions
      in
      before && initial && all_observed)

module Post_commit_observer =
  Eta_crux_test.Post_commit_effect_observer

let observer_driver ?observer apply_action =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0 ~apply_action
  in
  let root =
    Projection.root ~projection_capacity:1 ?post_commit_effect_observer:observer
      ~ingress_capacity:2 ~request_capacity:1 machine
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  (root, driver)

let observer_delivery = function
  | Some (Crux.Driver.Deliver delivery) -> delivery
  | Some _ | None -> failwith "expected observer-law delivery"

let complete_observer_delivery delivery =
  ignore (run_ok (Crux.Driver.Delivery.delivered delivery))

let qcheck_post_commit_effect_observer_inventory =
  let inventory =
    let open QCheck.Gen in
    list_size (0 -- 15) bool
  in
  (* Generated class: commits with empty or one-effect transition
     inventories, including [Some Effect.unit]. Observation boundary:
     per-commit Staged inventories, commit indices, unique effect identities,
     and complete lifecycle events after admission. *)
  QCheck.Test.make
    ~name:"qcheck_post_commit_effect_observer_inventory"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list bool) inventory)
    (fun inventory ->
      let observer = Post_commit_observer.create () in
      let _root, driver =
        observer_driver
          ~observer:(Post_commit_observer.attachment observer)
          (fun ~self:_ ~input:() ~model ~action ->
            (model + 1, if action then Some Eta.Effect.unit else None))
      in
      let initial =
        observer_delivery (run_ok (Crux.Driver.poll driver))
      in
      let _, endpoint = output_of_delivery initial in
      let initial_valid =
        match Post_commit_observer.poll observer with
        | Some
            (Post_commit_observer.Staged
              { commit; effects = []; _ }) ->
            Post_commit_observer.Commit_index.to_int64 commit = 0L
        | Some _ | None -> false
      in
      complete_observer_delivery initial;
      let _, valid, identities =
        List.fold_left
          (fun (index, valid, identities) present ->
            ignore
              (run_ok
                 (Crux.Endpoint.send endpoint present
                 |> Eta.Effect.or_die (fun _ ->
                        Invalid_argument "ingress closed")));
            let delivery =
              observer_delivery (run_ok (Crux.Driver.poll driver))
            in
            let stage =
              Post_commit_observer.poll observer
            in
            let stage_valid, identities =
              match stage, present with
              | Some
                  (Post_commit_observer.Staged
                    { commit; effects = [ effect ]; _ }),
                true ->
                  ( Post_commit_observer.Commit_index.to_int64 commit
                    = Int64.of_int index,
                    effect :: identities )
              | Some
                  (Post_commit_observer.Staged
                    { commit; effects = []; _ }),
                false ->
                  ( Post_commit_observer.Commit_index.to_int64 commit
                    = Int64.of_int index,
                    identities )
              | (Some _ | None), _ -> (false, identities)
            in
            complete_observer_delivery delivery;
            for _ = 1 to 3 do
              Eio.Fiber.yield ()
            done;
            let lifecycle =
              Post_commit_observer.drain observer
            in
            let lifecycle_valid =
              if present then
                match lifecycle with
                | [
                 Post_commit_observer.Started _;
                 Post_commit_observer.Settled
                   { settlement = Succeeded; _ };
                ] ->
                    true
                | _ -> false
              else lifecycle = []
            in
            ( index + 1,
              valid && stage_valid && lifecycle_valid,
              identities ))
          (1, initial_valid, []) inventory
      in
      let unique =
        List.sort_uniq Post_commit_observer.Effect_id.compare
          identities
        |> List.length
        = List.length identities
      in
      Crux.Driver.request_stop driver;
      ignore (run_ok (Crux.Driver.poll driver));
      valid && unique)

let qcheck_post_commit_effect_observer_fifo =
  let sample =
    let open QCheck.Gen in
    bind (2 -- 20) (fun count ->
        map (fun polled -> (count, polled)) (1 -- (count - 1)))
  in
  (* Generated class: queues of at least two empty-inventory commits with a
     non-empty poll prefix and drain suffix. Observation boundary: removed
     event positions, exact once-only removal, and final queue emptiness. *)
  QCheck.Test.make ~name:"qcheck_post_commit_effect_observer_fifo"
    ~count:100
    (QCheck.make
       ~print:(fun (count, polled) ->
         Printf.sprintf "{count=%d; polled=%d}" count polled)
       sample)
    (fun (count, polled) ->
      let observer = Post_commit_observer.create () in
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, None))
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:2 ~request_capacity:1 machine
      in
      let output, post = committed (run_ok (Crux.Root.advance root)) in
      let _, endpoint = output in
      start post;
      for _ = 2 to count do
        ignore
          (run_ok
             (Crux.Endpoint.send endpoint 1
             |> Eta.Effect.or_die (fun _ ->
                    Invalid_argument "ingress closed")));
        let _, post = committed (run_ok (Crux.Root.advance root)) in
        start post
      done;
      let rec take remaining events =
        if remaining = 0 then List.rev events
        else
          match Post_commit_observer.poll observer with
          | Some event -> take (remaining - 1) (event :: events)
          | None -> []
      in
      let events =
        take polled []
        @ Post_commit_observer.drain observer
      in
      let positions =
        List.map
          (function
            | Post_commit_observer.Staged { position; _ }
            | Post_commit_observer.Started { position; _ }
            | Post_commit_observer.Settled { position; _ }
            | Post_commit_observer.Discarded_before_start { position; _ } ->
                Post_commit_observer.Event_position.to_int64 position)
          events
      in
      let expected =
        List.init count Int64.of_int
      in
      let empty =
        Post_commit_observer.poll observer = None
      in
      Post_commit_observer.expect_empty observer;
      positions = expected && empty)

let qcheck_post_commit_effect_observer_lifecycle =
  (* Generated class: success, failure, interruption, and discard-before-start
     transition effects. Observation boundary: the exact accepted lifecycle
     trace for the one staged effect and its controlled production outcome. *)
  QCheck.Test.make
    ~name:"qcheck_post_commit_effect_observer_lifecycle"
    ~count:40 (QCheck.int_range 0 3)
    (fun outcome ->
      let observer = Post_commit_observer.create () in
      let root, driver =
        observer_driver
          ~observer:(Post_commit_observer.attachment observer)
          (fun ~self:_ ~input:() ~model ~action:_ ->
            let effect =
              match outcome with
              | 0 -> Eta.Effect.unit
              | 1 -> Eta.Effect.die_message "observed qcheck failure"
              | 2 -> Eta.Effect.never
              | _ -> Eta.Effect.unit
            in
            (model + 1, Some effect))
      in
      let initial =
        observer_delivery (run_ok (Crux.Driver.poll driver))
      in
      let _, endpoint = output_of_delivery initial in
      complete_observer_delivery initial;
      ignore (Post_commit_observer.drain observer);
      ignore
        (run_ok
           (Crux.Endpoint.send endpoint ()
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      let delivery =
        observer_delivery (run_ok (Crux.Driver.poll driver))
      in
      let effect =
        match Post_commit_observer.drain observer with
        | [
         Post_commit_observer.Staged
           { effects = [ effect ]; _ };
        ] ->
            effect
        | _ -> failwith "missing lifecycle stage"
      in
      if outcome = 3 then (
        let cause =
          Crux.Failure.Packed_cause.make
            ~pp_error:Format.pp_print_string
            (Eta.Cause.fail "discard")
        in
        ignore
          (run_ok
             (Crux.Driver.Delivery.failed delivery cause));
        ignore (run_ok (Crux.Driver.poll driver));
        ignore (run_ok (Crux.Driver.poll driver)))
      else (
        complete_observer_delivery delivery;
        for _ = 1 to 5 do
          Eio.Fiber.yield ()
        done;
        if outcome = 2 then (
          Crux.Driver.request_stop driver;
          ignore (run_ok (Crux.Driver.poll driver)))
        else if outcome = 1 then
          ignore (run_ok (Crux.Driver.poll driver)));
      for _ = 1 to 5 do
        Eio.Fiber.yield ()
      done;
      match outcome, Post_commit_observer.drain observer with
      | 0,
        [
         Post_commit_observer.Started { effect = started; _ };
         Post_commit_observer.Settled
           { effect = settled; settlement = Succeeded; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect started = 0
          && Post_commit_observer.Effect_id.compare effect settled = 0
      | 1,
        [
         Post_commit_observer.Started { effect = started; _ };
         Post_commit_observer.Settled
           { effect = settled; settlement = Failed; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect started = 0
          && Post_commit_observer.Effect_id.compare effect settled = 0
      | 2,
        [
         Post_commit_observer.Started { effect = started; _ };
         Post_commit_observer.Settled
           { effect = settled; settlement = Interrupted; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect started = 0
          && Post_commit_observer.Effect_id.compare effect settled = 0
      | 3,
        [
         Post_commit_observer.Discarded_before_start
           { effect = discarded; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect discarded = 0
      | _ -> false)

let qcheck_post_commit_effect_observer_order =
  (* Generated class: two overlapping controlled transition effects settled in
     either start order or the distinguishing reverse order. Observation
     boundary: event positions and effect identities in the complete trace. *)
  QCheck.Test.make
    ~name:"qcheck_post_commit_effect_observer_order"
    ~count:40 QCheck.bool
    (fun reverse ->
      let first = Eta.Promise.create () in
      let second = Eta.Promise.create () in
      let observer = Post_commit_observer.create () in
      let _root, driver =
        observer_driver
          ~observer:(Post_commit_observer.attachment observer)
          (fun ~self:_ ~input:() ~model ~action ->
            let promise = if action then second else first in
            (model + 1, Some (Eta.Promise.await promise)))
      in
      let initial =
        observer_delivery (run_ok (Crux.Driver.poll driver))
      in
      let _, endpoint = output_of_delivery initial in
      complete_observer_delivery initial;
      ignore (Post_commit_observer.drain observer);
      let admit action =
        ignore
          (run_ok
             (Crux.Endpoint.send endpoint action
             |> Eta.Effect.or_die (fun _ ->
                    Invalid_argument "ingress closed")));
        let delivery =
          observer_delivery (run_ok (Crux.Driver.poll driver))
        in
        complete_observer_delivery delivery
      in
      admit false;
      admit true;
      let resolve promise =
        ignore (run_ok (Eta.Promise.resolve promise (Eta.Exit.Ok ())));
        for _ = 1 to 5 do
          Eio.Fiber.yield ()
        done
      in
      if reverse then (
        resolve second;
        resolve first)
      else (
        resolve first;
        resolve second);
      Crux.Driver.request_stop driver;
      ignore (run_ok (Crux.Driver.poll driver));
      let events = Post_commit_observer.drain observer in
      let staged =
        List.filter_map
          (function
            | Post_commit_observer.Staged
                { effects = [ effect ]; _ } ->
                Some effect
            | _ -> None)
          events
      in
      let settled =
        List.filter_map
          (function
            | Post_commit_observer.Settled
                { effect; settlement = Succeeded; _ } ->
                Some effect
            | _ -> None)
          events
      in
      match staged, settled with
      | [ first_effect; second_effect ],
        [ settled_first; settled_second ] ->
          let expected_first =
            if reverse then second_effect else first_effect
          in
          let expected_second =
            if reverse then first_effect else second_effect
          in
          Post_commit_observer.Effect_id.compare
            expected_first settled_first
          = 0
          && Post_commit_observer.Effect_id.compare
               expected_second settled_second
             = 0
      | _ -> false)

let qcheck_post_commit_effect_observer_transparency =
  let actions =
    let open QCheck.Gen in
    list_size (0 -- 15) (-10 -- 10)
  in
  (* Generated class: bounded integer action traces. Observation boundary:
     admission results, complete delivered root outputs, normal terminal
     outcomes, and the attached observer's fully drained local trace. *)
  QCheck.Test.make
    ~name:"qcheck_post_commit_effect_observer_transparency"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) actions)
    (fun actions ->
      let run observer =
        let root, driver =
          observer_driver ?observer
            (fun ~self:_ ~input:() ~model ~action ->
              (model + action, None))
        in
        let initial =
          observer_delivery (run_ok (Crux.Driver.poll driver))
        in
        let model, endpoint = output_of_delivery initial in
        complete_observer_delivery initial;
        let outputs, admitted =
          List.fold_left
            (fun (outputs, admitted) action ->
              let sent =
                run_ok
                  (Eta.Effect.to_result
                     (Crux.Endpoint.send endpoint action))
              in
              let delivery =
                observer_delivery (run_ok (Crux.Driver.poll driver))
              in
              let output, _ = output_of_delivery delivery in
              complete_observer_delivery delivery;
              (output :: outputs, admitted && sent = Ok ()))
            ([ model ], true) actions
        in
        Crux.Driver.request_stop driver;
        let terminal =
          match run_ok (Crux.Driver.poll driver) with
          | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> `Stopped
          | _ -> `Unexpected
        in
        (List.rev outputs, admitted, terminal)
      in
      let observer = Post_commit_observer.create () in
      let without = run None in
      let with_observer =
        run
          (Some
             (Post_commit_observer.attachment observer))
      in
      ignore (Post_commit_observer.drain observer);
      Post_commit_observer.expect_empty observer;
      without = with_observer)

let reset_trigger reset =
  run_ok
    (Crux.Reset.trigger reset
    |> Eta.Effect.or_die (fun _ ->
           Invalid_argument "reset ingress closed"))

let reset_advance root =
  let output, post_commit =
    committed (run_ok (Crux.Root.advance root))
  in
  start post_commit;
  output

let qcheck_reset_default_custom =
  let sample =
    let open QCheck.Gen in
    pair (0 -- 2) (list_size (0 -- 20) bool)
  in
  (* Generated class: traces of ordinary increments and repeated reset
     triggers under default, preserving, and non-idempotent custom callbacks.
     Observation boundary: every complete committed model and callback count. *)
  QCheck.Test.make ~name:"qcheck_reset_default_custom"
    ~count:100
    (QCheck.make
       ~print:(fun (mode, operations) ->
         Printf.sprintf "{mode=%d; operations=%s}" mode
           (QCheck.Print.(list bool) operations))
       sample)
    (fun (mode, operations) ->
      let callbacks = ref 0 in
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let create ?reset () =
              Crux.State_machine.create ?reset input
                ~default_model:0
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model ~action ->
                  (model + action, None))
            in
            let machine =
              match mode with
              | 0 -> create ()
              | 1 ->
                  create
                    ~reset:(fun ~self:_ ~input:() ~model ->
                      incr callbacks;
                      (model, None))
                    ()
              | _ ->
                  create
                    ~reset:(fun ~self:_ ~input:() ~model ->
                      incr callbacks;
                      (model + 1, None))
                    ()
            in
            Crux.both reset machine)
      in
      let root =
        Projection.root ~projection_capacity:1
          ~ingress_capacity:(max 1 (List.length operations))
          ~request_capacity:1 description
      in
      let reset, (model, endpoint) = reset_advance root in
      let _, expected, valid, _ =
        List.fold_left
          (fun (resets, expected, valid, endpoint) operation ->
            if operation then reset_trigger reset
            else
              ignore
                (run_ok
                   (Crux.Endpoint.send endpoint 1
                   |> Eta.Effect.or_die (fun _ ->
                          Invalid_argument "ingress closed")));
            let _, (model, next_endpoint) =
              reset_advance root
            in
            let expected =
              if operation then
                match mode with
                | 0 -> 0
                | 1 -> expected
                | _ -> expected + 1
              else expected + 1
            in
            ( resets + (if operation then 1 else 0),
              expected,
              valid && model = expected,
              next_endpoint ))
          (0, model, model = 0, endpoint) operations
      in
      let resets =
        List.length (List.filter Fun.id operations)
      in
      valid
      && !callbacks = if mode = 0 then 0 else resets)

let qcheck_reset_snapshot_atomicity =
  let sample =
    let open QCheck.Gen in
    pair (-100 -- 100) (-100 -- 100)
  in
  (* Generated class: two-cell reset snapshots with independently generated
     pre-reset models. Observation boundary: callback witnesses and the one
     complete post-reset root output. *)
  QCheck.Test.make ~name:"qcheck_reset_snapshot_atomicity"
    ~count:100
    (QCheck.make
       ~print:(fun (left, right) ->
         Printf.sprintf "(%d,%d)" left right)
       sample)
    (fun (left_value, right_value) ->
      let left_seen = ref None in
      let right_seen = ref None in
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let machine seen delta =
              Crux.State_machine.create input ~default_model:0
                ~reset:(fun ~self:_ ~input:() ~model ->
                  seen := Some model;
                  (model + delta, None))
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model:_ ~action ->
                  (action, None))
            in
            Crux.both reset
              (Crux.both
                 (machine left_seen 1_000)
                 (machine right_seen 10_000)))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:3
          ~request_capacity:1 description
      in
      let reset, ((_, left_endpoint), (_, right_endpoint)) =
        reset_advance root
      in
      ignore
        (run_ok
           (Crux.Endpoint.send left_endpoint left_value
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      ignore
        (run_ok
           (Crux.Endpoint.send right_endpoint right_value
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      reset_trigger reset;
      let _, ((left_model, _), (right_model, _)) =
        reset_advance root
      in
      !left_seen = Some left_value
      && !right_seen = Some right_value
      && left_model = left_value + 1_000
      && right_model = right_value + 10_000)

let qcheck_reset_ingress_order =
  let operations =
    let open QCheck.Gen in
    list_size (1 -- 20) bool
  in
  (* Generated class: non-empty FIFO traces where [false] is Action (+1) and
     [true] is reset (2*n+1). All items are admitted before advancement.
     Observation boundary: every committed model in queue order. *)
  QCheck.Test.make ~name:"qcheck_reset_ingress_order"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list bool) operations)
    (fun operations ->
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let machine =
              Crux.State_machine.create input ~default_model:1
                ~reset:(fun ~self:_ ~input:() ~model ->
                  ((2 * model) + 1, None))
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model ~action:() ->
                  (model + 1, None))
            in
            Crux.both reset machine)
      in
      let root =
        Projection.root ~projection_capacity:1
          ~ingress_capacity:(List.length operations)
          ~request_capacity:1 description
      in
      let reset, (_, endpoint) = reset_advance root in
      List.iter
        (fun operation ->
          if operation then reset_trigger reset
          else
            ignore
              (run_ok
                 (Crux.Endpoint.send endpoint ()
                 |> Eta.Effect.or_die (fun _ ->
                        Invalid_argument "ingress closed"))))
        operations;
      let _, valid =
        List.fold_left
          (fun (expected, valid) operation ->
            let _, (model, _) = reset_advance root in
            let expected =
              if operation then (2 * expected) + 1
              else expected + 1
            in
            (expected, valid && model = expected))
          (1, true) operations
      in
      valid)

let qcheck_reset_scope_boundary =
  let sample =
    let open QCheck.Gen in
    triple bool (-100 -- 100) (-100 -- 100)
  in
  (* Generated class: nested outer/inner reset scopes with independently
     generated active models and either selected authority. Observation
     boundary: the complete two-model output after one reset. *)
  QCheck.Test.make ~name:"qcheck_reset_scope_boundary"
    ~count:100
    (QCheck.make
       ~print:(fun (outer, left, right) ->
         Printf.sprintf "{outer=%b; left=%d; right=%d}"
           outer left right)
       sample)
    (fun (use_outer, left_value, right_value) ->
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset:outer_reset ~input ->
            let outer =
              Crux.State_machine.create input ~default_model:0
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model:_ ~action ->
                  (action, None))
            in
            let inner =
              Crux.Reset.scope input
                ~f:(fun ~reset:inner_reset ~input ->
                  let machine =
                    Crux.State_machine.create input
                      ~default_model:0
                      ~apply_action:(fun ~self:_ ~input:()
                                        ~model:_ ~action ->
                        (action, None))
                  in
                  Crux.both inner_reset machine)
            in
            Crux.both outer_reset (Crux.both outer inner))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:3
          ~request_capacity:1 description
      in
      let outer_reset,
          ((_, outer_endpoint),
           (inner_reset, (_, inner_endpoint))) =
        reset_advance root
      in
      ignore
        (run_ok
           (Crux.Endpoint.send outer_endpoint left_value
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      ignore
        (run_ok
           (Crux.Endpoint.send inner_endpoint right_value
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      reset_trigger (if use_outer then outer_reset else inner_reset);
      let _, ((left, _), (_, (right, _))) =
        reset_advance root
      in
      if use_outer then left = 0 && right = 0
      else left = left_value && right = 0)

let qcheck_reset_dynamic_children =
  (* Generated class: either initial bind branch. Each outer reset flips the
     selector and therefore removes one child and creates the other.
     Observation boundary: authority stability, child endpoint incarnation,
     and the new child's default model. *)
  QCheck.Test.make ~name:"qcheck_reset_dynamic_children"
    ~count:50 QCheck.bool
    (fun initial ->
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let selector =
              Crux.State_machine.create input
                ~default_model:initial
                ~reset:(fun ~self:_ ~input:() ~model ->
                  (not model, None))
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model:_ ~action ->
                  (action, None))
            in
            let child =
              Crux.bind selector
                ~f:(fun (selected, _) ->
                  Crux.State_machine.create input
                    ~default_model:(if selected then 10 else 20)
                    ~apply_action:(fun ~self:_ ~input:()
                                      ~model ~action:_ ->
                      (model, None)))
            in
            Crux.both reset (Crux.both selector child))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1
          ~request_capacity:1 description
      in
      let authority,
          ((selected, _), (child_model, child_endpoint)) =
        reset_advance root
      in
      let initial_valid =
        selected = initial
        && child_model = (if initial then 10 else 20)
      in
      reset_trigger authority;
      let next_authority,
          ((selected, _), (child_model, next_endpoint)) =
        reset_advance root
      in
      let bind_valid =
        initial_valid
        && authority == next_authority
        && selected = not initial
        && child_model = (if initial then 20 else 10)
        && child_endpoint != next_endpoint
      in
      let initial_map =
        Int_map.empty
        |> Int_map.set 0 0
        |> Int_map.set 1 1
      in
      let target_map =
        Int_map.empty
        |> Int_map.set 1 1
        |> Int_map.set 2 2
      in
      let assoc_description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let parent =
              Crux.State_machine.create input
                ~default_model:initial_map
                ~reset:(fun ~self:_ ~input:() ~model:_ ->
                  (target_map, None))
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model:_ ~action ->
                  (action, None))
            in
            let module Assoc = Crux.Assoc (Int) in
            let children =
              Assoc.assoc (Crux.map parent ~f:fst)
                ~f:(fun ~key ~data ->
                  Crux.State_machine.create data
                    ~default_model:(key * 10)
                    ~reset:(fun ~self:_ ~input:_ ~model ->
                      (model + 100, None))
                    ~apply_action:(fun ~self:_ ~input:_
                                      ~model ~action:_ ->
                      (model, None)))
            in
            Crux.both reset (Crux.both parent children))
      in
      let assoc_root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:1
          ~request_capacity:1 assoc_description
      in
      let assoc_reset, (_, children) =
        reset_advance assoc_root
      in
      let _, retained_endpoint =
        int_map_find 1 children
      in
      reset_trigger assoc_reset;
      let _, (_, next_children) =
        reset_advance assoc_root
      in
      let retained_model, next_retained_endpoint =
        int_map_find 1 next_children
      in
      let added_model, _ = int_map_find 2 next_children in
      bind_valid
      && not (Int_map.mem 0 next_children)
      && retained_model = 110
      && retained_endpoint == next_retained_endpoint
      && added_model = 20)

let qcheck_reset_effect_lifecycle =
  let inventories =
    let open QCheck.Gen in
    list_size (0 -- 8) bool
  in
  (* Generated class: reset scopes with zero through many callbacks, each
     independently returning None or Some Effect.unit. Observation boundary:
     exact Staged inventory and one successful lifecycle per present effect. *)
  QCheck.Test.make ~name:"qcheck_reset_effect_lifecycle"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list bool) inventories)
    (fun inventories ->
      let observer = Post_commit_observer.create () in
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let machines =
              List.fold_left
                (fun machines present ->
                  let machine =
                    Crux.State_machine.create input ~default_model:()
                      ~reset:(fun ~self:_ ~input:() ~model:() ->
                        ( (),
                          if present then Some Eta.Effect.unit
                          else None ))
                      ~apply_action:(fun ~self:_ ~input:()
                                        ~model:() ~action:() ->
                        ((), None))
                    |> Crux.map ~f:(fun _ -> ())
                  in
                  Crux.map (Crux.both machines machine)
                    ~f:(fun _ -> ()))
                (Crux.return ()) inventories
            in
            Crux.both reset machines)
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1 description
      in
      let reset, _ = reset_advance root in
      ignore (Post_commit_observer.drain observer);
      reset_trigger reset;
      let _, post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let effects =
        match Post_commit_observer.drain observer with
        | [
         Post_commit_observer.Staged { effects; _ };
        ] ->
            effects
        | _ -> []
      in
      start post_commit;
      for _ = 1 to 5 do
        Eio.Fiber.yield ()
      done;
      let events = Post_commit_observer.drain observer in
      let started =
        List.filter
          (function Post_commit_observer.Started _ -> true | _ -> false)
          events
        |> List.length
      in
      let settled =
        List.filter
          (function
            | Post_commit_observer.Settled
                { settlement = Succeeded; _ } ->
                true
            | _ -> false)
          events
        |> List.length
      in
      let expected =
        List.length (List.filter Fun.id inventories)
      in
      List.length effects = expected
      && started = expected && settled = expected)

let qcheck_reset_authority_incarnation =
  (* Generated class: one through five disposal/re-entry cycles. Observation
     boundary: stale rejection for every disposed authority and successful
     commit through every fresh authority. *)
  QCheck.Test.make ~name:"qcheck_reset_authority_incarnation"
    ~count:50 (QCheck.int_range 1 5)
    (fun cycles ->
      let selector =
        Crux.State_machine.create (Crux.return ())
          ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.bind selector
          ~f:(fun (active, endpoint) ->
            if active then
              Crux.Reset.scope (Crux.return ())
                ~f:(fun ~reset ~input:_ ->
                  Crux.map reset ~f:(fun reset ->
                    (endpoint, Some reset)))
            else Crux.return (endpoint, None))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1 description
      in
      let endpoint, reset = reset_advance root in
      let rec loop remaining previous =
        if remaining = 0 then true
        else (
          ignore
            (run_ok
               (Crux.Endpoint.send endpoint false
               |> Eta.Effect.or_die (fun _ ->
                      Invalid_argument "ingress closed")));
          ignore (reset_advance root);
          reset_trigger previous;
          let stale =
            run_ok (Crux.Root.advance root)
            = Ok (Crux.Root.Rejected Crux.Root.Stale_reset)
          in
          ignore
            (run_ok
               (Crux.Endpoint.send endpoint true
               |> Eta.Effect.or_die (fun _ ->
                      Invalid_argument "ingress closed")));
          let _, next = reset_advance root in
          let next = Option.get next in
          stale && previous != next
          && loop (remaining - 1) next)
      in
      loop cycles (Option.get reset))

let invoke_poll_refresh
    (refresh :
      (unit, Crux.Endpoint.admission_error) Eta.Effect.t) =
  run_ok
    (refresh
    |> Eta.Effect.or_die (fun _ ->
           Invalid_argument "Poll refresh ingress closed"))

let qcheck_poll_committed_run_order =
  let sample =
    let open QCheck.Gen in
    bind (2 -- 5) (fun count ->
        map (fun priorities -> (count, priorities))
          (list_size (return count) int))
  in
  (* Generated class: two through five concurrent manual runs and every
     key-induced completion permutation. Observation boundary: committed Poll
     outputs after each completion ingress advancement. *)
  QCheck.Test.make ~name:"qcheck_poll_committed_run_order"
    ~count:100
    (QCheck.make
       ~print:(fun (count, priorities) ->
         Printf.sprintf "{count=%d; priorities=%s}" count
           (QCheck.Print.(list int) priorities))
       sample)
    (fun (count, priorities) ->
      let permutation =
        priorities
        |> List.mapi (fun index priority -> (priority, index))
        |> List.sort compare
        |> List.map snd
      in
      let controlled = Eta_test.Controlled.create () in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:Crux.Poll.Starting.empty
          ~effect:
            (Crux.return (Eta_test.Controlled.eff controlled ()))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:(count + 1)
          ~request_capacity:1 (Crux.both result refresh)
      in
      let _, refresh = reset_advance root in
      let calls =
        List.init count (fun _ ->
            invoke_poll_refresh refresh;
            ignore (reset_advance root);
            run_ok (Eta_test.Controlled.await_call controlled))
      in
      List.iter
        (fun index ->
          ignore
            (Eta_test.Controlled.succeed
               (List.nth calls index) index);
          for _ = 1 to 3 do
            Eio.Fiber.yield ()
          done)
        permutation;
      let _, valid =
        List.fold_left
          (fun (greatest, valid) completed ->
            let result, _ = reset_advance root in
            let greatest = max greatest completed in
            (greatest, valid && result = Some greatest))
          (-1, true) permutation
      in
      valid)

let qcheck_poll_manual_refresh_admission =
  (* Generated class: one through twelve refresh effects admitted into an
     exactly-sized root FIFO before any refresh advancement. Observation
     boundary: successful trigger commits, provider-call count, completion
     commits, and final result. *)
  QCheck.Test.make ~name:"qcheck_poll_manual_refresh_admission"
    ~count:50 (QCheck.int_range 1 12)
    (fun count ->
      let calls = ref 0 in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:Crux.Poll.Starting.empty
          ~effect:
            (Crux.return
               (Eta.Effect.sync (fun () ->
                    incr calls;
                    !calls)))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:count
          ~request_capacity:1 (Crux.both result refresh)
      in
      let _, refresh = reset_advance root in
      for _ = 1 to count do
        invoke_poll_refresh refresh
      done;
      for _ = 1 to count do
        ignore (reset_advance root);
        Eio.Fiber.yield ()
      done;
      for _ = 1 to count do
        ignore (reset_advance root)
      done;
      !calls = count)

let qcheck_poll_input_cutoff =
  let sample =
    let open QCheck.Gen in
    pair (0 -- 2) (list_size (0 -- 15) (-3 -- 3))
  in
  (* Generated class: candidate input traces under never, value-equality, and
     always-suppress cutoffs. The input state machine publishes equal values.
     Observation boundary: provider call count after each committed candidate. *)
  QCheck.Test.make ~name:"qcheck_poll_input_cutoff"
    ~count:100
    (QCheck.make
       ~print:(fun (mode, inputs) ->
         Printf.sprintf "{mode=%d; inputs=%s}" mode
           (QCheck.Print.(list int) inputs))
       sample)
    (fun (mode, inputs) ->
      let calls = ref 0 in
      let input =
        Crux.State_machine.create
          ~model_cutoff:Crux.Cutoff.never
          (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let cutoff =
        match mode with
        | 0 -> Crux.Cutoff.never
        | 1 -> Crux.Cutoff.of_equal Int.equal
        | _ -> Crux.Cutoff.always
      in
      let polled =
        Crux.Poll.effect_on_change ~input_cutoff:cutoff
          ~starting:Crux.Poll.Starting.empty
          ~input:(Crux.map input ~f:fst)
          ~effect:
            (Crux.return (fun value ->
                 Eta.Effect.sync (fun () ->
                     incr calls;
                     value)))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1 (Crux.both input polled)
      in
      let (_, endpoint), _ = reset_advance root in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      ignore (reset_advance root);
      let previous = ref 0 in
      let expected = ref 1 in
      List.iter
        (fun candidate ->
          ignore
            (run_ok
               (Crux.Endpoint.send endpoint candidate
               |> Eta.Effect.or_die (fun _ ->
                      Invalid_argument "ingress closed")));
          ignore (reset_advance root);
          let trigger =
            match mode with
            | 0 -> true
            | 1 -> not (Int.equal !previous candidate)
            | _ -> false
          in
          previous := candidate;
          if trigger then (
            incr expected;
            for _ = 1 to 3 do
              Eio.Fiber.yield ()
            done;
            ignore (reset_advance root)))
        inputs;
      !calls = !expected)

let qcheck_poll_starting_incarnation =
  (* Generated class: both Starting forms and bind disposal/re-entry.
     Observation boundary: starting outputs and stale old refresh rejection. *)
  QCheck.Test.make ~name:"qcheck_poll_starting_incarnation"
    ~count:50 QCheck.(pair bool int)
    (fun (empty, initial) ->
      let selector =
        Crux.State_machine.create (Crux.return ())
          ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.bind selector
          ~f:(fun (active, endpoint) ->
            if not active then Crux.return (endpoint, None)
            else
              let result, refresh =
                if empty then
                  Crux.Poll.manual_refresh
                    ~starting:Crux.Poll.Starting.empty
                    ~effect:(Crux.return (Eta.Effect.pure initial)) ()
                else
                  let result, refresh =
                    Crux.Poll.manual_refresh
                      ~starting:(Crux.Poll.Starting.initial initial)
                      ~effect:(Crux.return (Eta.Effect.pure initial)) ()
                  in
                  (Crux.map result ~f:Option.some, refresh)
              in
              Crux.map (Crux.both result refresh)
                ~f:(fun (result, refresh) ->
                  (endpoint, Some (result, refresh))))
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1 description
      in
      let endpoint, active = reset_advance root in
      let starting, old_refresh = Option.get active in
      let starting_valid =
        if empty then starting = None
        else starting = Some initial
      in
      ignore
        (run_ok
           (Crux.Endpoint.send endpoint false
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      ignore
        (run_ok
           (Crux.Endpoint.send endpoint true
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      let _, reentered = reset_advance root in
      let next_starting, _ = Option.get reentered in
      invoke_poll_refresh old_refresh;
      let stale =
        run_ok (Crux.Root.advance root)
        = Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint)
      in
      starting_valid && next_starting = starting && stale)

let qcheck_poll_run_order_overflow =
  (* White-box generated class: the private order claim is placed at
     exhaustion immediately before one production manual-refresh transition.
     Observation boundary: root failure attribution, prior output, provider
     witness, and absence of a successful observer commit. *)
  QCheck.Test.make ~name:"qcheck_poll_run_order_overflow"
    ~count:10 QCheck.unit
    (fun () ->
      let observer = Post_commit_observer.create () in
      let provider_calls = ref 0 in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:(Crux.Poll.Starting.initial 7)
          ~effect:
            (Crux.return
               (Eta.Effect.sync (fun () ->
                    incr provider_calls;
                    9)))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1
          (Crux.both result refresh)
      in
      let output, refresh = reset_advance root in
      ignore output;
      ignore (Post_commit_observer.drain observer);
      invoke_poll_refresh refresh;
      let previous =
        Eta_crux__Crux_poll_barrier.set_before_order_claim
          (fun order -> order := Int64.max_int)
      in
      let outcome = run_ok (Crux.Root.advance root) in
      let (_ : int64 ref -> unit) =
        Eta_crux__Crux_poll_barrier.set_before_order_claim
          previous
      in
      match outcome with
      | Ok (Crux.Root.Failed { failure; _ }) ->
          failure.Crux.Failure.primary.origin = Crux.Failure.Transition
          && failure.Crux.Failure.primary.trigger
             = Crux.Failure.Endpoint_action
          && !provider_calls = 0
          && Post_commit_observer.drain observer = []
      | _ -> false)

let qcheck_poll_provider_sampling =
  let multipliers =
    let open QCheck.Gen in
    list_size (0 -- 10) (1 -- 10)
  in
  (* Generated class: zero through ten provider-only replacements followed by
     one input trigger. Observation boundary: provider-call labels and Poll
     output; replacements alone must start no run. *)
  QCheck.Test.make ~name:"qcheck_poll_provider_sampling"
    ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) multipliers)
    (fun multipliers ->
      let calls = ref [] in
      let input =
        Crux.State_machine.create (Crux.return ())
          ~default_model:1
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let provider =
        Crux.State_machine.create (Crux.return ())
          ~default_model:1
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let polled =
        Crux.Poll.effect_on_change
          ~input_cutoff:(Crux.Cutoff.of_equal Int.equal)
          ~starting:Crux.Poll.Starting.empty
          ~input:(Crux.map input ~f:fst)
          ~effect:
            (Crux.map provider ~f:(fun (multiplier, _) value ->
                 Eta.Effect.sync (fun () ->
                     calls := (value, multiplier) :: !calls;
                     value * multiplier)))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1
          (Crux.both input (Crux.both provider polled))
      in
      let (input_output, (provider_output, _)) =
        reset_advance root
      in
      let _, input_endpoint = input_output in
      let _, provider_endpoint = provider_output in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      ignore (reset_advance root);
      List.iter
        (fun multiplier ->
          ignore
            (run_ok
               (Crux.Endpoint.send provider_endpoint multiplier
               |> Eta.Effect.or_die (fun _ ->
                      Invalid_argument "ingress closed")));
          ignore (reset_advance root);
          for _ = 1 to 2 do
            Eio.Fiber.yield ()
          done)
        multipliers;
      let before = List.length !calls in
      ignore
        (run_ok
           (Crux.Endpoint.send input_endpoint 2
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      ignore (reset_advance root);
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      let expected_multiplier =
        match List.rev multipliers with
        | multiplier :: _ -> multiplier
        | [] -> 1
      in
      before = 1
      && List.hd !calls = (2, expected_multiplier))

let qcheck_poll_activation_and_coalescing =
  let sample =
    let open QCheck.Gen in
    triple (-20 -- 20) (-20 -- 20) (1 -- 10)
  in
  (* Generated class: one reset advancement changes two Poll input
     dependencies. Observation boundary: exact one-effect inventory and one
     provider call carrying the latest stabilized sum. *)
  QCheck.Test.make
    ~name:"qcheck_poll_activation_and_coalescing"
    ~count:100
    (QCheck.make
       ~print:(fun (left, right, delta) ->
         Printf.sprintf "{left=%d; right=%d; delta=%d}"
           left right delta)
       sample)
    (fun (left, right, delta) ->
      let observer = Post_commit_observer.create () in
      let calls = ref [] in
      let description =
        Crux.Reset.scope (Crux.return ())
          ~f:(fun ~reset ~input ->
            let machine initial =
              Crux.State_machine.create input
                ~default_model:initial
                ~reset:(fun ~self:_ ~input:() ~model ->
                  (model + delta, None))
                ~apply_action:(fun ~self:_ ~input:()
                                  ~model ~action:_ ->
                  (model, None))
            in
            let left = machine left in
            let right = machine right in
            let polled =
              Crux.Poll.effect_on_change
                ~input_cutoff:(Crux.Cutoff.of_equal Int.equal)
                ~starting:Crux.Poll.Starting.empty
                ~input:
                  (Crux.map (Crux.both left right)
                     ~f:(fun ((left, _), (right, _)) ->
                       left + right))
                ~effect:
                  (Crux.return (fun value ->
                       Eta.Effect.sync (fun () ->
                           calls := value :: !calls;
                           value)))
                ()
            in
            Crux.both reset polled)
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1 description
      in
      let reset, _ = reset_advance root in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      ignore (reset_advance root);
      ignore (Post_commit_observer.drain observer);
      reset_trigger reset;
      let _, post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let inventory =
        match Post_commit_observer.drain observer with
        | [
         Post_commit_observer.Staged { effects; _ };
        ] ->
            List.length effects
        | _ -> -1
      in
      start post_commit;
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      inventory = 1
      && List.hd !calls = left + right + (2 * delta))

let qcheck_poll_result_cutoff_order_fence =
  let sample =
    let open QCheck.Gen in
    triple (-100 -- 100) (1 -- 20) (-100 -- 100)
  in
  (* Generated class: newer-equal, older-different, and later completions.
     Observation boundary: result-cutoff calls and committed output after each
     hidden completion. *)
  QCheck.Test.make
    ~name:"qcheck_poll_result_cutoff_order_fence"
    ~count:100
    (QCheck.make
       ~print:(fun (initial, older_delta, later) ->
         Printf.sprintf "{initial=%d; older_delta=%d; later=%d}"
           initial older_delta later)
       sample)
    (fun (initial, older_delta, later) ->
      let controlled = Eta_test.Controlled.create () in
      let cutoff_calls = ref 0 in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~result_cutoff:
            (Crux.Cutoff.of_equal (fun left right ->
                 incr cutoff_calls;
                 Int.equal left right))
          ~starting:(Crux.Poll.Starting.initial initial)
          ~effect:
            (Crux.return (Eta_test.Controlled.eff controlled ()))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:4
          ~request_capacity:1 (Crux.both result refresh)
      in
      let _, refresh = reset_advance root in
      let start_run () =
        invoke_poll_refresh refresh;
        ignore (reset_advance root);
        run_ok (Eta_test.Controlled.await_call controlled)
      in
      let older = start_run () in
      let newer_equal = start_run () in
      ignore (Eta_test.Controlled.succeed newer_equal initial);
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      ignore
        (Eta_test.Controlled.succeed older
           (initial + older_delta));
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      let equal, _ = reset_advance root in
      let stale, _ = reset_advance root in
      let calls_after_stale = !cutoff_calls in
      let latest = start_run () in
      ignore (Eta_test.Controlled.succeed latest later);
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      let latest, _ = reset_advance root in
      equal = initial
      && stale = initial
      && calls_after_stale = 1
      && !cutoff_calls = 2
      && latest = later)

let qcheck_poll_failure_attribution =
  (* Generated class: provider-start exceptions and body defects.
     Observation boundary: root failure attribution and observer settlement. *)
  QCheck.Test.make ~name:"qcheck_poll_failure_attribution"
    ~count:40 QCheck.bool
    (fun provider_raises ->
      let observer = Post_commit_observer.create () in
      let provider =
        if provider_raises then
          fun () -> raise (Failure "provider start defect")
        else fun () -> Eta.Effect.die_message "Poll body defect"
      in
      let polled =
        Crux.Poll.effect_on_change
          ~input_cutoff:Crux.Cutoff.never
          ~starting:Crux.Poll.Starting.empty
          ~input:(Crux.return ()) ~effect:(Crux.return provider) ()
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1 polled
      in
      ignore (reset_advance root);
      for _ = 1 to 5 do
        Eio.Fiber.yield ()
      done;
      let failure =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Failed { failure; _ }) -> Some failure
        | _ -> None
      in
      let events = Post_commit_observer.drain observer in
      let failed_settlement =
        List.exists
          (function
            | Post_commit_observer.Settled
                { settlement = Failed; _ } ->
                true
            | _ -> false)
          events
      in
      match failure with
      | Some failure ->
          failure.Crux.Failure.primary.origin
          = Crux.Failure.Owned_work
          && failure.Crux.Failure.primary.trigger
             = Crux.Failure.Poll_effect
          && failed_settlement
      | None -> false)

let qcheck_poll_clock_priority =
  (* Generated class: a queued integer Action and one simultaneously due clock
     input. Observation boundary: first committed output, Poll inventory,
     provider witness, and the still-queued Action's next output. *)
  QCheck.Test.make ~name:"qcheck_poll_clock_priority"
    ~count:40 (QCheck.int_range 1 100)
    (fun action ->
      let calls = ref [] in
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let due = Crux.Time.after (Eta.Duration.ms 10) in
      let polled =
        Crux.Poll.effect_on_change
          ~input_cutoff:(Crux.Cutoff.of_equal Bool.equal)
          ~starting:Crux.Poll.Starting.empty
          ~input:due
          ~effect:
            (Crux.return (fun due ->
                 Eta.Effect.sync (fun () ->
                     calls := due :: !calls;
                     due)))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1 (Crux.both machine polled)
      in
      let (_, endpoint), _ = reset_advance root in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      ignore (reset_advance root);
      ignore
        (run_ok
           (Crux.Endpoint.send endpoint action
           |> Eta.Effect.or_die (fun _ ->
                  Invalid_argument "ingress closed")));
      Eta_test.Test_clock.adjust (law_clock ())
        (Eta.Duration.ms 10);
      let (model_at_due, _), _ = reset_advance root in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      let (model_after_action, _), _ = reset_advance root in
      model_at_due = 0
      && model_after_action = action
      && List.hd !calls = true)

let qcheck_poll_completion_fifo =
  (* Generated class: both FIFO orders between one application Action and one
     Poll completion. Observation boundary: the next two committed complete
     outputs. *)
  QCheck.Test.make ~name:"qcheck_poll_completion_fifo"
    ~count:50 QCheck.bool
    (fun completion_first ->
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action:() ->
            (model + 1, None))
      in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:Crux.Poll.Starting.empty
          ~effect:(Crux.return (Eta.Effect.pure 9)) ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:2
          ~request_capacity:1
          (Crux.both machine (Crux.both result refresh))
      in
      let (_, endpoint), (_, refresh) = reset_advance root in
      if completion_first then (
        invoke_poll_refresh refresh;
        ignore (reset_advance root);
        for _ = 1 to 3 do
          Eio.Fiber.yield ()
        done;
        ignore
          (run_ok
             (Crux.Endpoint.send endpoint ()
             |> Eta.Effect.or_die (fun _ ->
                    Invalid_argument "ingress closed")));
        let (first_model, _), (first_result, _) =
          reset_advance root
        in
        let (second_model, _), (second_result, _) =
          reset_advance root
        in
        first_model = 0 && first_result = Some 9
        && second_model = 1 && second_result = Some 9)
      else (
        ignore
          (run_ok
             (Crux.Endpoint.send endpoint ()
             |> Eta.Effect.or_die (fun _ ->
                    Invalid_argument "ingress closed")));
        invoke_poll_refresh refresh;
        let (first_model, _), (first_result, _) =
          reset_advance root
        in
        let (second_model, _), (second_result, _) =
          reset_advance root
        in
        for _ = 1 to 3 do
          Eio.Fiber.yield ()
        done;
        let (third_model, _), (third_result, _) =
          reset_advance root
        in
        first_model = 1 && first_result = None
        && second_model = 1 && second_result = None
        && third_model = 1 && third_result = Some 9))

let qcheck_poll_run_order =
  (* Generated class: two through six runs completed in strict reverse order.
     Observation boundary: every committed output and the final greatest run. *)
  QCheck.Test.make ~name:"qcheck_poll_run_order"
    ~count:50 (QCheck.int_range 2 6)
    (fun count ->
      let controlled = Eta_test.Controlled.create () in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:Crux.Poll.Starting.empty
          ~effect:
            (Crux.return (Eta_test.Controlled.eff controlled ()))
          ()
      in
      let root =
        Projection.root ~projection_capacity:1 ~ingress_capacity:(count + 1)
          ~request_capacity:1 (Crux.both result refresh)
      in
      let _, refresh = reset_advance root in
      let calls =
        List.init count (fun _ ->
            invoke_poll_refresh refresh;
            ignore (reset_advance root);
            run_ok (Eta_test.Controlled.await_call controlled))
      in
      List.iter
        (fun index ->
          ignore
            (Eta_test.Controlled.succeed
               (List.nth calls index) index);
          Eio.Fiber.yield ())
        (List.init count (fun offset -> count - offset - 1));
      let outputs =
        List.init count (fun _ -> fst (reset_advance root))
      in
      match outputs with
      | Some newest :: stale ->
          newest = count - 1
          && List.for_all (( = ) (Some newest)) stale
      | None :: _ | [] -> false)

let qcheck_post_commit_effect_observer_poll_lifecycle =
  (* Generated class: admitted Poll work either starts and succeeds or is
     terminally replaced before start. Observation boundary: exact Poll
     identity path in the observer queue. *)
  QCheck.Test.make
    ~name:"qcheck_post_commit_effect_observer_poll_lifecycle"
    ~count:40 QCheck.bool
    (fun discard ->
      let observer = Post_commit_observer.create () in
      let result, refresh =
        Crux.Poll.manual_refresh
          ~starting:Crux.Poll.Starting.empty
          ~effect:(Crux.return (Eta.Effect.pure 1)) ()
      in
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:
            (Post_commit_observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1
          (Crux.both result refresh)
      in
      let _, refresh = reset_advance root in
      ignore (Post_commit_observer.drain observer);
      invoke_poll_refresh refresh;
      let _, post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let effect =
        match Post_commit_observer.drain observer with
        | [
         Post_commit_observer.Staged
           { effects = [ effect ]; _ };
        ] ->
            effect
        | _ -> failwith "missing Poll observer stage"
      in
      if discard then Crux.Root.request_stop root;
      start post_commit;
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      match discard, Post_commit_observer.drain observer with
      | true,
        [
         Post_commit_observer.Discarded_before_start
           { effect = discarded; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect discarded = 0
      | false,
        [
         Post_commit_observer.Started { effect = started; _ };
         Post_commit_observer.Settled
           { effect = settled; settlement = Succeeded; _ };
        ] ->
          Post_commit_observer.Effect_id.compare effect started = 0
          && Post_commit_observer.Effect_id.compare effect settled = 0
      | _ -> false)

(* ---------- Graph time and deterministic clock (GTC) ---------- *)

let shared_switch : Eio.Switch.t option ref = ref None

let law_switch () =
  match !shared_switch with
  | Some switch -> switch
  | None -> failwith "law switch is not installed"

let driver_output driver =
  match run_ok (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Deliver delivery) ->
      let output = output_of_delivery delivery in
      (match run_ok (Crux.Driver.Delivery.delivered delivery) with
      | Ok () -> ()
      | Error Crux.Driver.Delivery.Already_completed ->
          failwith "delivery completed twice");
      output
  | _ -> failwith "expected projection delivery"

let identity_driver root =
  Crux.Driver.create (Crux.Driver.Binding.identity []) root

let time_root description =
  Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1 description

let counting_clock clock =
  let reads = ref 0 in
  let capability : Eta.Capabilities.clock =
    object
      method now_ms () =
        incr reads;
        Eta_test.Test_clock.now_ms clock

      method sleep duration = Eta_test.Test_clock.sleep clock duration
    end
  in
  (capability, reads)

let wait_for_sleeper clock =
  let rec loop attempts =
    if Eta_test.Test_clock.sleeper_count clock >= 1 then ()
    else if attempts = 0 then
      failwith "driver never registered a deadline sleeper"
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 40

let qcheck_graph_time_initial_binding =
  (* Generated class: one interval timer per iteration. Observation
     boundary: the initial commit, then one foreign-clock advancement. *)
  QCheck.Test.make ~name:"qcheck_graph_time_initial_binding"
    ~count:50 (QCheck.map (fun x -> 1 + x) (QCheck.int_range 0 19))
    (fun period ->
      let root =
        time_root (Crux.Time.interval (Eta.Duration.ms period))
      in
      let bound =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Committed committed) ->
            start committed.post_commit;
            true
        | _ -> false
      in
      let foreign = Eta_test.Test_clock.create () in
      let mismatched =
        Crux.Root.advance root
        |> Eta.Effect.with_clock
             (Eta_test.Test_clock.as_capability foreign)
        |> run_ok
      in
      bound
      &&
      match mismatched with
      | Ok (Crux.Root.Failed { failure; _ }) ->
          failure.Crux.Failure.primary.origin
          = Crux.Failure.Graph_clock
      | _ -> false)

let qcheck_graph_time_shared_sample =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 5) (0 -- 10)) (map (( + ) 5) (0 -- 10))
  in
  (* Generated class: one now node and one after node per iteration, with a
     read-counting clock capability. Observation boundary: exact clock reads
     per advancement and the two node outputs. *)
  QCheck.Test.make ~name:"qcheck_graph_time_shared_sample"
    ~count:50
    (QCheck.make
       ~print:(fun (period, offset) ->
         Printf.sprintf "{period=%d; offset=%d}" period offset)
       sample)
    (fun (period, offset) ->
      let clock = law_clock () in
      let capability, reads = counting_clock clock in
      let under effect = Eta.Effect.with_clock capability effect in
      let description =
        let open Crux.Syntax in
        let+ now = Crux.Time.now ~every:(Eta.Duration.ms period)
        and+ due = Crux.Time.after (Eta.Duration.ms (period + offset)) in
        (Crux.Time.to_ms now, due)
      in
      let root = time_root description in
      let advance () = run_ok (under (Crux.Root.advance root)) in
      let now0 = Eta_test.Test_clock.now_ms clock in
      reads := 0;
      let first_ms, first_due =
        match advance () with
        | Ok (Crux.Root.Committed committed) ->
            start committed.post_commit;
            output_of_commit committed.commit
        | _ -> failwith "initial time commit failed"
      in
      let reads_initial = !reads in
      Eta_test.Test_clock.advance_to clock (now0 + period + offset);
      reads := 0;
      let second_ms, second_due =
        match advance () with
        | Ok (Crux.Root.Committed committed) ->
            start committed.post_commit;
            output_of_commit committed.commit
        | _ -> failwith "due time commit failed"
      in
      let reads_due = !reads in
      reads := 0;
      let idle = advance () in
      let reads_idle = !reads in
      reads_initial = 1
      && reads_due = 1
      && reads_idle <= 1
      && first_ms = now0
      && not first_due
      && second_ms = now0 + period + offset
      && second_due
      && idle = Ok Crux.Root.Idle)

let qcheck_graph_time_structural_ownership =
  (* Generated class: one timer child deactivated before its deadline, plus
     one always-active control timer. Observation boundary: advancement
     results after disposal and clock movement past both deadlines. *)
  QCheck.Test.make ~name:"qcheck_graph_time_structural_ownership"
    ~count:50 (QCheck.map (fun x -> 5 + x) (QCheck.int_range 0 15))
    (fun d ->
      let selector =
        Crux.State_machine.create (Crux.return ())
          ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action:_ ->
            (false, None))
      in
      let description =
        Crux.both selector
          (Crux.bind (Crux.map selector ~f:fst) ~f:(fun active ->
               if active then Crux.Time.after (Eta.Duration.ms d)
               else Crux.return true))
      in
      let root = time_root description in
      let control =
        time_root (Crux.Time.after (Eta.Duration.ms d))
      in
      let (_, endpoint), _ = reset_advance root in
      ignore (reset_advance control);
      send endpoint ();
      let _ = reset_advance root in
      Eta_test.Test_clock.adjust (law_clock ())
        (Eta.Duration.ms (d + 5));
      let disposed_idle =
        run_ok (Crux.Root.advance root) = Ok Crux.Root.Idle
      in
      let control_fired =
        match run_ok (Crux.Root.advance control) with
        | Ok (Crux.Root.Committed committed) ->
            start committed.post_commit;
            output_of_commit committed.commit
        | _ -> false
      in
      disposed_idle && control_fired)

let qcheck_graph_time_deadline_wake =
  (* Generated class: one after timer per leg. Observation boundary: a
     nonblocking poll on an already-due deadline, and a blocked await that
     continues without ingress once the deadline is due. *)
  QCheck.Test.make ~name:"qcheck_graph_time_deadline_wake"
    ~count:40 (QCheck.map (fun x -> 5 + x) (QCheck.int_range 0 15))
    (fun d ->
      let clock = law_clock () in
      let polled_root =
        time_root (Crux.Time.after (Eta.Duration.ms d))
      in
      let polled_driver = identity_driver polled_root in
      let initial_poll = driver_output polled_driver in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let due_poll = driver_output polled_driver in
      let awaited_root =
        time_root (Crux.Time.after (Eta.Duration.ms d))
      in
      let awaited_driver = identity_driver awaited_root in
      let initial_await = driver_output awaited_driver in
      let waiting =
        Eta_test.Async.fork_run (law_switch ())
          (match !shared_runtime with
          | Some runtime -> runtime
          | None -> failwith "law runtime is not installed")
          (Crux.Driver.await awaited_driver)
      in
      wait_for_sleeper clock;
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let event =
        Eta_test.Async.await waiting |> Eta_test.Expect.expect_ok
      in
      let due_await =
        match event with
        | Crux.Driver.Deliver delivery ->
            let output = output_of_delivery delivery in
            ignore
              (run_ok (Crux.Driver.Delivery.delivered delivery));
            output
        | _ -> failwith "await did not deliver the due output"
      in
      (not initial_poll) && due_poll && not initial_await && due_await)

let qcheck_graph_time_await_race =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 20) (0 -- 20)) (-50 -- 50)
  in
  (* Generated class: one machine Action racing one future deadline.
     Observation boundary: the awaited delivery, the canceled sleeper, and
     the recalculated deadline wait. *)
  QCheck.Test.make ~name:"qcheck_graph_time_await_race"
    ~count:40
    (QCheck.make
       ~print:(fun (d, action) ->
         Printf.sprintf "{d=%d; action=%d}" d action)
       sample)
    (fun (d, action) ->
      let clock = law_clock () in
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let root =
        time_root
          (Crux.both machine (Crux.Time.after (Eta.Duration.ms d)))
      in
      let driver = identity_driver root in
      let (_, endpoint), _ = driver_output driver in
      let runtime =
        match !shared_runtime with
        | Some runtime -> runtime
        | None -> failwith "law runtime is not installed"
      in
      let waiting =
        Eta_test.Async.fork_run (law_switch ()) runtime
          (Crux.Driver.await driver)
      in
      wait_for_sleeper clock;
      send endpoint action;
      let event =
        Eta_test.Async.await waiting |> Eta_test.Expect.expect_ok
      in
      let first =
        match event with
        | Crux.Driver.Deliver delivery ->
            let output = output_of_delivery delivery in
            ignore
              (run_ok (Crux.Driver.Delivery.delivered delivery));
            output
        | _ -> failwith "await did not deliver the action output"
      in
      let waiting =
        Eta_test.Async.fork_run (law_switch ()) runtime
          (Crux.Driver.await driver)
      in
      wait_for_sleeper clock;
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let event =
        Eta_test.Async.await waiting |> Eta_test.Expect.expect_ok
      in
      let second =
        match event with
        | Crux.Driver.Deliver delivery ->
            let output = output_of_delivery delivery in
            ignore
              (run_ok (Crux.Driver.Delivery.delivered delivery));
            output
        | _ -> failwith "await did not deliver the due output"
      in
      let (first_model, _), first_due = first in
      let (second_model, _), second_due = second in
      first_model = action
      && not first_due
      && second_model = action
      && second_due)

let qcheck_graph_time_event_priority =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 5) (0 -- 10)) (1 -- 50)
  in
  (* Generated class: one queued Action and one due timer, then stop versus
     due, then crash versus due. Observation boundary: the event kind each
     following driver operation reports. *)
  QCheck.Test.make ~name:"qcheck_graph_time_event_priority"
    ~count:40
    (QCheck.make
       ~print:(fun (d, action) ->
         Printf.sprintf "{d=%d; action=%d}" d action)
       sample)
    (fun (d, action) ->
      let clock = law_clock () in
      let machine apply =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0 ~apply_action:apply
      in
      let due_root apply =
        time_root
          (Crux.both (machine apply)
             (Crux.Time.after (Eta.Duration.ms d)))
      in
      let ingress_root =
        due_root (fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let ingress_driver = identity_driver ingress_root in
      let (_, endpoint), _ = driver_output ingress_driver in
      send endpoint action;
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let due_first = driver_output ingress_driver in
      let action_second = driver_output ingress_driver in
      let stop_root = time_root (Crux.Time.after (Eta.Duration.ms d)) in
      let stop_driver = identity_driver stop_root in
      ignore (driver_output stop_driver);
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      Crux.Driver.request_stop stop_driver;
      let stop_won =
        match run_ok (Crux.Driver.poll stop_driver) with
        | Some (Crux.Driver.Closed _) -> true
        | _ -> false
      in
      let crash_root =
        due_root (fun ~self:_ ~input:() ~model:_ ~action ->
            (action, Some (Eta.Effect.die_message "graph time crash")))
      in
      let crash_driver = identity_driver crash_root in
      let (_, crash_endpoint), _ = driver_output crash_driver in
      send crash_endpoint action;
      ignore (driver_output crash_driver);
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let crash_won =
        match run_ok (Crux.Driver.poll crash_driver) with
        | Some (Crux.Driver.Crash_detected _) -> true
        | _ -> false
      in
      fst (fst due_first) = 0
      && snd due_first
      && fst (fst action_second) = action
      && snd action_second
      && stop_won && crash_won)

let qcheck_graph_time_due_coalescing =
  let sample =
    let open QCheck.Gen in
    triple (map (( + ) 5) (0 -- 5)) (map (( + ) 1) (0 -- 4)) (1 -- 50)
  in
  (* Generated class: two timers due in one sample and one queued Action.
     Observation boundary: one due delivery with both timers, then the
     preserved Action delivery, then idleness. *)
  QCheck.Test.make ~name:"qcheck_graph_time_due_coalescing"
    ~count:40
    (QCheck.make
       ~print:(fun (d, gap, action) ->
         Printf.sprintf "{d=%d; gap=%d; action=%d}" d gap action)
       sample)
    (fun (d, gap, action) ->
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        let open Crux.Syntax in
        let+ timers =
          Crux.both
            (Crux.Time.after (Eta.Duration.ms d))
            (Crux.Time.after (Eta.Duration.ms (d + gap)))
        and+ model = Crux.map machine ~f:fst in
        (timers, model)
      in
      let root = time_root (Crux.both machine description) in
      let driver = identity_driver root in
      let (_, endpoint), _ = driver_output driver in
      send endpoint action;
      Eta_test.Test_clock.adjust (law_clock ())
        (Eta.Duration.ms (d + gap));
      let _, ((first, second), model) = driver_output driver in
      let _, ((_, _), action_model) = driver_output driver in
      let idle = run_ok (Crux.Driver.poll driver) = None in
      first && second && model = 0 && action_model = action && idle)

let qcheck_graph_time_timer_progress =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 5) (0 -- 10)) (map (( + ) 2) (0 -- 4))
  in
  (* Generated class: one one-shot timer and one periodic timer.
     Observation boundary: deliveries before and after each deadline and
     idleness between them. *)
  QCheck.Test.make ~name:"qcheck_graph_time_timer_progress"
    ~count:40
    (QCheck.make
       ~print:(fun (d, p) -> Printf.sprintf "{d=%d; p=%d}" d p)
       sample)
    (fun (d, p) ->
      let clock = law_clock () in
      let one_shot_root =
        time_root (Crux.Time.after (Eta.Duration.ms d))
      in
      let one_shot = identity_driver one_shot_root in
      let initial_shot = driver_output one_shot in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let fired = driver_output one_shot in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms d);
      let retired = run_ok (Crux.Driver.poll one_shot) = None in
      let periodic_root =
        time_root (Crux.Time.interval (Eta.Duration.ms p))
      in
      let periodic = identity_driver periodic_root in
      let tick0 = driver_output periodic in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms p);
      let tick1 = driver_output periodic in
      let quiet = run_ok (Crux.Driver.poll periodic) = None in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms p);
      let tick2 = driver_output periodic in
      (not initial_shot) && fired && retired
      && tick0 = 0 && tick1 = 1 && quiet && tick2 = 2)

let qcheck_graph_time_now_cadence =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 5) (0 -- 7)) (1 -- 50)
  in
  (* Generated class: one Action inside the first cadence interval.
     Observation boundary: the shared sample at each committed advancement
     and the activation-aligned due schedule, which the Action does not
     shift. *)
  QCheck.Test.make ~name:"qcheck_graph_time_now_cadence"
    ~count:40
    (QCheck.make
       ~print:(fun (p, action) ->
         Printf.sprintf "{p=%d; action=%d}" p action)
       sample)
    (fun (p, action) ->
      let clock = law_clock () in
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        let open Crux.Syntax in
        let+ now = Crux.Time.now ~every:(Eta.Duration.ms p)
        and+ model = Crux.map machine ~f:fst in
        (Crux.Time.to_ms now, model)
      in
      let root = time_root (Crux.both machine description) in
      let driver = identity_driver root in
      let t0 = Eta_test.Test_clock.now_ms clock in
      let (_, endpoint), (emitted0, _) = driver_output driver in
      Eta_test.Test_clock.adjust clock Eta.Duration.(ms 1);
      send endpoint action;
      let _, (action_sample, action_model) = driver_output driver in
      Eta_test.Test_clock.advance_to clock (t0 + p);
      let _, (aligned, _) = driver_output driver in
      Eta_test.Test_clock.advance_to clock (t0 + (2 * p));
      let _, (next, _) = driver_output driver in
      emitted0 = t0
      && action_sample = t0 + 1
      && action_model = action
      && aligned = t0 + p
      && next = t0 + (2 * p))

let qcheck_graph_time_deadline =
  (* Generated class: one dynamic deadline with a generated future offset.
     Observation boundary: outputs before, at, and after the deadline. *)
  QCheck.Test.make ~name:"qcheck_graph_time_deadline" ~count:40
    (QCheck.map (fun x -> 5 + x) (QCheck.int_range 0 25))
    (fun offset ->
      let clock = law_clock () in
      let source = time_root (Crux.Time.now ~every:(Eta.Duration.ms 1)) in
      let source_driver = identity_driver source in
      let token = driver_output source_driver in
      let target =
        match Crux.Time.add token (Eta.Duration.ms offset) with
        | Ok target -> target
        | Error _ -> failwith "valid time addition failed"
      in
      let root = time_root (Crux.Time.deadline target) in
      let driver = identity_driver root in
      let before = driver_output driver in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms offset);
      let at = driver_output driver in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms offset);
      let after = run_ok (Crux.Driver.poll driver) = None in
      (not before) && at && after)

let qcheck_graph_time_after_activation =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 8) (0 -- 7)) (map (( + ) 3) (0 -- 3))
  in
  (* Generated class: one timer child disposed and re-entered before its
     original deadline. Observation boundary: advancement results at the
     original and the re-activation deadlines. *)
  QCheck.Test.make ~name:"qcheck_graph_time_after_activation"
    ~count:40
    (QCheck.make
       ~print:(fun (d, r) -> Printf.sprintf "{d=%d; r=%d}" d r)
       sample)
    (fun (d, r) ->
      let clock = law_clock () in
      let selector =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.both selector
          (Crux.bind (Crux.map selector ~f:fst) ~f:(fun stage ->
               if stage = 1 then Crux.Time.after (Eta.Duration.ms d)
               else Crux.return true))
      in
      let root = time_root description in
      let (_, endpoint), _ = reset_advance root in
      let t0 = Eta_test.Test_clock.now_ms clock in
      send endpoint 1;
      let _ = reset_advance root in
      Eta_test.Test_clock.advance_to clock (t0 + r);
      send endpoint 2;
      let _ = reset_advance root in
      send endpoint 1;
      let _ = reset_advance root in
      Eta_test.Test_clock.advance_to clock (t0 + d);
      let original_deadline_idle =
        run_ok (Crux.Root.advance root) = Ok Crux.Root.Idle
      in
      Eta_test.Test_clock.advance_to clock (t0 + r + d);
      let reactivation_fired =
        match run_ok (Crux.Root.advance root) with
        | Ok (Crux.Root.Committed committed) ->
            start committed.post_commit;
            snd (output_of_commit committed.commit)
        | _ -> false
      in
      original_deadline_idle && reactivation_fired)

let qcheck_graph_time_interval_catch_up =
  let sample =
    let open QCheck.Gen in
    pair (map (( + ) 2) (0 -- 8)) (map (( + ) 2) (0 -- 3))
  in
  (* Generated class: missed tick counts, then a saturation leg on an
     isolated clock. Observation boundary: one catch-up delivery, idleness
     after it, the saturated delivery, and idleness after saturation. *)
  QCheck.Test.make ~name:"qcheck_graph_time_interval_catch_up"
    ~count:40
    (QCheck.make
       ~print:(fun (p, missed) ->
         Printf.sprintf "{p=%d; missed=%d}" p missed)
       sample)
    (fun (p, missed) ->
      let clock = law_clock () in
      let root = time_root (Crux.Time.interval (Eta.Duration.ms p)) in
      let driver = identity_driver root in
      let tick0 = driver_output driver in
      Eta_test.Test_clock.adjust clock
        (Eta.Duration.ms ((missed * p) + (p - 1)));
      let caught_up = driver_output driver in
      let no_replay = run_ok (Crux.Driver.poll driver) = None in
      let isolated = Eta_test.Test_clock.create () in
      let isolated_capability =
        Eta_test.Test_clock.as_capability isolated
      in
      let under effect =
        Eta.Effect.with_clock isolated_capability effect
      in
      let saturated_root =
        time_root (Crux.Time.interval (Eta.Duration.ms 1))
      in
      let saturated_driver = identity_driver saturated_root in
      let initial =
        match run_ok (under (Crux.Driver.poll saturated_driver)) with
        | Some (Crux.Driver.Deliver delivery) ->
            let output = output_of_delivery delivery in
            ignore
              (run_ok
                 (under (Crux.Driver.Delivery.delivered delivery)));
            output
        | _ -> failwith "isolated initial delivery failed"
      in
      Eta_test.Test_clock.advance_to isolated max_int;
      let saturated =
        match run_ok (under (Crux.Driver.poll saturated_driver)) with
        | Some (Crux.Driver.Deliver delivery) ->
            let output = output_of_delivery delivery in
            ignore
              (run_ok
                 (under (Crux.Driver.Delivery.delivered delivery)));
            output
        | _ -> failwith "isolated saturation delivery failed"
      in
      let quiet =
        run_ok (under (Crux.Driver.poll saturated_driver)) = None
      in
      tick0 = 0
      && caught_up = missed
      && no_replay
      && initial = 0
      && saturated = max_int
      && quiet)

let qcheck_graph_time_commit_fence =
  (* Generated class: one due timer per iteration. Observation boundary:
     the due commit's output, the advancement fence before the token
     starts, and idleness after it. *)
  QCheck.Test.make ~name:"qcheck_graph_time_commit_fence"
    ~count:40 (QCheck.map (fun x -> 5 + x) (QCheck.int_range 0 10))
    (fun d ->
      let root = time_root (Crux.Time.after (Eta.Duration.ms d)) in
      ignore (reset_advance root);
      Eta_test.Test_clock.adjust (law_clock ()) (Eta.Duration.ms d);
      let output, post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let fenced =
        run_ok (Crux.Root.advance root)
        = Error Crux.Root.Awaiting_post_commit
      in
      start post_commit;
      let idle = run_ok (Crux.Root.advance root) = Ok Crux.Root.Idle in
      output && fenced && idle)

let qcheck_graph_time_driver_bound =
  let sample =
    let open QCheck.Gen in
    triple (map (( + ) 5) (0 -- 5)) (map (( + ) 1) (0 -- 4)) (1 -- 50)
  in
  (* Generated class: two due timers and one queued Action. Observation
     boundary: the exact delivery sequence of consecutive polls. *)
  QCheck.Test.make ~name:"qcheck_graph_time_driver_bound"
    ~count:40
    (QCheck.make
       ~print:(fun (d, gap, action) ->
         Printf.sprintf "{d=%d; gap=%d; action=%d}" d gap action)
       sample)
    (fun (d, gap, action) ->
      let machine =
        Crux.State_machine.create (Crux.return ())
          ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        let open Crux.Syntax in
        let+ timers =
          Crux.both
            (Crux.Time.after (Eta.Duration.ms d))
            (Crux.Time.after (Eta.Duration.ms (d + gap)))
        and+ model = Crux.map machine ~f:fst in
        (timers, model)
      in
      let root = time_root (Crux.both machine description) in
      let driver = identity_driver root in
      let (_, endpoint), _ = driver_output driver in
      send endpoint action;
      Eta_test.Test_clock.adjust (law_clock ())
        (Eta.Duration.ms (d + gap));
      let first = driver_output driver in
      let second = driver_output driver in
      let quiet = run_ok (Crux.Driver.poll driver) = None in
      snd first = ((true, true), 0)
      && snd second = ((true, true), action)
      && quiet)

let qcheck_graph_time_transport_equivalence =
  (* Generated class: one interval timer observed through both binding
     kinds. Observation boundary: the delivered tick sequences. *)
  QCheck.Test.make ~name:"qcheck_graph_time_transport_equivalence"
    ~count:20 (QCheck.map (fun x -> 5 + x) (QCheck.int_range 0 10))
    (fun p ->
      let clock = law_clock () in
      let projection =
        Typed_projection.create ~name:"graph-time-equivalence"
          ~codec:int_codec ~value_equal:Int.equal
          ~cutoff:Crux.Cutoff.never
      in
      let identity_root =
        time_root (Crux.Time.interval (Eta.Duration.ms p))
      in
      let identity = identity_driver identity_root in
      let candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:1024
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let serialized_root =
        Typed_projection.root projection ~projection_capacity:1
          ~ingress_capacity:4 ~request_capacity:1
          (Crux.Time.interval (Eta.Duration.ms p))
      in
      let serialized = Crux.Driver.create binding serialized_root in
      let ack_sequence = ref 0l in
      let serialized_output () =
        let rec drain attempts =
          match
            run_ok (Crux.Serialized_session.poll_outgoing peer)
          with
          | Some bytes -> Eta_crux_json.Format.decode bytes
          | None ->
              if attempts = 0 then
                failwith "serialized binding emitted no frame"
              else (
                if run_ok (Crux.Driver.poll serialized) <> None then
                  failwith
                    "serialized delivery is not transport-owned";
                drain (attempts - 1))
        in
        let frame = drain 8 in
        let sequence, output =
          match frame with
          | Ok (Crux.Wire.Frame.Projection_deliver { seq; content; _ }) -> (
              let output = projection_content_value content in
              seq,
              match Crux.Codec.decode int_codec output with
              | Ok value -> value
              | Error _ -> failwith "serialized tick did not decode")
          | _ -> failwith "serialized binding emitted the wrong frame"
        in
        let response =
          Crux.Wire.Frame.Projection_result
            {
              seq = !ack_sequence;
              reply_to = sequence;
              result = `Accepted;
            }
          |> Eta_crux_json.Format.encode
        in
        ack_sequence := Int32.add !ack_sequence 1l;
        (match
           run_ok (Crux.Serialized_session.receive peer response)
         with
        | Ok () -> ()
        | Error _ -> failwith "serialized acknowledgment rejected");
        output
      in
      let identity_tick0 = driver_output identity in
      let serialized_tick0 = serialized_output () in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms p);
      let identity_tick1 = driver_output identity in
      let serialized_tick1 = serialized_output () in
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms p);
      let identity_tick2 = driver_output identity in
      let serialized_tick2 = serialized_output () in
      [ identity_tick0; identity_tick1; identity_tick2 ]
      = [ serialized_tick0; serialized_tick1; serialized_tick2 ]
      && identity_tick2 = 2)

let qcheck_poll_transport_equivalence =
  (* Generated class: one manual Poll result observed through both binding
     kinds. Observation boundary: the delivered output sequences and the
     refresh admissions. *)
  QCheck.Test.make ~name:"qcheck_poll_transport_equivalence"
    ~count:10 (QCheck.int_range 1 100)
    (fun value ->
      let description () =
        let result, refresh =
          Crux.Poll.manual_refresh
            ~starting:Crux.Poll.Starting.empty
            ~effect:(Crux.return (Eta.Effect.pure value)) ()
        in
        Crux.both
          (Crux.map result ~f:(function
            | Some result -> result
            | None -> -1))
          refresh
      in
      let identity_root = time_root (description ()) in
      let identity = identity_driver identity_root in
      let pair_codec =
        Crux.Codec.make
          ~encode:(fun (result, _) ->
            Crux.Codec.encode int_codec result)
          ~decode:(fun _ ->
            Error
              {
                Crux.Codec.message =
                  "poll transport codec is encode-only";
              })
      in
      let projection =
        Typed_projection.create ~name:"poll-equivalence"
          ~codec:pair_codec ~value_equal:(fun (left, _) (right, _) ->
            Int.equal left right)
          ~cutoff:Crux.Cutoff.never
      in
      let candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:1024
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized
          ~operations:[] ~session:candidate
      in
      let serialized_root =
        Typed_projection.root projection ~projection_capacity:1
          ~ingress_capacity:4 ~request_capacity:1 (description ())
      in
      let serialized = Crux.Driver.create binding serialized_root in
      let ack_sequence = ref 0l in
      let serialized_output () =
        let rec drain attempts =
          match
            run_ok (Crux.Serialized_session.poll_outgoing peer)
          with
          | Some bytes -> Eta_crux_json.Format.decode bytes
          | None ->
              if attempts = 0 then
                failwith "serialized binding emitted no frame"
              else (
                if run_ok (Crux.Driver.poll serialized) <> None then
                  failwith
                    "serialized delivery is not transport-owned";
                drain (attempts - 1))
        in
        let frame = drain 8 in
        let sequence, output =
          match frame with
          | Ok (Crux.Wire.Frame.Projection_deliver { seq; content; _ }) -> (
              let output = projection_content_value content in
              seq,
              match Crux.Codec.decode int_codec output with
              | Ok decoded -> decoded
              | Error _ -> failwith "serialized poll did not decode")
          | _ -> failwith "serialized binding emitted the wrong frame"
        in
        let response =
          Crux.Wire.Frame.Projection_result
            {
              seq = !ack_sequence;
              reply_to = sequence;
              result = `Accepted;
            }
          |> Eta_crux_json.Format.encode
        in
        ack_sequence := Int32.add !ack_sequence 1l;
        (match
           run_ok (Crux.Serialized_session.receive peer response)
         with
        | Ok () -> ()
        | Error _ -> failwith "serialized acknowledgment rejected");
        output
      in
      let committed_int driver =
        match latest_committed_snapshot driver with
        | Some (result, _) -> result
        | None -> failwith "poll commit was not retained"
      in
      let refresh_of driver =
        match latest_committed_snapshot driver with
        | Some (_, refresh) -> refresh
        | None -> failwith "poll refresh was not retained"
      in
      let serialized_latest () =
        Option.bind
          (Crux.Driver.latest_committed_snapshot serialized)
          (Typed_projection.snapshot_value projection)
      in
      let initial_identity, _ = driver_output identity in
      let initial_serialized = serialized_output () in
      invoke_poll_refresh (refresh_of identity);
      invoke_poll_refresh
        (match serialized_latest () with
        | Some (_, refresh) -> refresh
        | None -> failwith "serialized poll refresh was not retained");
      let refresh_identity, _ = driver_output identity in
      let refresh_serialized = serialized_output () in
      for _ = 1 to 3 do
        Eio.Fiber.yield ()
      done;
      let completion_identity, _ = driver_output identity in
      let completion_serialized = serialized_output () in
      initial_identity = -1
      && initial_serialized = -1
      && refresh_identity = -1
      && refresh_serialized = -1
      && completion_identity = value
      && completion_serialized = value
      && committed_int identity = value
      &&
      (match serialized_latest () with
      | Some (result, _) -> result = value
      | None -> false))

let () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  shared_runtime := Some runtime;
  shared_clock := Some clock;
  shared_switch := Some switch;
  let seed = Random.State.make [| 0xE7A; 0xC2_0C |] in
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed
      [
        qcheck_description_identity;
        qcheck_cutoff_boundary;
        qcheck_assoc_key_order;
        qcheck_assoc_continuous_presence;
        qcheck_assoc_data_update;
        qcheck_assoc_remove_reenter;
        qcheck_source_spec_identity;
        qcheck_source_latest_mapper;
        qcheck_source_terminal_outcome;
        qcheck_transition_snapshot;
        qcheck_one_event_advancement;
        qcheck_projection_image_per_commit;
        qcheck_lifecycle_once_per_interval;
        qcheck_ingress_fifo_admission;
        qcheck_capacity_bounds;
        qcheck_endpoint_contramap;
        qcheck_bind_child_identity;
        qcheck_active_disposed_states;
        qcheck_committed_dependencies_only;
        qcheck_post_commit_fence;
        qcheck_assoc_rollback;
        qcheck_assoc_lifecycle_order;
        qcheck_cause_classification;
        qcheck_export_generation;
        qcheck_export_rebinding;
        qcheck_request_first_resolution;
        qcheck_request_capacity;
        qcheck_driver_one_advancement;
        qcheck_delivery_token;
        qcheck_request_closure_reasons;
        qcheck_wire_sequence;
        qcheck_exact_envelope_grammars;
        qcheck_wire_reply_correlation;
        qcheck_malformed_frame_isolation;
        qcheck_wire_closed_outcomes;
        qcheck_wire_bounds;
        qcheck_wire_redaction;
        qcheck_bounded_drain;
        qcheck_controlled_dependencies;
        qcheck_latest_committed_snapshot;
        qcheck_post_commit_effect_observer_inventory;
        qcheck_post_commit_effect_observer_lifecycle;
        qcheck_post_commit_effect_observer_order;
        qcheck_post_commit_effect_observer_fifo;
        qcheck_post_commit_effect_observer_transparency;
        qcheck_reset_default_custom;
        qcheck_reset_snapshot_atomicity;
        qcheck_reset_ingress_order;
        qcheck_reset_scope_boundary;
        qcheck_reset_dynamic_children;
        qcheck_reset_effect_lifecycle;
        qcheck_reset_authority_incarnation;
        qcheck_poll_committed_run_order;
        qcheck_poll_manual_refresh_admission;
        qcheck_poll_input_cutoff;
        qcheck_poll_starting_incarnation;
        qcheck_poll_run_order_overflow;
        qcheck_poll_provider_sampling;
        qcheck_poll_activation_and_coalescing;
        qcheck_poll_result_cutoff_order_fence;
        qcheck_poll_failure_attribution;
        qcheck_poll_clock_priority;
        qcheck_poll_completion_fifo;
        qcheck_poll_run_order;
        qcheck_post_commit_effect_observer_poll_lifecycle;
        qcheck_graph_time_initial_binding;
        qcheck_graph_time_shared_sample;
        qcheck_graph_time_structural_ownership;
        qcheck_graph_time_deadline_wake;
        qcheck_graph_time_await_race;
        qcheck_graph_time_event_priority;
        qcheck_graph_time_due_coalescing;
        qcheck_graph_time_timer_progress;
        qcheck_graph_time_now_cadence;
        qcheck_graph_time_deadline;
        qcheck_graph_time_after_activation;
        qcheck_graph_time_interval_catch_up;
        qcheck_graph_time_commit_fence;
        qcheck_graph_time_driver_bound;
        qcheck_graph_time_transport_equivalence;
        qcheck_poll_transport_equivalence;
      ]
  in
  if code <> 0 then exit code
