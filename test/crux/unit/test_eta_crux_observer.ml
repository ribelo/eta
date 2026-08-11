module Crux = Eta_crux
module Observer = Eta_crux_test.Post_commit_effect_observer

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let accept_delivery runtime = function
  | Some (Crux.Driver.Deliver delivery) ->
      ignore
        (run_ok runtime
           (Crux.Driver.Delivery.delivered delivery));
      Crux.Driver.Delivery.output delivery
  | Some _ | None -> Alcotest.fail "expected delivery"

type action =
  | No_effect
  | Succeed
  | Fail
  | Interrupt
  | Never_started

let observer_machine ran =
  Crux.State_machine.create (Crux.return ())
    ~default_model:0
    ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
      match action with
      | No_effect -> (model + 1, None)
      | Succeed ->
          ( model + 1,
            Some (Eta.Effect.sync (fun () -> ran := true)) )
      | Fail ->
          (model + 1, Some (Eta.Effect.die_message "observed failure"))
      | Interrupt ->
          (model + 1, Some Eta.Effect.never)
      | Never_started ->
          ( model + 1,
            Some (Eta.Effect.sync (fun () -> ran := true)) ))

let create_driver observer ran =
  let root =
    Crux.Root.create
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:2 ~request_capacity:1
      (observer_machine ran)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  (root, driver)

let staged = function
  | Observer.Staged { position; commit; effects } ->
      ( Observer.Event_position.to_int64 position,
        Observer.Commit_index.to_int64 commit,
        effects )
  | _ -> Alcotest.fail "expected staged event"

let test_post_commit_effect_observer_inventory_and_lifecycle () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let ran = ref false in
  let _root, driver = create_driver observer ran in
  let model, endpoint =
    accept_delivery runtime (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check int) "initial model" 0 model;
  let position, commit, effects =
    match Observer.poll observer with
    | Some event -> staged event
    | None -> Alcotest.fail "initial staging was not observed"
  in
  Alcotest.(check int64) "initial position" 0L position;
  Alcotest.(check int64) "initial commit" 0L commit;
  Alcotest.(check int) "initial inventory empty" 0
    (List.length effects);
  Observer.expect_empty observer;

  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint No_effect
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")));
  ignore
    (accept_delivery runtime
       (run_ok runtime (Crux.Driver.poll driver)));
  let position, commit, effects =
    match Observer.poll observer with
    | Some event -> staged event
    | None -> Alcotest.fail "empty transition commit was not observed"
  in
  Alcotest.(check int64) "empty transition position" 1L position;
  Alcotest.(check int64) "empty transition commit" 1L commit;
  Alcotest.(check int) "no transition effect" 0
    (List.length effects);

  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint Succeed
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")));
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None -> Alcotest.fail "effect commit did not deliver"
  in
  let effect =
    match Observer.poll observer with
    | Some event ->
        let position, commit, effects = staged event in
        Alcotest.(check int64) "effect stage position" 2L position;
        Alcotest.(check int64) "effect commit" 2L commit;
        (match effects with
        | [ effect ] -> effect
        | _ -> Alcotest.fail "effect inventory was not exact")
    | None -> Alcotest.fail "effect staging was not observed"
  in
  Observer.expect_empty observer;
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.delivered delivery));
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool) "effect ran" true !ran;
  (match Observer.drain observer with
  | [
   Observer.Started { position = started_position; effect = started };
   Observer.Settled
     {
       position = settled_position;
       effect = settled;
       settlement = Observer.Succeeded;
     };
  ] ->
      Alcotest.(check int64) "started position" 3L
        (Observer.Event_position.to_int64 started_position);
      Alcotest.(check int64) "settled position" 4L
        (Observer.Event_position.to_int64 settled_position);
      Alcotest.(check bool) "started identity" true
        (Observer.Effect_id.compare effect started = 0);
      Alcotest.(check bool) "settled identity" true
        (Observer.Effect_id.compare effect settled = 0)
  | _ -> Alcotest.fail "effect lifecycle trace was incomplete");
  Observer.expect_empty observer;
  Crux.Driver.request_stop driver;
  ignore (run_ok runtime (Crux.Driver.poll driver))

let test_post_commit_effect_observer_discard_before_start () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let ran = ref false in
  let _root, driver = create_driver observer ran in
  let _, endpoint =
    accept_delivery runtime (run_ok runtime (Crux.Driver.poll driver))
  in
  ignore (Observer.drain observer);
  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint Never_started
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")));
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None -> Alcotest.fail "effect commit did not deliver"
  in
  let effect =
    match Observer.drain observer with
    | [ Observer.Staged { effects = [ effect ]; _ } ] -> effect
    | _ -> Alcotest.fail "discard candidate was not staged"
  in
  let cause =
    Crux.Failure.Packed_cause.make
      ~pp_error:Format.pp_print_string
      (Eta.Cause.fail "delivery failed")
  in
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.failed delivery cause));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  Alcotest.(check bool) "discarded effect did not run" false !ran;
  (match Observer.drain observer with
  | [ Observer.Discarded_before_start { effect = discarded; _ } ] ->
      Alcotest.(check bool) "discarded identity" true
        (Observer.Effect_id.compare effect discarded = 0)
  | _ -> Alcotest.fail "discard lifecycle was not recorded")

let test_post_commit_effect_observer_single_attachment () =
  let observer = Observer.create () in
  ignore
    (Crux.Root.create
       ~post_commit_effect_observer:(Observer.attachment observer)
       ~ingress_capacity:1 ~request_capacity:1
       (Crux.return ()));
  let rejected =
    try
      ignore
        (Crux.Root.create
           ~post_commit_effect_observer:(Observer.attachment observer)
           ~ingress_capacity:1 ~request_capacity:1
           (Crux.return ()));
      false
    with Invalid_argument _ -> true
  in
  Alcotest.(check bool) "second attachment rejected" true rejected

let test_post_commit_effect_observer_failure_and_interruption () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_case action expected =
    let observer = Observer.create () in
    let ran = ref false in
    let _root, driver = create_driver observer ran in
    let _, endpoint =
      accept_delivery runtime
        (run_ok runtime (Crux.Driver.poll driver))
    in
    ignore (Observer.drain observer);
    ignore
      (run_ok runtime
         (Crux.Endpoint.send endpoint action
         |> Eta.Effect.or_die (fun _ ->
                Invalid_argument "ingress closed")));
    let delivery =
      match run_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Deliver delivery) -> delivery
      | Some _ | None -> Alcotest.fail "effect commit did not deliver"
    in
    let effect =
      match Observer.drain observer with
      | [ Observer.Staged { effects = [ effect ]; _ } ] -> effect
      | _ -> Alcotest.fail "effect was not staged"
    in
    ignore
      (run_ok runtime
         (Crux.Driver.Delivery.delivered delivery));
    for _ = 1 to 10 do
      Eio.Fiber.yield ()
    done;
    (match action with
    | Interrupt ->
        Crux.Driver.request_stop driver;
        ignore (run_ok runtime (Crux.Driver.poll driver))
    | Fail ->
        ignore (run_ok runtime (Crux.Driver.poll driver))
    | No_effect | Succeed | Never_started -> assert false);
    for _ = 1 to 10 do
      Eio.Fiber.yield ()
    done;
    match Observer.drain observer with
    | [
     Observer.Started { effect = started; _ };
     Observer.Settled
       { effect = settled; settlement; _ };
    ] ->
        Observer.Effect_id.compare effect started = 0
        && Observer.Effect_id.compare effect settled = 0
        && settlement = expected
    | _ -> false
  in
  Alcotest.(check bool) "failed effect classified" true
    (run_case Fail Observer.Failed);
  Alcotest.(check bool) "interrupted effect classified" true
    (run_case Interrupt Observer.Interrupted)

let () =
  Alcotest.run "eta_crux post-commit effect observer"
    [
      ( "observer",
        [
          Alcotest.test_case "inventory and lifecycle" `Quick
            test_post_commit_effect_observer_inventory_and_lifecycle;
          Alcotest.test_case "discard before start" `Quick
            test_post_commit_effect_observer_discard_before_start;
          Alcotest.test_case "single attachment" `Quick
            test_post_commit_effect_observer_single_attachment;
          Alcotest.test_case "failure and interruption" `Quick
            test_post_commit_effect_observer_failure_and_interruption;
        ] );
    ]
