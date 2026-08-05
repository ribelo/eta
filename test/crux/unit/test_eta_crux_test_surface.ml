module Crux = Eta_crux
module Crux_test = Eta_crux_test

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let inject_ok runtime effect =
  effect
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
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self ~input:() ~model ~action ->
        ( model + action,
          Crux.Endpoint.send self action
          |> Eta.Effect.ignore_errors ))
  in
  let root =
    Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
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
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observed_outputs = ref [] in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
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
    Crux_test.Handle.create ~incoming ~shell:quiet_shell root
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
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let deliveries = Eta_test.Controlled.create () in
  let shell =
    {
      Crux_test.Test_shell.pp_error = Format.pp_print_string;
      deliver =
        (fun delivery ->
          Eta_test.Controlled.effect deliveries delivery);
      request_event = (fun _ -> Eta.Effect.unit);
      crash_detected = (fun _ -> Eta.Effect.unit);
    }
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 1)
  in
  let handle =
    Crux_test.Handle.create ~incoming:Crux_test.Incoming.none
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
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let normal_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  ignore
    (run_ok runtime
       (Crux_test.Handle.use
          ~incoming:Crux_test.Incoming.none
          ~shell:quiet_shell normal_root
          ~f:(fun _ -> Eta.Effect.unit)));
  Alcotest.(check bool) "normal bracket settled root" true
    (match run_ok runtime (Crux.Root.advance normal_root) with
    | Error Crux.Root.Closed -> true
    | _ -> false);

  let crashing_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.map (Crux.return ()) ~f:(fun () ->
           raise (Failure "unobserved-crash")))
  in
  let unobserved =
    Eta.Runtime.run runtime
      (Crux_test.Handle.use
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
    Eta_test.Run.run
      (Crux_test.Handle.use
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
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
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
        (action, Eta.Effect.unit))
  in
  let right =
    Crux.State_machine.create (Crux.return ())
      ~default_model:10
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, Eta.Effect.unit))
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
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
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
          Eta.Effect.sync (fun () ->
              events := Post_commit :: !events) ))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      machine
  in
  let handle =
    Crux_test.Handle.create
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
        ] );
    ]
