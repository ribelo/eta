module Crux = Eta_crux
module Int_map = Map.Make (Int)

let shared_runtime : Crux.never Eta.Runtime.t option ref = ref None

let run_ok eff =
  match !shared_runtime with
  | None -> failwith "law runtime is not installed"
  | Some runtime ->
      Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let committed = function
  | Ok (Crux.Root.Committed { output; post_commit }) ->
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
      projection count and each delivered parity.
    - [qcheck_assoc_key_order] generates bounded key-value bindings. It observes
      the complete ordered child map.
    - [qcheck_assoc_continuous_presence] generates one retained key and action.
      It observes the retained endpoint and model.
    - [qcheck_assoc_data_update] generates old data, new data, and one action.
      It observes the retained model and current data.
    - [qcheck_assoc_remove_reenter] generates one key and action. It observes the
      stale old endpoint and the fresh child state.
    - [qcheck_source_spec_identity] generates spec and mapper changes. It
      observes producer incarnations and committed mapped output.
    - [qcheck_source_latest_mapper] generates mapper replacements. It observes
      the mapper used for the next source item.
    - [qcheck_source_terminal_outcome] generates completion or failure. It
      observes one terminal action, one producer, and final idleness.
    - [qcheck_transition_snapshot] generates bounded transition values. It
      observes apply arguments, output, and post-commit effect eligibility.
    - [qcheck_one_event_advancement] generates nonempty action lists and stop
      priority. It observes each prefix or zero transition calls.
    - [qcheck_complete_output_per_commit] generates action lists with an equal
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
            (model + action, Eta.Effect.unit))
      in
      let root =
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1
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
      let projections = ref 0 in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, Eta.Effect.unit))
      in
      let parity =
        Crux.map machine ~f:fst
        |> Crux.cutoff ~equal:(fun left right -> left mod 2 = right mod 2)
        |> Crux.map ~f:(fun value ->
               incr projections;
               value mod 2)
      in
      let root =
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1
          (Crux.both machine parity)
      in
      let initial_output, initial_post_commit =
        committed (run_ok (Crux.Root.advance root))
      in
      let (initial_model, endpoint), _ = initial_output in
      start initial_post_commit;
      let _, changes =
        List.fold_left
          (fun (model, changes) action ->
            send endpoint action;
            let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
            start post_commit;
            let (new_model, _), observed_parity = output in
            if observed_parity <> new_model mod 2 then
              failwith "cutoff changed the delivered value";
            (new_model, changes + Bool.to_int (model mod 2 <> new_model mod 2)))
          (initial_model, 0) actions
      in
      !projections = changes + 1)

let assoc_description initial =
  let parent =
    Crux.State_machine.create (Crux.return ()) ~default_model:initial
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, Eta.Effect.unit))
  in
  let children =
    let module Assoc = Crux.Assoc (Int_map) in
    Assoc.assoc (Crux.map parent ~f:fst)
      ~data_equal:Int.equal
      ~f:(fun ~key:_ ~data ->
        let machine =
          Crux.State_machine.create data ~default_model:0
            ~apply_action:(fun ~self:_ ~input:_ ~model ~action ->
              (model + action, Eta.Effect.unit))
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
          (fun map (key, value) -> Int_map.add key value map)
          Int_map.empty bindings
      in
      let root =
        Crux.Root.create ~ingress_capacity:8 ~request_capacity:1
          (assoc_description input)
      in
      let ((_parent, children), post_commit) =
        committed (run_ok (Crux.Root.advance root))
      in
      start post_commit;
      List.map (fun (key, (data, _, _)) -> (key, data))
        (Int_map.bindings children)
      = Int_map.bindings input)

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
        Crux.Root.create ~ingress_capacity:8 ~request_capacity:1
          (assoc_description initial)
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, retained_endpoint = Int_map.find key children in
      send parent_endpoint (Int_map.add (key + 1) 17 initial);
      let _, update_post = committed (run_ok (Crux.Root.advance root)) in
      start update_post;
      send retained_endpoint delta;
      let ((_, children), child_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start child_post;
      let _, model, _ = Int_map.find key children in
      model = delta)

let qcheck_assoc_data_update =
  QCheck.Test.make ~name:"qcheck_assoc_data_update" ~count:200 assoc_sample
    (fun (key, first, second, delta) ->
      let root =
        Crux.Root.create ~ingress_capacity:8 ~request_capacity:1
          (assoc_description (Int_map.singleton key first))
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, child_endpoint = Int_map.find key children in
      send child_endpoint delta;
      let _, child_post = committed (run_ok (Crux.Root.advance root)) in
      start child_post;
      send parent_endpoint (Int_map.singleton key second);
      let ((_, children), update_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start update_post;
      let data, model, _ = Int_map.find key children in
      data = second && model = delta)

let qcheck_assoc_remove_reenter =
  QCheck.Test.make ~name:"qcheck_assoc_remove_reenter" ~count:200 assoc_sample
    (fun (key, data, _, delta) ->
      let root =
        Crux.Root.create ~ingress_capacity:8 ~request_capacity:1
          (assoc_description (Int_map.singleton key data))
      in
      let (((_, parent_endpoint), children), first_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start first_post;
      let _, _, old_endpoint = Int_map.find key children in
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
      let _, _, new_endpoint = Int_map.find key children in
      send new_endpoint delta;
      let ((_, children), child_post) =
        committed (run_ok (Crux.Root.advance root))
      in
      start child_post;
      let _, model, _ = Int_map.find key children in
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
  root : source_output Crux.Root.t;
  commands : (source_command, Crux.never) Eta.Queue.t;
  openings : int ref;
  config_endpoint : (int * int) Crux.Endpoint.t;
}

let make_source_harness ~spec ~mapper =
  let commands = Eta.Queue.unbounded () in
  let openings = ref 0 in
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
  let producer _spec ~emit =
    let open Eta.Syntax in
    let* () = Eta.Effect.sync (fun () -> incr openings) in
    Eta.Effect.pure (running ~emit)
  in
  let config =
    Crux.State_machine.create (Crux.return ())
      ~default_model:(spec, mapper)
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, Eta.Effect.unit))
  in
  let sink =
    Crux.State_machine.create (Crux.return ()) ~default_model:[]
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model @ [ action ], Eta.Effect.unit))
  in
  let source =
    Crux.Source.create ~spec_equal:Int.equal
      ~spec:(Crux.map config ~f:(fun ((spec, _), _) -> spec))
      ~producer:(Crux.return producer)
      ~target:(Crux.map sink ~f:snd)
      ~on_item:
        (Crux.map config ~f:(fun ((_, mapper), _) item ->
             Item (item * mapper)))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> Completed
          | Crux.Source.Failed message -> Failed message))
  in
  let root =
    Crux.Root.create ~ingress_capacity:16 ~request_capacity:1
      (Crux.both config (Crux.both sink source))
  in
  let output, post_commit = committed (run_ok (Crux.Root.advance root)) in
  start post_commit;
  let ((_, config_endpoint), _) = output in
  { root; commands; openings; config_endpoint }

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
    | Ok (Crux.Root.Committed { output; post_commit }) ->
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
      let harness = make_source_harness ~spec:0 ~mapper:1 in
      let _, expected =
        List.fold_left
          (fun (previous, expected) spec ->
            ignore (source_update_config harness (spec, 1));
            (spec, expected + Bool.to_int (spec <> previous)))
          (0, 1) specs
      in
      let observed = !(harness.openings) in
      stop_source_harness harness;
      observed = expected)

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
      let harness = make_source_harness ~spec:0 ~mapper:1 in
      ignore (source_update_config harness (0, mapper));
      source_send_command harness (Emit item);
      let _, ((observations, _), _) = await_source_commit harness 100 in
      let openings = !(harness.openings) in
      stop_source_harness harness;
      observations = [ Item (item * mapper) ] && openings = 1)

let qcheck_source_terminal_outcome =
  QCheck.Test.make ~name:"qcheck_source_terminal_outcome" ~count:100
    QCheck.(pair bool string_small)
    (fun (complete, message) ->
      let harness = make_source_harness ~spec:0 ~mapper:1 in
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
            (action, Eta.Effect.unit))
      in
      let machine =
        Crux.State_machine.create (Crux.map input ~f:fst)
          ~default_model:initial_model
          ~apply_action:(fun ~self:_ ~input ~model ~action ->
            calls := (input, model, action) :: !calls;
            ( model + (input * action),
              Eta.Effect.sync (fun () -> effect_started := true) ))
      in
      let root =
        Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
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
            ((model * 31) + action, Eta.Effect.unit))
      in
      let root =
        Crux.Root.create ~ingress_capacity:12 ~request_capacity:1 machine
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

let qcheck_complete_output_per_commit =
  (* Generated class: nonempty bounded action lists forced to contain an
     equal-model action. Observation boundary: exact committed-output
     cardinality and value sequence, including the unchanged first output. *)
  let sample =
    let open QCheck.Gen in
    map (fun rest -> 0 :: rest) (list_size (0 -- 11) (-2 -- 2))
  in
  QCheck.Test.make ~name:"qcheck_complete_output_per_commit" ~count:100
    (QCheck.make ~print:QCheck.Print.(list int) sample)
    (fun actions ->
      let calls = ref 0 in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            incr calls;
            (model + action, Eta.Effect.unit))
      in
      let root =
        Crux.Root.create ~ingress_capacity:12 ~request_capacity:1 machine
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
            (action, Eta.Effect.unit))
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
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1
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
    ~encode:(fun value -> Bytes.of_string (string_of_int value))
    ~decode:(fun bytes ->
      match int_of_string_opt (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "expected an integer" })

let exported_counter ~capacity =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let export =
    Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
      ~codec:int_codec
  in
  let root =
    Crux.Root.create ~ingress_capacity:capacity ~request_capacity:1
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
              | Ok
                  (Crux.Root.Committed
                    { output = ((model, _), _); post_commit }) ->
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
            (model + action, Eta.Effect.unit))
      in
      let root =
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1 machine
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
        (action, Eta.Effect.unit))
  in
  let child default_model =
    Crux.State_machine.create (Crux.return ()) ~default_model
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
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
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1
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
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1
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
              (action, Eta.Effect.unit))
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
          Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
          Crux.Driver.Delivery.output initial_delivery
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
                Crux.Driver.Delivery.output delivery
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
            (model + action, Eta.Effect.unit))
      in
      let root =
        Crux.Root.create ~ingress_capacity:32 ~request_capacity:1 machine
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
            (action, Eta.Effect.unit))
      in
      let module Assoc = Crux.Assoc (Int_map) in
      let children =
        Assoc.assoc (Crux.map parent ~f:fst)
          ~f:(fun ~key ~data:_ ->
            let child =
              Crux.State_machine.create (Crux.return ()) ~default_model:0
                ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
                  (model + action, Eta.Effect.unit))
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
        Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
          (Crux.both parent children)
      in
      let initial, initial_post = committed (run_ok (Crux.Root.advance root)) in
      start initial_post;
      let ((_, parent_endpoint), initial_children) = initial in
      let retained = Int_map.find retained_key initial_children in
      send parent_endpoint
        (Int_map.add failing_key (data + 1)
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
             (fun map (key, data) -> Int_map.add key data map)
             Int_map.empty
      in
      let initial_map = map_from 0 removed_count in
      let replacement_map = map_from 100 added_count in
      let parent =
        Crux.State_machine.create (Crux.return ())
          ~default_model:initial_map
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, Eta.Effect.unit))
      in
      let module Assoc = Crux.Assoc (Int_map) in
      let children =
        Assoc.assoc (Crux.map parent ~f:fst)
          ~f:(fun ~key:_ ~data:_ ->
            let child =
              Crux.State_machine.create (Crux.return ()) ~default_model:0
                ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
                  (model + action, Eta.Effect.unit))
            in
            Crux.Exported_endpoint.create (Crux.map child ~f:snd)
              ~codec:int_codec)
      in
      let root =
        Crux.Root.create ~ingress_capacity:added_count ~request_capacity:1
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
        Int_map.bindings old_children
        |> List.for_all (fun (_, export) ->
               Crux.Exported_endpoint.try_invoke export 1
               = Error Crux.Exported_endpoint.Revoked)
      in
      let additions_active =
        Int_map.bindings new_children
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
        Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
            (action, Eta.Effect.unit))
      in
      let child =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, Eta.Effect.unit))
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
        Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
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
        | Ok
            (Crux.Root.Committed
              {
                output = (_, Some (model, _));
                post_commit;
              }) ->
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
            Bytes.of_string (string_of_int value))
          ~decode:(fun bytes ->
            incr codec_calls;
            match int_of_string_opt (Bytes.to_string bytes) with
            | Some value -> Ok value
            | None -> Error { Crux.Codec.message = "invalid integer" })
      in
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:true
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, Eta.Effect.unit))
      in
      let counter () =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, Eta.Effect.unit))
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
        Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
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
    Crux.Root.create ~ingress_capacity:8 ~request_capacity
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
            (action, Eta.Effect.unit))
      in
      let child =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
            (model + action, Eta.Effect.unit))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
            if enabled then Crux.map child ~f:Option.some
            else Crux.return None)
      in
      let root =
        Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
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
        Crux.Driver.Delivery.output initial_delivery
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
        Crux.Driver.Delivery.output structural_delivery
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
        Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
        fst (Crux.Driver.Delivery.output delivery) = expected
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
            (action, Eta.Effect.unit))
      in
      let selected =
        Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
            if enabled then
              Crux.lifecycle (Crux.return request_program)
              |> Crux.map ~f:Option.some
            else Crux.return None)
      in
      let root =
        Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
          (Crux.both selector selected)
      in
      let driver = Crux.Driver.create binding root in
      let initial =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) -> delivery
        | _ -> failwith "closure-reason driver did not start"
      in
      let ((_, selector_endpoint), _) =
        Crux.Driver.Delivery.output initial
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
      Crux.Wire.Frame.Output_deliver
        { seq; reason = `Advancement; output = bytes }
  | 1 ->
      Output_result { seq; reply_to = 0l; result = `Accepted }
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
        Crux.Driver.Binding.serialized ~output:int_codec
          ~operations:[] ~session:candidate
      in
      let root =
        Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ -> Int32.minus_one
      in
      let response =
        match case with
        | Exact_reply ->
            Crux.Wire.Frame.Output_result
              {
                seq = 0l;
                reply_to = command_sequence;
                result = `Accepted;
              }
        | Unknown_reply ->
            Crux.Wire.Frame.Output_result
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
        Crux.Driver.Binding.serialized ~output:int_codec
          ~operations:[] ~session:candidate
      in
      let root =
        Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
            Crux.Wire.Frame.Output_result
              {
                seq = 1l;
                reply_to = 0l;
                result = `Accepted;
              }
            |> Eta_crux_json.Format.encode
        | Unknown_result_reply ->
            Crux.Wire.Frame.Output_result
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
        = Error Crux.Root.Awaiting_post_commit
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
        Crux.Driver.Binding.serialized ~output:int_codec
          ~operations:[] ~session:candidate
      in
      let root =
        Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
            | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
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
        Crux.Wire.Frame.Output_result
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
          let bytes_codec =
            Crux.Codec.make ~encode:Fun.id
              ~decode:(fun bytes -> Ok bytes)
          in
          let binding, _admin =
            Crux.Driver.Binding.serialized ~output:bytes_codec
              ~operations:[] ~session:candidate
          in
          let root =
            Crux.Root.create ~ingress_capacity:1
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
            (action, Eta.Effect.unit))
      in
      let payload_codec =
        Crux.Codec.make ~encode:Bytes.of_string
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
            Bytes.concat (Bytes.of_string "\000")
              [ Bytes.of_string model; handle ])
          ~decode:(fun _ ->
            Error
              {
                Crux.Codec.message =
                  "redaction test output is encode-only";
              })
      in
      let candidate, peer =
        Crux.Serialized_session.candidate
          ~max_frame_bytes:2048
          ~format:(module Eta_crux_json.Format)
      in
      let binding, _admin =
        Crux.Driver.Binding.serialized ~output:output_codec
          ~operations:[] ~session:candidate
      in
      let root =
        Crux.Root.create ~ingress_capacity:1
          ~request_capacity:1 description
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
                (Crux.Wire.Frame.Output_deliver
                  { seq; output; _ }) ->
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
        Crux.Wire.Frame.Output_result
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
              Crux.Endpoint.send self action
              |> Eta.Effect.ignore_errors ))
      in
      let seed =
        Crux.lifecycle
          (Crux.map machine ~f:(fun (_, endpoint) ->
               Crux.Endpoint.send endpoint 1
               |> Eta.Effect.ignore_errors))
      in
      let root =
        Crux.Root.create ~ingress_capacity:4
          ~request_capacity:1
          (Crux.map (Crux.both machine seed) ~f:fst)
      in
      let handle =
        Eta_crux_test.Handle.create
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
            (model @ [ item ], Eta.Effect.unit)
        | Controlled_terminal -> (model, Eta.Effect.unit))
  in
  let source =
    Crux.Source.create ~spec_equal:(fun () () -> true)
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
  Crux.Root.create ~ingress_capacity:16 ~request_capacity:1
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
    | Ok (Crux.Root.Committed { output; post_commit }) ->
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

let () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  shared_runtime := Some runtime;
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
        qcheck_complete_output_per_commit;
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
      ]
  in
  if code <> 0 then exit code
