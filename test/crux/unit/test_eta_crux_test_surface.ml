module Crux = Eta_crux
module Crux_test = Eta_crux_test

let run_ok runtime eff =
  Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let inject_ok runtime eff =
  eff
  |> Eta.Effect.or_die (function
       | Crux_test.Handle.No_output ->
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
  let root =
    Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun (_model, endpoint) action ->
             Crux.Endpoint.send endpoint action))
      ~shell:quiet_shell root
  in
  let initial =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match initial with
  | Ok { outcome = Committed (0, _); _ } -> ()
  | _ -> Alcotest.fail "initial frame did not commit once");
  ignore (inject_ok runtime (Crux_test.Handle.inject handle 1));
  let first =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match first with
  | Ok { outcome = Committed (1, _); _ } -> ()
  | _ ->
      Alcotest.fail
        "frame crossed the one-advancement boundary");
  let second =
    run_ok runtime (Crux_test.Handle.frame handle)
  in
  (match second with
  | Ok { outcome = Committed (2, _); _ } -> ()
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
  let incoming =
    Crux_test.Incoming.create
      ~send:(fun ((model, endpoint) as _output) action ->
        observed_outputs := model :: !observed_outputs;
        Crux.Endpoint.send endpoint action)
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create ~clock ~incoming ~shell:quiet_shell root
  in
  Alcotest.(check bool) "injection requires delivered output" true
    (run_ok runtime (Eta.Effect.to_result
       (Crux_test.Handle.inject handle 1))
    = Error Crux_test.Handle.No_output);
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
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
      (Ok { Crux_test.Handle.outcome = Committed 1; _ }) ->
      ()
  | _ -> Alcotest.fail "first frame did not resume");
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_handle_bracket_cleanup () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let normal_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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

  let crashing_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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

  let observed_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
  let shell =
    {
      Crux_test.Test_shell.pp_error =
        (fun _ (error : Crux.never) ->
          match error with _ -> .);
      deliver =
        (fun delivery ->
          delivered :=
            delivery.Crux.Adapter.output
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
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      description
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun (_, endpoint) action ->
             Crux.Endpoint.send endpoint action))
      ~shell root
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
  let shell =
    {
      Crux_test.Test_shell.pp_error =
        (fun _ (error : Crux.never) ->
          match error with _ -> .);
      deliver =
        (fun delivery ->
          events :=
            Delivering
              (fst delivery.Crux.Adapter.output)
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
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
      ~clock
      ~incoming:
        (Crux_test.Incoming.create
           ~send:(fun (_, endpoint) action ->
             Crux.Endpoint.send endpoint action))
      ~shell root
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

let test_handle_output_boundaries () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.after (Eta.Duration.ms 10))
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:Crux_test.Incoming.none
      ~shell:quiet_shell root
  in
  Alcotest.(check (option bool)) "no committed output" None
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check (option bool)) "no delivered output" None
    (Crux_test.Handle.latest_delivered_output handle);
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option bool)) "initial commit visible" (Some false)
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check (option bool)) "initial delivery visible" (Some false)
    (Crux_test.Handle.latest_delivered_output handle);
  Crux_test.Handle.advance_time_by handle (Eta.Duration.ms 5);
  Crux_test.Handle.advance_time_to handle 10;
  Alcotest.(check int) "handle moved only its clock" 10
    (Eta_test.Test_clock.now_ms clock);
  Alcotest.(check (option bool)) "movement did not run driver" (Some false)
    (Crux_test.Handle.latest_committed_output handle);
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option bool)) "due commit visible" (Some true)
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check (option bool)) "due delivery visible" (Some true)
    (Crux_test.Handle.latest_delivered_output handle);
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
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both due polled)
  in
  let handle =
    Crux_test.Handle.create ~clock
      ~incoming:Crux_test.Incoming.none ~shell:quiet_shell root
  in
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option (pair bool (option bool))))
    "initial commit" (Some (false, None))
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check int) "activation ran the Poll provider" 1
    !provider_calls;
  Crux_test.Handle.advance_time_to handle 10;
  Alcotest.(check (option (pair bool (option bool))))
    "movement did not advance" (Some (false, None))
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check int) "movement did not trigger Poll" 1
    !provider_calls;
  ignore (run_ok runtime (Crux_test.Handle.frame handle));
  Alcotest.(check (option (pair bool (option bool))))
    "frame observed the due commit" (Some (true, None))
    (Crux_test.Handle.latest_committed_output handle);
  Alcotest.(check int) "due commit triggered Poll" 2
    !provider_calls;
  ignore
    (run_ok runtime (Crux_test.Handle.drain handle ~max_steps:8));
  Alcotest.(check (option (pair bool (option bool))))
    "drain published the Poll result" (Some (true, Some true))
    (Crux_test.Handle.latest_committed_output handle);
  ignore (run_ok runtime (Crux_test.Handle.stop handle))

let test_graph_time_handle_validation () =
  (* GTC-17: test movement never moves time backward. Negative deltas are
     unrepresentable: Eta.Duration clamps them to zero, which is a no-op.
     Backward targets raise Invalid_argument. Zero movement is a no-op. *)
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
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
    (Crux_test.Handle.latest_committed_output handle);
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
            test_handle_output_boundaries;
          Alcotest.test_case "graph time handle separation" `Quick
            test_graph_time_handle_separation;
          Alcotest.test_case "graph time handle validation" `Quick
            test_graph_time_handle_validation;
        ] );
    ]
