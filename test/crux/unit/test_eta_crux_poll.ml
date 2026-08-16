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
module Observer = Eta_crux_test.Post_commit_effect_observer

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let start runtime post_commit =
  ignore
    (run_ok runtime
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
              Invalid_argument "post-commit already started")))

type 'output advancement = {
  output : 'output;
  post_commit : Crux.Post_commit.t;
}

let advance runtime witness root =
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Committed { commit; post_commit }) ->
      let output = output_of_commit witness commit in
      { output; post_commit }
  | Ok Crux.Root.Idle -> Alcotest.fail "expected Poll commit, got idle"
  | Ok (Crux.Root.Rejected _) ->
      Alcotest.fail "expected Poll commit, got rejection"
  | Ok (Crux.Root.Stopped _) ->
      Alcotest.fail "expected Poll commit, got stop"
  | Ok (Crux.Root.Failed _) ->
      Alcotest.fail "expected Poll commit, got failure"
  | Error _ -> Alcotest.fail "expected Poll commit, got advance error"

let send runtime endpoint action =
  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint action
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")))

let invoke_refresh runtime effect =
  ignore
    (run_ok runtime
       (effect
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "refresh ingress closed")))

let staged_effects observer =
  match Observer.poll observer with
  | Some (Observer.Staged { effects; _ }) -> effects
  | Some _ | None -> Alcotest.fail "missing Poll Staged event"

let yield_many () =
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done

let test_poll_activation_input_and_provider_sampling () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let calls = ref [] in
  let input =
    Crux.State_machine.create (Crux.return ()) ~default_model:1
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let provider =
    Crux.State_machine.create (Crux.return ()) ~default_model:2
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let provider_value =
    Crux.map provider ~f:(fun (multiplier, _) input ->
        Eta.Effect.sync (fun () ->
            calls := (input, multiplier) :: !calls;
            input * multiplier))
  in
  let polled =
    Crux.Poll.effect_on_change
      ~input_cutoff:(Crux.Cutoff.of_equal Int.equal)
      ~starting:Crux.Poll.Starting.empty
      ~input:(Crux.map input ~f:fst)
      ~effect:provider_value ()
  in
  let description =
    Crux.map
      (Crux.both input (Crux.both provider polled))
      ~f:(fun
           ((input, input_endpoint),
            ((provider, provider_endpoint), result)) ->
        (input, input_endpoint, provider, provider_endpoint, result))
  in
  let root, witness =
    Projection.root ~projection_capacity:1
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:4 ~request_capacity:1 description
  in
  let initial = advance runtime witness root in
  let input, input_endpoint, provider, provider_endpoint, result =
    initial.output
  in
  Alcotest.(check (triple int int (option int))) "starting output"
    (1, 2, None) (input, provider, result);
  Alcotest.(check int) "activation inventory" 1
    (List.length (staged_effects observer));
  Alcotest.(check int) "provider waits for post-commit" 0
    (List.length !calls);
  start runtime initial.post_commit;
  yield_many ();
  Alcotest.(check (list (pair int int))) "activation provider"
    [ (1, 2) ] (List.rev !calls);
  ignore (Observer.drain observer);
  let completion = advance runtime witness root in
  let _, _, _, _, result = completion.output in
  Alcotest.(check (option int)) "activation completion"
    (Some 2) result;
  Alcotest.(check int) "completion stages no Poll run" 0
    (List.length (staged_effects observer));
  start runtime completion.post_commit;

  send runtime provider_endpoint 3;
  let provider_change = advance runtime witness root in
  let _, _, provider, _, result = provider_change.output in
  Alcotest.(check (pair int (option int))) "provider-only output"
    (3, Some 2) (provider, result);
  Alcotest.(check int) "provider-only inventory" 0
    (List.length (staged_effects observer));
  start runtime provider_change.post_commit;
  yield_many ();
  Alcotest.(check int) "provider-only change started no run" 1
    (List.length !calls);

  send runtime input_endpoint 4;
  let input_change = advance runtime witness root in
  let input, _, _, _, result = input_change.output in
  Alcotest.(check (pair int (option int))) "trigger output precedes run"
    (4, Some 2) (input, result);
  Alcotest.(check int) "input change inventory" 1
    (List.length (staged_effects observer));
  start runtime input_change.post_commit;
  yield_many ();
  Alcotest.(check (list (pair int int))) "latest provider sampled"
    [ (1, 2); (4, 3) ] (List.rev !calls);
  ignore (Observer.drain observer);
  let completion = advance runtime witness root in
  let _, _, _, _, result = completion.output in
  Alcotest.(check (option int)) "new provider result"
    (Some 12) result;
  start runtime completion.post_commit

let test_poll_manual_refresh_committed_run_order () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let controlled = Eta_test.Controlled.create () in
  let effect =
    Crux.return (Eta_test.Controlled.eff controlled ())
  in
  let result, refresh =
    Crux.Poll.manual_refresh
      ~starting:Crux.Poll.Starting.empty ~effect ()
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
      (Crux.both result refresh)
  in
  let initial = advance runtime witness root in
  let result, refresh = initial.output in
  Alcotest.(check (option int)) "manual starting output" None result;
  start runtime initial.post_commit;

  invoke_refresh runtime refresh;
  let first_run = advance runtime witness root in
  Alcotest.(check (option int)) "first trigger keeps output" None
    (fst first_run.output);
  start runtime first_run.post_commit;
  let first_call =
    run_ok runtime (Eta_test.Controlled.await_call controlled)
  in

  invoke_refresh runtime refresh;
  let second_run = advance runtime witness root in
  start runtime second_run.post_commit;
  let second_call =
    run_ok runtime (Eta_test.Controlled.await_call controlled)
  in
  Alcotest.(check bool) "newer run completed first" true
    (Eta_test.Controlled.succeed second_call 20 = Ok ());
  yield_many ();
  Alcotest.(check bool) "older run completed second" true
    (Eta_test.Controlled.succeed first_call 10 = Ok ());
  yield_many ();

  let newer = advance runtime witness root in
  Alcotest.(check (option int)) "newer completion selected"
    (Some 20) (fst newer.output);
  start runtime newer.post_commit;
  let stale = advance runtime witness root in
  Alcotest.(check (option int)) "older completion stayed stale"
    (Some 20) (fst stale.output);
  start runtime stale.post_commit

let test_poll_stale_refresh_after_disposal () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let description =
    Crux.bind selector ~f:(fun (active, endpoint) ->
        if not active then Crux.return (endpoint, None)
        else
          let _result, refresh =
            Crux.Poll.manual_refresh
              ~starting:Crux.Poll.Starting.empty
              ~effect:(Crux.return (Eta.Effect.pure 1)) ()
          in
          Crux.map refresh ~f:(fun refresh ->
              (endpoint, Some refresh)))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      description
  in
  let initial = advance runtime witness root in
  let selector_endpoint, refresh = initial.output in
  let refresh = Option.get refresh in
  start runtime initial.post_commit;
  send runtime selector_endpoint false;
  let disposed = advance runtime witness root in
  start runtime disposed.post_commit;
  invoke_refresh runtime refresh;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> ()
  | _ -> Alcotest.fail "retained Poll refresh was not stale"

let test_poll_result_cutoff_order_fence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let controlled = Eta_test.Controlled.create () in
  let cutoff_calls = ref 0 in
  let result, refresh =
    Crux.Poll.manual_refresh
      ~result_cutoff:
        (Crux.Cutoff.of_equal (fun left right ->
             incr cutoff_calls;
             Int.equal left right))
      ~starting:(Crux.Poll.Starting.initial 5)
      ~effect:
        (Crux.return (Eta_test.Controlled.eff controlled ()))
      ()
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
      (Crux.both result refresh)
  in
  let initial = advance runtime witness root in
  let _, refresh = initial.output in
  start runtime initial.post_commit;
  let start_run () =
    invoke_refresh runtime refresh;
    let trigger = advance runtime witness root in
    start runtime trigger.post_commit;
    run_ok runtime (Eta_test.Controlled.await_call controlled)
  in
  let older = start_run () in
  let newer_equal = start_run () in
  Alcotest.(check bool) "newer equal completed" true
    (Eta_test.Controlled.succeed newer_equal 5 = Ok ());
  yield_many ();
  Alcotest.(check bool) "older different completed" true
    (Eta_test.Controlled.succeed older 9 = Ok ());
  yield_many ();
  let equal_completion = advance runtime witness root in
  Alcotest.(check int) "newer equal called cutoff" 1 !cutoff_calls;
  Alcotest.(check int) "equal result remained published" 5
    (fst equal_completion.output);
  start runtime equal_completion.post_commit;
  let stale_completion = advance runtime witness root in
  Alcotest.(check int) "stale completion skipped cutoff" 1 !cutoff_calls;
  Alcotest.(check int) "stale result fenced" 5
    (fst stale_completion.output);
  start runtime stale_completion.post_commit;
  let latest = start_run () in
  Alcotest.(check bool) "latest completed" true
    (Eta_test.Controlled.succeed latest 7 = Ok ());
  yield_many ();
  let latest_completion = advance runtime witness root in
  Alcotest.(check int) "later result called cutoff" 2 !cutoff_calls;
  Alcotest.(check int) "later result published" 7
    (fst latest_completion.output);
  start runtime latest_completion.post_commit

let test_poll_post_commit_phase_order () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let transitions = Eta_test.Controlled.create () in
  let polls = Eta_test.Controlled.create () in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some (Eta_test.Controlled.eff transitions action) ))
  in
  let polled =
    Crux.Poll.effect_on_change
      ~input_cutoff:(Crux.Cutoff.of_equal Int.equal)
      ~starting:Crux.Poll.Starting.empty
      ~input:(Crux.map machine ~f:fst)
      ~effect:
        (Crux.return (fun input ->
             Eta_test.Controlled.eff polls input))
      ()
  in
  let description = Crux.both machine polled in
  let root, witness =
    Projection.root ~projection_capacity:1
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:4 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let accept () =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) ->
        let output = output_of_delivery witness delivery in
        ignore
          (run_ok runtime
             (Crux.Driver.Delivery.delivered delivery));
        output
    | _ -> Alcotest.fail "expected Poll phase delivery"
  in
  let (model, endpoint), _ = accept () in
  Alcotest.(check int) "initial model" 0 model;
  let initial_call =
    run_ok runtime (Eta_test.Controlled.await_call polls)
  in
  ignore (Eta_test.Controlled.succeed initial_call 0);
  yield_many ();
  ignore (accept ());
  ignore (Observer.drain observer);

  send runtime endpoint 7;
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "mixed commit did not deliver"
  in
  let (model, _), result = output_of_delivery witness delivery in
  Alcotest.(check (pair int (option int)))
    "complete output published before effects" (7, Some 0)
    (model, result);
  Alcotest.(check int) "transition and Poll inventory" 2
    (List.length (staged_effects observer));
  Alcotest.(check bool) "transition not started before delivery" true
    (Eta_test.Controlled.poll_call transitions = None);
  Alcotest.(check bool) "Poll not started before delivery" true
    (Eta_test.Controlled.poll_call polls = None);
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.delivered delivery));
  let transition_call =
    run_ok runtime (Eta_test.Controlled.await_call transitions)
  in
  let poll_call =
    run_ok runtime (Eta_test.Controlled.await_call polls)
  in
  Alcotest.(check bool) "Poll settles first" true
    (Eta_test.Controlled.succeed poll_call 70 = Ok ());
  yield_many ();
  Alcotest.(check bool) "transition settles second" true
    (Eta_test.Controlled.succeed transition_call () = Ok ());
  yield_many ();
  let events = Observer.drain observer in
  Alcotest.(check int) "both effects started" 2
    (List.length
       (List.filter
          (function Observer.Started _ -> true | _ -> false)
          events));
  Alcotest.(check int) "both effects settled" 2
    (List.length
       (List.filter
          (function Observer.Settled _ -> true | _ -> false)
          events))

let test_poll_failure_attribution () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let polled =
    Crux.Poll.effect_on_change
      ~input_cutoff:Crux.Cutoff.never
      ~starting:Crux.Poll.Starting.empty
      ~input:(Crux.return ())
      ~effect:
        (Crux.return (fun () ->
             raise (Failure "provider defect")))
      ()
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1 polled
  in
  let initial = advance runtime witness root in
  start runtime initial.post_commit;
  yield_many ();
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Failed { failure; _ }) ->
      Alcotest.(check bool) "Poll defect origin" true
        (failure.Crux.Failure.primary.origin = Crux.Failure.Owned_work);
      Alcotest.(check bool) "Poll defect trigger" true
        (failure.Crux.Failure.primary.trigger = Crux.Failure.Poll_effect)
  | _ -> Alcotest.fail "Poll provider defect did not fail root"

let () =
  Alcotest.run "eta_crux poll"
    [
      ( "poll",
        [
          Alcotest.test_case "activation input and provider sampling"
            `Quick test_poll_activation_input_and_provider_sampling;
          Alcotest.test_case "manual committed run order" `Quick
            test_poll_manual_refresh_committed_run_order;
          Alcotest.test_case "stale refresh after disposal" `Quick
            test_poll_stale_refresh_after_disposal;
          Alcotest.test_case "result cutoff order fence" `Quick
            test_poll_result_cutoff_order_fence;
          Alcotest.test_case "post-commit phase order" `Quick
            test_poll_post_commit_phase_order;
          Alcotest.test_case "failure attribution" `Quick
            test_poll_failure_attribution;
        ] );
    ]
