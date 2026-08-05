module Crux = Eta_crux

let run_ok runtime eff =
  Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let committed = function
  | Ok (Crux.Root.Committed { output; post_commit }) ->
      (output, post_commit)
  | _ -> Alcotest.fail "expected committed advancement"

let start runtime post_commit =
  Crux.Post_commit.start post_commit
  |> Eta.Effect.or_die (function
       | Crux.Post_commit.Already_started ->
           Failure "post-commit token started twice")
  |> run_ok runtime
  |> ignore

let counter_root () =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 machine

let stop runtime root =
  Crux.Root.request_stop root;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start runtime post_commit
  | _ -> Alcotest.fail "root did not stop"

let race_ingress_close_vs_send_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let send_winner_root = counter_root () in
  let (_, send_winner_endpoint), initial_post =
    committed (run_ok runtime (Crux.Root.advance send_winner_root))
  in
  start runtime initial_post;
  let admitted = Eta.Promise.create () in
  let send_first =
    let open Eta.Syntax in
    let* result = Eta.Effect.to_result
        (Crux.Endpoint.send send_winner_endpoint 1)
    in
    let+ _ = Eta.Promise.resolve admitted (Eta.Exit.Ok ()) in
    result
  in
  let stop_second =
    let open Eta.Syntax in
    let* () = Eta.Promise.await admitted in
    Eta.Effect.sync (fun () ->
        Crux.Root.request_stop send_winner_root)
  in
  let send_result, () =
    run_ok runtime (Eta.Effect.par send_first stop_second)
  in
  Alcotest.(check bool) "admission won first arbitration" true
    (send_result = Ok ());
  (match run_ok runtime (Crux.Root.advance send_winner_root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start runtime post_commit
  | _ -> Alcotest.fail "send-winner root did not stop");

  let close_winner_root = counter_root () in
  let (_, close_winner_endpoint), initial_post =
    committed (run_ok runtime (Crux.Root.advance close_winner_root))
  in
  start runtime initial_post;
  let closed = Eta.Promise.create () in
  let close_first =
    let open Eta.Syntax in
    let* () =
      Eta.Effect.sync (fun () ->
          Crux.Root.request_stop close_winner_root)
    in
    let+ _ = Eta.Promise.resolve closed (Eta.Exit.Ok ()) in
    ()
  in
  let send_second =
    let open Eta.Syntax in
    let* () = Eta.Promise.await closed in
    Eta.Effect.to_result
      (Crux.Endpoint.send close_winner_endpoint 1)
  in
  let (), close_result =
    run_ok runtime (Eta.Effect.par close_first send_second)
  in
  Alcotest.(check bool) "closure won first arbitration" true
    (close_result = Error Crux.Endpoint.Ingress_closed);
  (match run_ok runtime (Crux.Root.advance close_winner_root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start runtime post_commit
  | _ -> Alcotest.fail "close-winner root did not stop")

let race_batch_start_exactly_once () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  let _, post_commit = committed (run_ok runtime (Crux.Root.advance root)) in
  let attempt = Eta.Effect.to_result (Crux.Post_commit.start post_commit) in
  let left, right = run_ok runtime (Eta.Effect.par attempt attempt) in
  let admitted =
    List.fold_left
      (fun count -> function
        | Ok Crux.Post_commit.Admitted -> count + 1
        | Ok Crux.Post_commit.Stop_settled
        | Ok (Crux.Post_commit.Crash_settled _) ->
            Alcotest.fail "ordinary batch returned terminal settlement"
        | Error Crux.Post_commit.Already_started -> count)
      0 [ left; right ]
  in
  let rejected =
    List.fold_left
      (fun count -> function
        | Error Crux.Post_commit.Already_started -> count + 1
        | Ok _ -> count)
      0 [ left; right ]
  in
  Alcotest.(check int) "one start admitted" 1 admitted;
  Alcotest.(check int) "one start rejected" 1 rejected;
  stop runtime root

let race_failure_observation_order () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let first_entered = Eta.Promise.create () in
  let second_entered = Eta.Promise.create () in
  let first_finished = Eta.Promise.create () in
  let second_finished = Eta.Promise.create () in
  let release = Eta.Promise.create () in
  let failing_program entered finished message =
    let open Eta.Syntax in
    (let* _ = Eta.Promise.resolve entered (Eta.Exit.Ok ()) in
     let* () = Eta.Promise.await release in
     Eta.Effect.die_message message)
    |> Eta.Effect.on_exit (fun _ ->
           Eta.Promise.resolve finished (Eta.Exit.Ok ())
           |> Eta.Effect.map (fun _ -> ()))
  in
  let description =
    Crux.both
      (Crux.lifecycle
         (Crux.return
            (failing_program first_entered first_finished "first child")))
      (Crux.lifecycle
         (Crux.return
            (failing_program second_entered second_finished "second child")))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let _, initial_post = committed (run_ok runtime (Crux.Root.advance root)) in
  start runtime initial_post;
  let release_both =
    let open Eta.Syntax in
    let* () = Eta.Promise.await first_entered in
    let* () = Eta.Promise.await second_entered in
    let* _ = Eta.Promise.resolve release (Eta.Exit.Ok ()) in
    let* () = Eta.Promise.await first_finished in
    Eta.Promise.await second_finished
  in
  run_ok runtime release_both;
  let failure, crash_post =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { failure; post_commit }) ->
        (failure, post_commit)
    | _ -> Alcotest.fail "owned failures did not latch"
  in
  let secondary = List.hd failure.secondary in
  Alcotest.(check int64) "primary position" 0L
    (Crux.Failure.Observation_position.to_int64
       failure.primary.position);
  Alcotest.(check int64) "secondary position" 1L
    (Crux.Failure.Observation_position.to_int64 secondary.position);
  (match run_ok runtime (Crux.Post_commit.start crash_post) with
  | Crux.Post_commit.Crash_settled settlement ->
      Alcotest.(check int) "settlement preserves both records" 1
        (List.length settlement.failure.secondary)
  | _ -> Alcotest.fail "failure did not settle as crash")

let race_commit_vs_crash_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let make_root () =
    let before_apply = ref (fun () -> ()) in
    let machine =
      Crux.State_machine.create (Crux.return ()) ~default_model:0
        ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
          !before_apply ();
          (model + action, Eta.Effect.unit))
    in
    let crashing_endpoint =
      Crux.map machine ~f:(fun (_, endpoint) ->
          Crux.Endpoint.contramap endpoint ~f:(fun () ->
              raise (Failure "fatal export mapper")))
    in
    let unit_codec =
      Crux.Codec.make ~encode:(fun () -> Bytes.empty)
        ~decode:(fun _ -> Ok ())
    in
    let export =
      Crux.Exported_endpoint.create crashing_endpoint ~codec:unit_codec
    in
    let root =
      Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
        (Crux.both machine export)
    in
    let ((_, endpoint), crashing_export), initial_post =
      committed (run_ok runtime (Crux.Root.advance root))
    in
    start runtime initial_post;
    (root, endpoint, crashing_export, before_apply)
  in
  let trigger_crash export =
    match Crux.Exported_endpoint.try_invoke export () with
    | _ -> Alcotest.fail "fatal export mapper did not raise"
    | exception Failure _ -> ()
    | exception exn ->
        Alcotest.failf "unexpected export exception: %s"
          (Printexc.to_string exn)
  in

  let fatal_root, fatal_endpoint, fatal_export, before_apply =
    make_root ()
  in
  before_apply := (fun () -> trigger_crash fatal_export);
  run_ok runtime
    (Crux.Endpoint.send fatal_endpoint 5
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"));
  let fatal_post =
    match run_ok runtime (Crux.Root.advance fatal_root) with
    | Ok (Crux.Root.Failed { post_commit; _ }) -> post_commit
    | _ -> Alcotest.fail "fatal winner did not roll back advancement"
  in
  (match run_ok runtime (Crux.Post_commit.start fatal_post) with
  | Crux.Post_commit.Crash_settled _ -> ()
  | _ -> Alcotest.fail "fatal winner did not settle as crash");

  let commit_root, commit_endpoint, commit_export, _ =
    make_root ()
  in
  run_ok runtime
    (Crux.Endpoint.send commit_endpoint 7
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"));
  let committed_output, committed_post =
    committed (run_ok runtime (Crux.Root.advance commit_root))
  in
  let (committed_model, _), _ = committed_output in
  trigger_crash commit_export;
  Alcotest.(check int) "commit winner preserves output" 7 committed_model;
  (match run_ok runtime (Crux.Post_commit.start committed_post) with
  | Crux.Post_commit.Crash_settled _ -> ()
  | _ -> Alcotest.fail "commit winner batch did not convert to crash teardown")

let race_commit_atomicity () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let transition_effect_started = ref false in
  let provisional_lifecycle_started = ref false in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Eta.Effect.sync (fun () ->
              transition_effect_started := true) ))
  in
  let retained =
    Crux.State_machine.create (Crux.return ()) ~default_model:7
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let provisional =
    Crux.State_machine.create (Crux.return ()) ~default_model:99
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun keep_retained ->
        if keep_retained then Crux.map retained ~f:(fun value -> `Retained value)
        else
          Crux.both provisional
            (Crux.lifecycle
               (Crux.return
                  (Eta.Effect.sync (fun () ->
                       provisional_lifecycle_started := true))))
          |> Crux.map ~f:(fun _ ->
                 raise
                   (Failure
                      "provisional graph failed before atomic commit")))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both selector selected)
  in
  let initial, initial_post = committed (run_ok runtime (Crux.Root.advance root)) in
  start runtime initial_post;
  let (_, selector_endpoint), selected_output = initial in
  Alcotest.(check bool) "initial retained branch" true
    (match selected_output with `Retained _ -> true);
  run_ok runtime
    (Crux.Endpoint.send selector_endpoint false
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"));
  let failure, crash_post =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { failure; post_commit }) ->
        (failure, post_commit)
    | _ -> Alcotest.fail "provisional graph failure did not abort commit"
  in
  Alcotest.(check bool) "failure is a transition failure" true
    (failure.primary.origin = Crux.Failure.Transition);
  Alcotest.(check bool) "staged transition effect did not start" false
    !transition_effect_started;
  Alcotest.(check bool) "provisional lifecycle did not activate" false
    !provisional_lifecycle_started;
  (match run_ok runtime (Crux.Post_commit.start crash_post) with
  | Crux.Post_commit.Crash_settled _ -> ()
  | _ -> Alcotest.fail "atomic rollback did not settle as crash");
  Alcotest.(check bool) "teardown did not admit transition effect" false
    !transition_effect_started;
  Alcotest.(check bool) "teardown did not admit provisional lifecycle" false
    !provisional_lifecycle_started

let race_export_permit_vs_commit_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Bytes.of_string (string_of_int value))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let make_root () =
    let during_encode = ref (fun () -> ()) in
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
    let active =
      let target =
        Crux.map child ~f:(fun (_, endpoint) ->
            Crux.Endpoint.contramap endpoint ~f:(fun payload ->
                !during_encode ();
                payload))
      in
      Crux.Exported_endpoint.create target ~codec
      |> Crux.map ~f:Option.some
    in
    let selected =
      Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
          if enabled then active else Crux.return None)
    in
    let root =
      Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
        (Crux.both selector selected)
    in
    let initial, initial_post = committed (run_ok runtime (Crux.Root.advance root)) in
    start runtime initial_post;
    let ((_, selector_endpoint), export) = initial in
    ( root,
      selector_endpoint,
      Option.get export,
      during_encode )
  in

  let invoke_root, selector_endpoint, export, during_encode =
    make_root ()
  in
  run_ok runtime
    (Crux.Endpoint.send selector_endpoint false
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"));
  let removal_post = ref None in
  during_encode :=
    (fun () ->
      match run_ok runtime (Crux.Root.advance invoke_root) with
      | Ok (Crux.Root.Committed { post_commit; _ }) ->
          removal_post := Some post_commit
      | _ -> Alcotest.fail "structural commit did not win encode barrier");
  let invocation_result =
    Crux.Exported_endpoint.try_invoke export 3
  in
  during_encode := (fun () -> ());
  Alcotest.(check bool) "invocation winner pins old binding" true
    (invocation_result = Ok (Ok (Ok ())));
  start runtime (Option.get !removal_post);
  (match run_ok runtime (Crux.Root.advance invoke_root) with
  | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> ()
  | _ -> Alcotest.fail "pinned old binding did not retain old incarnation");
  stop runtime invoke_root;

  let commit_root, selector_endpoint, export, _ = make_root () in
  run_ok runtime
    (Crux.Endpoint.send selector_endpoint false
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed"));
  let _, removal_post = committed (run_ok runtime (Crux.Root.advance commit_root)) in
  start runtime removal_post;
  Alcotest.(check bool) "commit winner revokes export" true
    (Crux.Exported_endpoint.try_invoke export 3
    = Error Crux.Exported_endpoint.Revoked);
  stop runtime commit_root

let request_race_fixture runtime =
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Bytes.of_string (string_of_int value))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let operation =
    Crux.Host_operation.define ~name:"test.request-race"
      ~request:codec ~response:codec
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack operation ]
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  let driver = Crux.Driver.create binding root in
  let initial =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "request-race driver did not start"
  in
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.delivered initial));
  let requester =
    Crux.Driver.Binding.requester binding operation
  in
  (root, driver, operation, requester)

let rec await_driver_request driver =
  let open Eta.Syntax in
  let* event = Crux.Driver.poll driver in
  match event with
  | Some (Crux.Driver.Request request) -> Eta.Effect.pure request
  | Some _ | None ->
      let* () = Eta.Effect.yield in
      await_driver_request driver

let rec await_cancellation cancellation =
  match !cancellation with
  | Some reason -> Eta.Effect.pure reason
  | None ->
      let open Eta.Syntax in
      let* () = Eta.Effect.yield in
      await_cancellation cancellation

let race_cancel_vs_dispatch_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_case ~accept_first =
    let root, driver, operation, requester =
      request_race_fixture runtime
    in
    let cancellation_signal = Eta.Promise.create () in
    let cancellation = ref None in
    let request =
      Eta.Effect.race
        [
          (Crux.Requester.request requester 1
          |> Eta.Effect.or_die (function
               | Crux.Requester.Ingress_closed ->
                   Failure "request ingress closed"
               | Crux.Requester.Dispatch_failed ->
                   Failure "request dispatch failed"
               | Crux.Requester.Closed _ ->
                   Failure "request closed")
          |> Eta.Effect.map (fun response -> `Response response));
          (Eta.Promise.await cancellation_signal
          |> Eta.Effect.map (fun () -> `Cancelled));
        ]
    in
    let host =
      let open Eta.Syntax in
      let* event = await_driver_request driver in
      let resolver = ref None in
      let* _ =
        Crux.Request.Driver_event.handle event operation
          ~f:(fun _ ~resolve ~on_cancel ->
            resolver := Some resolve;
            on_cancel (fun reason -> cancellation := Some reason);
            Eta.Effect.unit)
      in
      let resolve = Option.get !resolver in
      if accept_first then
        let* accepted = Crux.Request.Driver_event.accepted event in
        let* _ =
          Eta.Promise.resolve cancellation_signal (Eta.Exit.Ok ())
        in
        let* reason = await_cancellation cancellation in
        let+ resolved = resolve 2 in
        (accepted, reason, resolved)
      else
        let* _ =
          Eta.Promise.resolve cancellation_signal (Eta.Exit.Ok ())
        in
        let* reason = await_cancellation cancellation in
        let* accepted = Crux.Request.Driver_event.accepted event in
        let+ resolved = resolve 2 in
        (accepted, reason, resolved)
    in
    let request_outcome, host_outcome =
      run_ok runtime (Eta.Effect.par request host)
    in
    stop runtime root;
    (request_outcome, host_outcome)
  in
  let cancelled, (acceptance_lost, reason, resolution_lost) =
    run_case ~accept_first:false
  in
  Alcotest.(check bool) "cancellation completed request fiber" true
    (cancelled = `Cancelled);
  Alcotest.(check bool) "cancellation won before dispatch" true
    (acceptance_lost
    = Error Crux.Request.Driver_event.Already_completed);
  Alcotest.(check bool) "initiator reason delivered" true
    (reason = Crux.Request.Initiator_cancelled);
  Alcotest.(check bool) "resolution lost cancellation race" true
    (resolution_lost = Error Crux.Request.Not_pending);

  let cancelled, (acceptance_won, reason, resolution_lost) =
    run_case ~accept_first:true
  in
  Alcotest.(check bool) "accepted request can still cancel" true
    (cancelled = `Cancelled);
  Alcotest.(check bool) "dispatch won before cancellation" true
    (acceptance_won = Ok ());
  Alcotest.(check bool) "accepted cancellation reason" true
    (reason = Crux.Request.Initiator_cancelled);
  Alcotest.(check bool) "cancelled request cannot resolve" true
    (resolution_lost = Error Crux.Request.Not_pending);

  let root, driver, operation, requester =
    request_race_fixture runtime
  in
  let cancellation_signal = Eta.Promise.create () in
  let request_settled = Eta.Promise.create () in
  let request =
    Eta.Effect.race
      [
        (Crux.Requester.request requester 1
        |> Eta.Effect.to_result
        |> Eta.Effect.map (fun _ -> `Response));
        (Eta.Promise.await cancellation_signal
        |> Eta.Effect.map (fun () -> `Cancelled));
      ]
    |> Eta.Effect.on_exit (fun exit ->
           Eta.Promise.resolve request_settled exit
           |> Eta.Effect.map (fun _ -> ()))
  in
  let late_registration =
    let open Eta.Syntax in
    let* event = await_driver_request driver in
    let* _ =
      Eta.Promise.resolve cancellation_signal (Eta.Exit.Ok ())
    in
    let* _ = Eta.Promise.await request_settled in
    let cancellation = ref None in
    let* _ =
      Crux.Request.Driver_event.handle event operation
        ~f:(fun _ ~resolve:_ ~on_cancel ->
          on_cancel (fun reason ->
              cancellation := Some reason);
          Eta.Effect.unit)
    in
    let+ accepted = Crux.Request.Driver_event.accepted event in
    (accepted, !cancellation)
  in
  let request_outcome, (accepted, cancellation) =
    run_ok runtime (Eta.Effect.par request late_registration)
  in
  stop runtime root;
  Alcotest.(check bool) "late cancellation won" true
    (request_outcome = `Cancelled);
  Alcotest.(check bool) "late dispatch completion rejected" true
    (accepted
    = Error Crux.Request.Driver_event.Already_completed);
  Alcotest.(check bool) "late handler receives exact reason" true
    (cancellation = Some Crux.Request.Initiator_cancelled)

let race_resolve_vs_cancel_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_case ~resolve_first =
    let root, driver, operation, requester =
      request_race_fixture runtime
    in
    let cancellation_signal = Eta.Promise.create () in
    let cancellation = ref None in
    let request =
      Eta.Effect.race
        [
          (Crux.Requester.request requester 1
          |> Eta.Effect.to_result
          |> Eta.Effect.map (fun result -> `Request result));
          (Eta.Promise.await cancellation_signal
          |> Eta.Effect.map (fun () -> `Cancelled));
        ]
    in
    let host =
      let open Eta.Syntax in
      let* event = await_driver_request driver in
      let resolver = ref None in
      let* _ =
        Crux.Request.Driver_event.handle event operation
          ~f:(fun _ ~resolve ~on_cancel ->
            resolver := Some resolve;
            on_cancel (fun reason -> cancellation := Some reason);
            Eta.Effect.unit)
      in
      let* _ = Crux.Request.Driver_event.accepted event in
      let resolve = Option.get !resolver in
      if resolve_first then
        let* first = resolve 2 in
        let* _ =
          Eta.Promise.resolve cancellation_signal (Eta.Exit.Ok ())
        in
        let* () = Eta.Effect.yield in
        let+ second = resolve 3 in
        (first, second, !cancellation)
      else
        let* _ =
          Eta.Promise.resolve cancellation_signal (Eta.Exit.Ok ())
        in
        let* reason = await_cancellation cancellation in
        let+ resolution = resolve 2 in
        (resolution, resolution, Some reason)
    in
    let request_outcome, host_outcome =
      run_ok runtime (Eta.Effect.par request host)
    in
    stop runtime root;
    (request_outcome, host_outcome)
  in
  let _, (first, second, cancellation) =
    run_case ~resolve_first:true
  in
  Alcotest.(check bool) "resolution won" true (first = Ok ());
  Alcotest.(check bool) "second resolution rejected" true
    (second = Error Crux.Request.Not_pending);
  Alcotest.(check bool) "resolution suppressed cancellation" true
    (Option.is_none cancellation);
  let cancelled, (resolution, _, cancellation) =
    run_case ~resolve_first:false
  in
  Alcotest.(check bool) "cancellation branch completed" true
    (cancelled = `Cancelled);
  Alcotest.(check bool) "resolution lost" true
    (resolution = Error Crux.Request.Not_pending);
  Alcotest.(check bool) "cancellation notified once" true
    (cancellation = Some Crux.Request.Initiator_cancelled)

let race_terminal_vs_delivery () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let stop_work_started = ref false in
  let stop_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both (Crux.return 7)
         (Crux.lifecycle
            (Crux.return
               (Eta.Effect.sync (fun () ->
                    stop_work_started := true)))))
  in
  let stop_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) stop_root
  in
  let stop_delivery =
    match run_ok runtime (Crux.Driver.poll stop_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "stop case did not produce delivery"
  in
  Crux.Driver.request_stop stop_driver;
  Alcotest.(check bool) "stop preserves pending delivery" true
    (run_ok runtime (Crux.Driver.poll stop_driver) = None);
  Alcotest.(check int) "committed stop output preserved" 7
    (fst (Crux.Driver.Delivery.output stop_delivery));
  Alcotest.(check bool) "stop answer accepted" true
    (run_ok runtime
       (Crux.Driver.Delivery.delivered stop_delivery)
    = Ok ());
  Alcotest.(check bool) "terminal work replaced ordinary work" false
    !stop_work_started;
  (match run_ok runtime (Crux.Driver.poll stop_driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "stop case did not close after delivery answer");

  let crash_work_started = ref false in
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Bytes.of_string (string_of_int value))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let target =
    Crux.map machine ~f:(fun (_, endpoint) ->
        Crux.Endpoint.contramap endpoint ~f:(fun (_ : int) ->
            raise (Failure "pending-delivery crash")))
  in
  let description =
    Crux.both machine
      (Crux.both
         (Crux.Exported_endpoint.create target ~codec)
         (Crux.lifecycle
            (Crux.return
               (Eta.Effect.sync (fun () ->
                    crash_work_started := true)))))
  in
  let crash_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let crash_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) crash_root
  in
  let crash_delivery =
    match run_ok runtime (Crux.Driver.poll crash_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "crash case did not produce delivery"
  in
  let (committed_model, _), (export, _) =
    Crux.Driver.Delivery.output crash_delivery
  in
  (match Crux.Exported_endpoint.try_invoke export 1 with
  | _ -> Alcotest.fail "export crash callback did not raise"
  | exception Failure _ -> ()
  | exception exn ->
      Alcotest.failf "unexpected export callback exception: %s"
        (Printexc.to_string exn));
  Alcotest.(check bool) "crash preserves pending delivery" true
    (run_ok runtime (Crux.Driver.poll crash_driver) = None);
  Alcotest.(check int) "committed crash output preserved" 0
    committed_model;
  Alcotest.(check bool) "crash answer accepted" true
    (run_ok runtime
       (Crux.Driver.Delivery.delivered crash_delivery)
    = Ok ());
  Alcotest.(check bool) "crash suppressed ordinary work" false
    !crash_work_started;
  (match run_ok runtime (Crux.Driver.poll crash_driver) with
  | Some (Crux.Driver.Crash_detected failure) ->
      Alcotest.(check bool) "pending crash retained origin" true
        (failure.primary.origin = Crux.Failure.Export_dispatch)
  | _ -> Alcotest.fail "crash was not detected after delivery answer");
  (match run_ok runtime (Crux.Driver.poll crash_driver) with
  | Some
      (Crux.Driver.Closed
        (Crux.Driver.Crashed { teardown_settled = true; _ })) ->
      ()
  | _ -> Alcotest.fail "crash did not settle after delivery answer")

let race_session_replacement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Bytes.of_string (string_of_int value))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:73
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let export =
    Crux.Exported_endpoint.create
      (Crux.map machine ~f:snd) ~codec
  in
  let output_codec =
    Crux.Codec.make
      ~encode:(fun ((model, _endpoint), export) ->
        let handle =
          Crux.Exported_endpoint.remote_handle export
        in
        let bytes = Bytes.create (4 + Bytes.length handle) in
        Bytes.set_int32_be bytes 0 (Int32.of_int model);
        Bytes.blit handle 0 bytes 4 (Bytes.length handle);
        bytes)
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "replacement output is encode-only";
          })
  in
  let old_candidate, old_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~output:output_codec
      ~operations:[]
      ~session:old_candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both machine export)
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let initial_sequence, initial_handle =
    match
      run_ok runtime
        (Crux.Serialized_session.poll_outgoing old_peer)
    with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Output_deliver
              { seq; output; _ }) ->
            Alcotest.(check int32) "initial replacement model" 73l
              (Bytes.get_int32_be output 0);
            ( seq,
              Bytes.sub output 4
                (Bytes.length output - 4) )
        | Ok _ | Error _ ->
            Alcotest.fail "initial serialized output malformed")
    | None -> Alcotest.fail "initial serialized output missing"
  in
  let initial_reply =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = initial_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok runtime
       (Crux.Serialized_session.receive old_peer initial_reply));
  ignore (run_ok runtime (Crux.Driver.poll driver));

  let new_candidate, new_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let replacement =
    Crux.Serialized_session.replace admin new_candidate
    |> Eta.Effect.to_result
  in
  let remote =
    let open Eta.Syntax in
    let* bytes =
      Crux.Serialized_session.await_outgoing new_peer
      |> Eta.Effect.or_die (function
           | Crux.Serialized_session.Session_closed ->
               Failure "replacement session closed"
           | Crux.Serialized_session.Protocol_error _ ->
               Failure "replacement protocol error")
    in
    let sequence, output =
      match Eta_crux_json.Format.decode bytes with
      | Ok
          (Crux.Wire.Frame.Output_deliver
            {
              seq;
              reason = `Session_replacement;
              output;
            }) ->
          ( seq,
            ( Int32.to_int (Bytes.get_int32_be output 0),
              Bytes.sub output 4
                (Bytes.length output - 4) ) )
      | Ok _ | Error _ ->
          Alcotest.fail "replacement output malformed"
    in
    let* old_closed =
      Crux.Serialized_session.receive old_peer
        (Bytes.of_string "{}")
    in
    let reply =
      Crux.Wire.Frame.Output_result
        { seq = 0l; reply_to = sequence; result = `Accepted }
      |> Eta_crux_json.Format.encode
    in
    let* received =
      Crux.Serialized_session.receive new_peer reply
    in
    let* _ = Crux.Driver.poll driver in
    Eta.Effect.pure (sequence, output, old_closed, received)
  in
  let replacement_result,
      (sequence, (output, replacement_handle), old_closed, received) =
    run_ok runtime (Eta.Effect.par replacement remote)
  in
  Alcotest.(check bool) "replacement completed after delivery" true
    (replacement_result = Ok Crux.Serialized_session.Replaced);
  Alcotest.(check int32) "new outgoing sequence starts at zero" 0l
    sequence;
  Alcotest.(check int) "current output redelivered" 73 output;
  Alcotest.(check bool) "replacement allocated fresh handle" false
    (Bytes.equal initial_handle replacement_handle);
  Alcotest.(check bool) "old session closed before installation" true
    (old_closed = Error Crux.Serialized_session.Session_closed);
  Alcotest.(check bool) "replacement acknowledgment accepted" true
    (received = Ok ());
  let invoke handle sequence =
    Crux.Wire.Frame.Endpoint_invoke
      {
        seq = sequence;
        handle;
        payload = Crux.Codec.encode codec 1;
      }
    |> Eta_crux_json.Format.encode
    |> Crux.Serialized_session.receive new_peer
    |> run_ok runtime
    |> ignore;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    match
      run_ok runtime
        (Crux.Serialized_session.poll_outgoing new_peer)
    with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Endpoint_result
              { result; _ }) ->
            result
        | Ok _ | Error _ ->
            Alcotest.fail "replacement invocation result malformed")
    | None ->
        Alcotest.fail "replacement invocation result missing"
  in
  Alcotest.(check bool) "old-session handle is stale" true
    (invoke initial_handle 1l = `Stale_handle);
  Alcotest.(check bool) "fresh registry is complete" true
    (invoke replacement_handle 2l = `Accepted);
  Crux.Driver.request_stop driver;
  (match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "replacement driver did not stop")

let () =
  Alcotest.run "eta_crux races"
    [
      ( "races",
        [
          Alcotest.test_case "ingress close vs send both winners" `Quick
            race_ingress_close_vs_send_both_winners;
          Alcotest.test_case "batch start exactly once" `Quick
            race_batch_start_exactly_once;
          Alcotest.test_case "failure observation order" `Quick
            race_failure_observation_order;
          Alcotest.test_case "commit vs crash both winners" `Quick
            race_commit_vs_crash_both_winners;
          Alcotest.test_case "commit atomicity" `Quick
            race_commit_atomicity;
          Alcotest.test_case "export permit vs commit both winners" `Quick
            race_export_permit_vs_commit_both_winners;
          Alcotest.test_case "cancel vs dispatch both winners" `Quick
            race_cancel_vs_dispatch_both_winners;
          Alcotest.test_case "resolve vs cancel both winners" `Quick
            race_resolve_vs_cancel_both_winners;
          Alcotest.test_case "terminal vs delivery" `Quick
            race_terminal_vs_delivery;
          Alcotest.test_case "session replacement" `Quick
            race_session_replacement;
        ] );
    ]
