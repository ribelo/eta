module Crux = Eta_crux
module Projection = Eta_crux_test.Projection_harness.Opaque

let output_of_delivery witness delivery =
  Eta_crux_test.Projection_harness.Opaque.delivery_value
    witness
    (Crux.Driver.Delivery.projection delivery)
  |> Option.get

let output_of_commit witness commit =
  Eta_crux_test.Projection_harness.Opaque.commit_value witness commit
  |> Option.get

let latest_committed_snapshot witness driver =
  Option.bind (Crux.Driver.latest_committed_snapshot driver)
    (Eta_crux_test.Projection_harness.Opaque.snapshot_value witness)

let handle_latest_committed_snapshot witness handle =
  Option.bind (Eta_crux_test.Handle.latest_committed_snapshot handle)
    (Eta_crux_test.Projection_harness.Opaque.snapshot_value witness)

let handle_latest_delivered_snapshot witness handle =
  Option.bind (Eta_crux_test.Handle.latest_delivered_snapshot handle)
    (Eta_crux_test.Projection_harness.Opaque.snapshot_value witness)
module Crux_test = Eta_crux_test

let run_ok runtime eff =
  Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let inject_ok runtime eff =
  eff
  |> Eta.Effect.or_die (function
       | Crux_test.Handle.No_projection ->
           Failure "test injection has no output"
       | Crux_test.Handle.Ingress_closed ->
           Failure "test injection ingress closed")
  |> run_ok runtime

let quiet_shell =
  {
    Crux_test.Test_shell.pp_error =
      (fun _ (error : Crux.never) ->
        match error with _ -> .);
    deliver = (fun _ -> Eta.Effect.unit);
    request_event = (fun _ -> Eta.Effect.unit);
    crash_detected = (fun _ -> Eta.Effect.unit);
  }

let test_frame_boundary () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self ~input:() ~model ~action ->
        ( model + action,
          Some
            (Crux.Endpoint.send self action
            |> Eta.Effect.ignore_errors) ))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun snapshot action ->
             let _model, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:quiet_shell root
  in
  let initial =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match initial with
  | Ok { outcome = Committed snapshot; _ }
    when fst (Projection.snapshot_value witness snapshot |> Option.get) = 0 -> ()
  | _ -> Alcotest.fail "initial frame did not commit once");
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 1));
  let first =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match first with
  | Ok { outcome = Committed snapshot; _ }
    when fst (Projection.snapshot_value witness snapshot |> Option.get) = 1 -> ()
  | _ ->
      Alcotest.fail
        "frame crossed the one-advancement boundary");
  let second =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match second with
  | Ok { outcome = Committed snapshot; _ }
    when fst (Projection.snapshot_value witness snapshot |> Option.get) = 2 -> ()
  | _ ->
      Alcotest.fail
        "post-commit action was not left for the next frame");
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_incoming_uses_endpoint () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let observed_outputs = ref [] in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let incoming witness =
    Crux_test.Incoming.create
      ~send:(fun snapshot action ->
        let model, endpoint =
          Projection.snapshot_value witness snapshot |> Option.get
        in
        observed_outputs := model :: !observed_outputs;
        Crux.Endpoint.send endpoint action)
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create ~clock ~incoming:(incoming witness)
      ~shell:quiet_shell root
  in
  Alcotest.(check bool) "injection requires delivered output" true
    (run_ok runtime (Eta.Effect.to_result
       (Crux_test.Handle.inject handle 1))
    = Error Crux_test.Handle.No_projection);
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 3));
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 4));
  Alcotest.(check (list int)) "latest delivered snapshots" [ 0; 3 ]
    (List.rev !observed_outputs);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_handle_exclusive_ownership () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let deliveries = Eta_test.Controlled.create () in
  let shell =
    {
      Crux_test.Test_shell.pp_error = Format.pp_print_string;
      deliver =
        (fun delivery ->
          Eta_test.Controlled.eff deliveries delivery);
      request_event = (fun _ -> Eta.Effect.unit);
      crash_detected = (fun _ -> Eta.Effect.unit);
    }
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 1)
  in
  let handle =
    Crux_test.Handle.create ~clock ~incoming:Crux_test.Incoming.none
      ~shell root
  in
  let first =
    Eta_test.Async.fork_run switch runtime
      (Crux_test.Handle.frame handle)
  in
  let call =
    run_ok runtime (Eta_test.Controlled.await_call deliveries)
  in
  Alcotest.(check bool) "concurrent frame is busy" true
    (run_ok runtime (Crux_test.Handle.frame handle)
    = Error Crux_test.Handle.Busy);
  Alcotest.(check bool) "delivery completion accepted" true
    (Eta_test.Controlled.succeed call () = Ok ());
  (match Eta_test.Async.await first with
  | Eta.Exit.Ok
      (Ok { Crux_test.Handle.outcome = Committed snapshot; _ })
      when Projection.snapshot_value witness snapshot = Some 1 ->
      ()
  | _ -> Alcotest.fail "first frame did not resume");
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_handle_bracket_cleanup () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let normal_root, _normal_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  ignore
    (run_ok runtime
       (Crux_test.Handle.use
          ~clock
          ~incoming:Crux_test.Incoming.none
          ~shell:quiet_shell normal_root
          ~f:(fun _ -> Eta.Effect.unit)));
  Alcotest.(check bool) "driver fence remains after bracket" true
    (match run_ok runtime (Crux.Root.advance normal_root) with
    | Error Crux.Root.Driver_attached -> true
    | _ -> false);

  let crashing_root, _crashing_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.map (Crux.return ()) ~f:(fun () ->
           raise (Failure "unobserved-crash")))
  in
  let unobserved =
    Eta.Runtime.run runtime
      (Crux_test.Handle.use
         ~clock
         ~incoming:Crux_test.Incoming.none
         ~shell:quiet_shell crashing_root
         ~f:(fun handle ->
           Crux_test.Handle.poll handle
           |> Eta.Effect.map (fun _ -> ())))
  in
  Alcotest.(check bool) "unobserved crash fails bracket" true
    (match unobserved with
    | Eta.Exit.Error (Eta.Cause.Finalizer _)
    | Eta.Exit.Error (Eta.Cause.Suppressed _) ->
        true
    | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false);

  let observed_root, _observed_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.map (Crux.return ()) ~f:(fun () ->
           raise (Failure "observed-crash")))
  in
  let observed =
    Eta_test.Run.run ~clock
      (Crux_test.Handle.use
         ~clock
         ~incoming:Crux_test.Incoming.none
         ~shell:quiet_shell observed_root
         ~f:(fun handle ->
           Crux_test.Handle.frame handle
           |> Eta.Effect.map (function
                | Ok
                    {
                      Crux_test.Handle.outcome =
                        Crashed _;
                      _;
                    } ->
                    ()
                | _ ->
                    Alcotest.fail
                      "crash terminal was not observable")))
  in
  ignore (Eta_test.Expect.expect_ok observed.exit)

let test_snapshot_only_observation () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let delivered = ref [] in
  let shell witness =
    {
      Crux_test.Test_shell.pp_error =
        (fun _ (error : Crux.never) ->
          match error with _ -> .);
      deliver =
        (fun delivery ->
          delivered :=
            (Projection.delivery_value witness
               delivery.Crux.Adapter.projection
            |> Option.get)
            :: !delivered;
          Eta.Effect.unit);
      request_event = (fun _ -> Eta.Effect.unit);
      crash_detected = (fun _ -> Eta.Effect.unit);
    }
  in
  let left =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let right =
    Crux.State_machine.create (Crux.return ())
      ~default_model:10
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let description =
    Crux.map (Crux.both left right)
      ~f:(fun ((left_model, left_endpoint), (right_model, _)) ->
        ((left_model, right_model), left_endpoint))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      description
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun snapshot action ->
             let _, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:(shell witness) root
  in
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 1));
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (list (pair int int)))
    "adapter retained complete committed snapshots"
    [ (0, 10); (1, 10) ]
    (List.rev_map fst !delivered);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

type commit_boundary_event =
  | Stabilizing
  | Delivering of int
  | Post_commit

let test_adapter_commit_boundary () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let events = ref [] in
  let shell witness =
    {
      Crux_test.Test_shell.pp_error =
        (fun _ (error : Crux.never) ->
          match error with _ -> .);
      deliver =
        (fun delivery ->
          events :=
            Delivering
              (fst
                 (Projection.delivery_value witness
                    delivery.Crux.Adapter.projection
                 |> Option.get))
            :: !events;
          Eta.Effect.unit);
      request_event = (fun _ -> Eta.Effect.unit);
      crash_detected = (fun _ -> Eta.Effect.unit);
    }
  in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        events := Stabilizing :: !events;
        ( action,
          Some
            (Eta.Effect.sync (fun () ->
                 events := Post_commit :: !events)) ))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun snapshot action ->
             let _, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:(shell witness) root
  in
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  events := [];
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 7));
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check int) "phase event count" 3
    (List.length !events);
  (match List.rev !events with
  | [ Stabilizing; Delivering 7; Post_commit ] -> ()
  | _ ->
      Alcotest.fail
        "adapter delivery did not remain between commit and post-commit work");
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_handle_projection_boundaries () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.after (Eta.Duration.ms 10))
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:Crux_test.Incoming.none
      ~shell:quiet_shell root
  in
  Alcotest.(check (option bool)) "no committed snapshot" None
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check (option bool)) "no delivered output" None
    (handle_latest_delivered_snapshot witness handle);
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option bool)) "initial commit visible" (Some false)
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check (option bool)) "initial delivery visible" (Some false)
    (handle_latest_delivered_snapshot witness handle);
  Crux_test.Handle.advance_time_by handle (Eta.Duration.ms 5);
  Crux_test.Handle.advance_time_to handle 10;
  Alcotest.(check int) "handle moved only its clock" 10
    (Eta_test.Test_clock.now_ms clock);
  Alcotest.(check (option bool)) "movement did not run driver" (Some false)
    (handle_latest_committed_snapshot witness handle);
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option bool)) "due commit visible" (Some true)
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check (option bool)) "due delivery visible" (Some true)
    (handle_latest_delivered_snapshot witness handle);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let poll_delivery runtime handle =
  match run_ok runtime (Crux_test.Handle.poll handle) with
  | Ok (Some (Crux.Driver.Deliver delivery)) -> delivery
  | _ -> Alcotest.fail "expected a pending projection delivery"

let test_projection_delivered_shadow () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2
      ~request_capacity:1 machine
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:
        (Crux_test.Incoming.create ~send:(fun snapshot action ->
             let _, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:quiet_shell root
  in
  Alcotest.(check (option int)) "no committed snapshot" None
    (Option.map fst (handle_latest_committed_snapshot witness handle));
  Alcotest.(check (option int)) "no delivered snapshot" None
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  let initial = poll_delivery runtime handle in
  Alcotest.(check (option int)) "commit published before answer" (Some 0)
    (Option.map fst (handle_latest_committed_snapshot witness handle));
  Alcotest.(check (option int)) "pending delivery retained no state" None
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  Alcotest.(check bool) "initial delivery accepted" true
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle initial)
    = Ok ());
  Alcotest.(check (option int)) "accepted delivery installed" (Some 0)
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 7));
  let changed = poll_delivery runtime handle in
  Alcotest.(check (option int)) "new commit published" (Some 7)
    (Option.map fst (handle_latest_committed_snapshot witness handle));
  Alcotest.(check (option int)) "pending delivery retained prior state" (Some 0)
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  let cause =
    Crux.Failure.Packed_cause.make ~pp_error:Format.pp_print_string
      (Eta.Cause.fail "injected delivery failure")
  in
  Alcotest.(check bool) "failed answer accepted once" true
    (run_ok runtime
       (Crux_test.Handle.delivery_failed handle changed cause)
    = Ok ());
  Alcotest.(check (option int)) "failed delivery did not install" (Some 0)
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  Alcotest.(check bool) "failed delivery cannot be accepted later" true
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle changed)
    = Error Crux.Driver.Delivery.Already_completed);
  Alcotest.(check (option int)) "late answer did not install" (Some 0)
    (Option.map fst (handle_latest_delivered_snapshot witness handle));
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_projection_install_before_ack () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let handle_ref = ref None in
  let witness_ref = ref None in
  let observed_at_post_commit = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some
            (Eta.Effect.sync (fun () ->
                 let handle = Option.get !handle_ref in
                 observed_at_post_commit :=
                   Option.map fst
                     (handle_latest_delivered_snapshot
                        (Option.get !witness_ref) handle))) ))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2
      ~request_capacity:1 machine
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:
        (Crux_test.Incoming.create ~send:(fun snapshot action ->
             let _, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:quiet_shell root
  in
  witness_ref := Some witness;
  handle_ref := Some handle;
  let initial = poll_delivery runtime handle in
  ignore
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle initial));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 9));
  let changed = poll_delivery runtime handle in
  ignore
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle changed));
  let rec await attempts =
    if !observed_at_post_commit = Some 9 then ()
    else if attempts = 0 then
      Alcotest.fail "post-commit effect did not observe installed state"
    else (
      ignore (run_ok runtime Eta.Effect.yield);
      await (attempts - 1))
  in
  await 100;
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_projection_responder_one_answer () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root, _witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1
      ~request_capacity:1 (Crux.return 1)
  in
  let handle =
    Crux_test.Handle.create ~clock ~incoming:Crux_test.Incoming.none
      ~shell:quiet_shell root
  in
  let delivery = poll_delivery runtime handle in
  Alcotest.(check bool) "first answer accepted" true
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle delivery)
    = Ok ());
  Alcotest.(check bool) "second answer rejected" true
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle delivery)
    = Error Crux.Driver.Delivery.Already_completed);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_projection_held_delivery_fences_post_commit () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let effect_started = ref false in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some
            (Eta.Effect.sync (fun () ->
                 effect_started := true)) ))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2
      ~request_capacity:1 machine
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:
        (Crux_test.Incoming.create ~send:(fun snapshot action ->
             let _, endpoint =
               Projection.snapshot_value witness snapshot |> Option.get
             in
             Crux.Endpoint.send endpoint action))
      ~shell:quiet_shell root
  in
  let initial = poll_delivery runtime handle in
  ignore
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle initial));
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 1));
  let held = poll_delivery runtime handle in
  ignore (run_ok runtime Eta.Effect.yield);
  Alcotest.(check bool) "held delivery fenced post-commit work" false
    !effect_started;
  Alcotest.(check bool) "driver remains fenced" true
    (run_ok runtime (Crux_test.Handle.poll handle) = Ok None);
  ignore
    (run_ok runtime
       (Crux_test.Handle.delivery_delivered handle held));
  let rec await attempts =
    if !effect_started then ()
    else if attempts = 0 then
      Alcotest.fail "acknowledgment did not admit post-commit work"
    else (
      ignore (run_ok runtime Eta.Effect.yield);
      await (attempts - 1))
  in
  await 100;
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_graph_time_handle_separation () =
  (* GTC-16: moving test time neither advances Eta Crux nor triggers Poll.
     A later frame observes the due work through the production driver. *)
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let provider_calls = ref 0 in
  let due = Crux.Time.after (Eta.Duration.ms 10) in
  let polled =
    Crux.Poll.effect_on_change
      ~input_cutoff:(Crux.Cutoff.of_equal Bool.equal)
      ~starting:Crux.Poll.Starting.empty ~input:due
      ~effect:
        (Crux.return (fun due ->
             Eta.Effect.sync (fun () ->
                 incr provider_calls;
                 due)))
      ()
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.both due polled)
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:Crux_test.Incoming.none ~shell:quiet_shell root
  in
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option (pair bool (option bool))))
    "initial commit" (Some (false, None))
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check int) "activation ran the Poll provider" 1
    !provider_calls;
  Crux_test.Handle.advance_time_to handle 10;
  Alcotest.(check (option (pair bool (option bool))))
    "movement did not advance" (Some (false, None))
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check int) "movement did not trigger Poll" 1
    !provider_calls;
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option (pair bool (option bool))))
    "frame observed the due commit" (Some (true, None))
    (handle_latest_committed_snapshot witness handle);
  Alcotest.(check int) "due commit triggered Poll" 2
    !provider_calls;
  ignore
    (run_ok runtime (Crux_test.Handle.drain handle ~max_steps:8));
  Alcotest.(check (option (pair bool (option bool))))
    "drain published the Poll result" (Some (true, Some true))
    (handle_latest_committed_snapshot witness handle);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_graph_time_handle_validation () =
  (* GTC-17: test movement never moves time backward. Negative deltas are
     unrepresentable: Eta.Duration clamps them to zero, which is a no-op.
     Backward targets raise Invalid_argument. Zero movement is a no-op. *)
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 0)
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:Crux_test.Incoming.none ~shell:quiet_shell root
  in
  Crux_test.Handle.advance_time_by handle Eta.Duration.zero;
  Crux_test.Handle.advance_time_by handle (Eta.Duration.ms (-1));
  Crux_test.Handle.advance_time_to handle 0;
  Alcotest.(check int) "zero and clamped movement is a no-op" 0
    (Eta_test.Test_clock.now_ms clock);
  Crux_test.Handle.advance_time_to handle 10;
  (match Crux_test.Handle.advance_time_to handle 5 with
  | () -> Alcotest.fail "backward target was accepted"
  | exception Invalid_argument _ -> ());
  Alcotest.(check int) "failed movement preserved time" 10
    (Eta_test.Test_clock.now_ms clock);
  Alcotest.(check (option int)) "no movement ran the driver" None
    (handle_latest_committed_snapshot witness handle);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let () =
  Alcotest.run "eta_crux test surface"
    [
      ( "handle",
        [
          Alcotest.test_case "frame boundary" `Quick
            test_frame_boundary;
          Alcotest.test_case "incoming uses endpoint" `Quick
            test_incoming_uses_endpoint;
          Alcotest.test_case "exclusive ownership" `Quick
            test_handle_exclusive_ownership;
          Alcotest.test_case "bracket cleanup" `Quick
            test_handle_bracket_cleanup;
          Alcotest.test_case "snapshot only observation" `Quick
            test_snapshot_only_observation;
          Alcotest.test_case "adapter commit boundary" `Quick
            test_adapter_commit_boundary;
          Alcotest.test_case "clock and output boundaries" `Quick
            test_handle_projection_boundaries;
          Alcotest.test_case "projection delivered shadow" `Quick
            test_projection_delivered_shadow;
          Alcotest.test_case "projection install before ack" `Quick
            test_projection_install_before_ack;
          Alcotest.test_case "projection responder one answer" `Quick
            test_projection_responder_one_answer;
          Alcotest.test_case "held projection delivery fence" `Quick
            test_projection_held_delivery_fences_post_commit;
          Alcotest.test_case "graph time handle separation" `Quick
            test_graph_time_handle_separation;
          Alcotest.test_case "graph time handle validation" `Quick
            test_graph_time_handle_validation;
        ] );
    ]
