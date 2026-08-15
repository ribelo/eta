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

let run_ok runtime eff =
  Eta.Runtime.run runtime eff |> Eta_test.Expect.expect_ok

let committed = function
  | Ok (Crux.Root.Committed { commit; post_commit }) ->
      let output = output_of_commit commit in
      (output, post_commit)
  | _ -> Alcotest.fail "expected committed advancement"

let start runtime post_commit =
  Crux.Post_commit.start post_commit
  |> Eta.Effect.or_die (function
       | Crux.Post_commit.Already_started ->
           Failure "post-commit token started twice")
  |> run_ok runtime
  |> ignore

let start_result runtime post_commit =
  Crux.Post_commit.start post_commit
  |> Eta.Effect.or_die (function
       | Crux.Post_commit.Already_started ->
           Failure "post-commit token started twice")
  |> run_ok runtime

let counter_root () =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1 machine

let stop runtime root =
  Crux.Root.request_stop root;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start runtime post_commit
  | _ -> Alcotest.fail "root did not stop"

let stop_driver runtime driver =
  Crux.Driver.request_stop driver;
  match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "driver-owned root did not stop"

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
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
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
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1 description
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
  (match start_result runtime crash_post with
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
          (model + action, None))
    in
    let crashing_endpoint =
      Crux.map machine ~f:(fun (_, endpoint) ->
          Crux.Endpoint.contramap endpoint ~f:(fun () ->
              raise (Failure "fatal export mapper")))
    in
    let unit_codec =
      Crux.Codec.make ~encode:(fun () -> Ok Bytes.empty)
        ~decode:(fun _ -> Ok ())
    in
    let export =
      Crux.Exported_endpoint.create crashing_endpoint ~codec:unit_codec
    in
    let root =
      Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
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
  (match start_result runtime fatal_post with
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
  (match start_result runtime committed_post with
  | Crux.Post_commit.Crash_settled _ -> ()
  | _ -> Alcotest.fail "commit winner batch did not convert to crash teardown");
  Eta.Runtime.drain runtime

let race_commit_atomicity () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let transition_effect_started = ref false in
  let provisional_lifecycle_started = ref false in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some
            (Eta.Effect.sync (fun () ->
                 transition_effect_started := true)) ))
  in
  let retained =
    Crux.State_machine.create (Crux.return ()) ~default_model:7
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let provisional =
    Crux.State_machine.create (Crux.return ()) ~default_model:99
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
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
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
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
  (match start_result runtime crash_post with
  | Crux.Post_commit.Crash_settled _ -> ()
  | _ -> Alcotest.fail "atomic rollback did not settle as crash");
  Alcotest.(check bool) "teardown did not admit transition effect" false
    !transition_effect_started;
  Alcotest.(check bool) "teardown did not admit provisional lifecycle" false
    !provisional_lifecycle_started;
  Eta.Runtime.drain runtime

let race_export_permit_vs_commit_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
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
          (action, None))
    in
    let child =
      Crux.State_machine.create (Crux.return ()) ~default_model:0
        ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
          (model + action, None))
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
      Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
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
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
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
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
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
               | Crux.Requester.Encode_failed _ ->
                   Failure "request encode failed"
               | Crux.Requester.Decode_failed _ ->
                   Failure "request decode failed"
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
    ignore root;
    stop_driver runtime driver;
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
    let* handled =
      Crux.Request.Driver_event.handle event operation
        ~f:(fun _ ~resolve:_ ~on_cancel ->
          on_cancel (fun reason ->
              cancellation := Some reason);
          Eta.Effect.unit)
    in
    let+ accepted = Crux.Request.Driver_event.accepted event in
    (handled, accepted, !cancellation)
  in
  let request_outcome, (handled, accepted, cancellation) =
    run_ok runtime (Eta.Effect.par request late_registration)
  in
  ignore root;
  stop_driver runtime driver;
  Alcotest.(check bool) "late cancellation won" true
    (request_outcome = `Cancelled);
  Alcotest.(check bool) "late dispatch completion rejected" true
    (accepted
    = Error Crux.Request.Driver_event.Already_completed);
  Alcotest.(check bool) "late handler observes exact closure" true
    (handled
    = Crux.Request.Driver_event.Closed
        Crux.Request.Initiator_cancelled);
  Alcotest.(check bool) "late closed handler did not run" true
    (cancellation = None)

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
    ignore root;
    stop_driver runtime driver;
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
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
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
    (fst (output_of_delivery stop_delivery));
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
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
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
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1 description
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
    output_of_delivery crash_delivery
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
  | _ -> Alcotest.fail "crash did not settle after delivery answer");
  Eta.Runtime.drain runtime

let race_session_replacement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:73
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
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
        Ok bytes)
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "replacement output is encode-only";
          })
  in
  let projection =
    Typed_projection.create ~name:"session-replacement"
      ~codec:output_codec ~value_equal:( == )
      ~cutoff:Crux.Cutoff.never
  in
  let old_candidate, old_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized
      ~operations:[]
      ~session:old_candidate
  in
  let root =
    Typed_projection.root projection ~projection_capacity:1
      ~ingress_capacity:1 ~request_capacity:1
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
            (Crux.Wire.Frame.Projection_deliver
              { seq; content; _ }) ->
            let output = projection_content_value content in
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
    Crux.Wire.Frame.Projection_result
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
          (Crux.Wire.Frame.Projection_deliver
            {
              seq;
              reason = `Session_replacement;
              content;
            }) ->
          let output = projection_content_value content in
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
      Crux.Wire.Frame.Projection_result
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
        payload =
          (match Crux.Codec.encode codec 1 with
          | Ok payload -> payload
          | Error _ -> Alcotest.fail "codec encode failed");
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
  | _ -> Alcotest.fail "replacement driver did not stop");
  Eta.Runtime.drain runtime

let test_session_replacement_permit_wait () =
  race_session_replacement ()

let race_replacement_vs_commit_both_winners () =
  let run_case ~replacement_first =
    Eta_test.with_test_clock @@ fun _switch _clock runtime ->
    let endpoint = ref None in
    let codec =
      Crux.Codec.make
        ~encode:(fun value ->
          Ok (Bytes.of_string (string_of_int value)))
        ~decode:(fun bytes ->
          match int_of_string_opt (Bytes.to_string bytes) with
          | Some value -> Ok value
          | None ->
              Error { Crux.Codec.message = "invalid race value" })
    in
    let projection =
      Typed_projection.create ~name:"replacement-vs-commit"
        ~codec ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never
    in
    let machine =
      Crux.State_machine.create (Crux.return ()) ~default_model:0
        ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
          (action, None))
    in
    let description =
      Crux.map machine ~f:(fun (model, machine_endpoint) ->
          endpoint := Some machine_endpoint;
          model)
    in
    let old_candidate, old_peer =
      Crux.Serialized_session.candidate ~max_frame_bytes:2048
        ~format:(module Eta_crux_json.Format)
    in
    let binding, admin =
      Crux.Driver.Binding.serialized ~operations:[]
        ~session:old_candidate
    in
    let root =
      Typed_projection.root projection ~projection_capacity:1
        ~ingress_capacity:2 ~request_capacity:1 description
    in
    let driver = Crux.Driver.create binding root in
    let poll_frame peer =
      match
        run_ok runtime
          (Crux.Serialized_session.poll_outgoing peer)
      with
      | Some bytes -> (
          match Eta_crux_json.Format.decode bytes with
          | Ok frame -> frame
          | Error _ -> Alcotest.fail "race frame malformed")
      | None -> Alcotest.fail "race frame missing"
    in
    let receive peer frame =
      run_ok runtime
        (Crux.Serialized_session.receive peer
           (Eta_crux_json.Format.encode frame))
    in
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let initial_sequence =
      match poll_frame old_peer with
      | Crux.Wire.Frame.Projection_deliver { seq; _ } -> seq
      | _ -> Alcotest.fail "race initial projection missing"
    in
    ignore
      (receive old_peer
         (Crux.Wire.Frame.Projection_result
            {
              seq = 0l;
              reply_to = initial_sequence;
              result = `Accepted;
            }));
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let send_action value =
      ignore
        (run_ok runtime
           (Crux.Endpoint.send (Option.get !endpoint) value
           |> Eta.Effect.or_die (fun _ ->
                  Failure "race endpoint closed")))
    in
    let accept_advancement peer ~result_seq =
      ignore (run_ok runtime (Crux.Driver.poll driver));
      let sequence =
        match poll_frame peer with
        | Crux.Wire.Frame.Projection_deliver
            { seq; reason = `Advancement; _ } ->
            seq
        | _ -> Alcotest.fail "race advancement missing"
      in
      ignore
        (receive peer
           (Crux.Wire.Frame.Projection_result
              {
                seq = result_seq;
                reply_to = sequence;
                result = `Accepted;
              }));
      ignore (run_ok runtime (Crux.Driver.poll driver))
    in
    if not replacement_first then (
      send_action 1;
      accept_advancement old_peer ~result_seq:1l);
    let new_candidate, new_peer =
      Crux.Serialized_session.candidate ~max_frame_bytes:2048
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
        |> Eta.Effect.or_die (fun _ ->
               Failure "replacement race session closed")
      in
      let sequence, value =
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Projection_deliver
              {
                seq;
                reason = `Session_replacement;
                content;
              }) ->
            let value =
              projection_content_value content
              |> Bytes.to_string |> int_of_string
            in
            (seq, value)
        | _ ->
            Alcotest.fail "replacement race bootstrap malformed"
      in
      let* fenced =
        if replacement_first then
          let* () =
            Crux.Endpoint.send (Option.get !endpoint) 1
            |> Eta.Effect.or_die (fun _ ->
                   Failure "race endpoint closed")
          in
          Crux.Driver.poll driver
        else Eta.Effect.pure None
      in
      let* received =
        Crux.Serialized_session.receive new_peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Projection_result
                {
                  seq = 0l;
                  reply_to = sequence;
                  result = `Accepted;
                }))
      in
      let* _ = Crux.Driver.poll driver in
      Eta.Effect.pure (value, fenced, received)
    in
    let replacement_result, (bootstrap_value, fenced, received) =
      run_ok runtime (Eta.Effect.par replacement remote)
    in
    Alcotest.(check bool) "replacement race completed" true
      (replacement_result = Ok Crux.Serialized_session.Replaced);
    Alcotest.(check int) "winner selected complete bootstrap"
      (if replacement_first then 0 else 1)
      bootstrap_value;
    Alcotest.(check bool) "replacement result accepted" true
      (received = Ok ());
    if replacement_first then (
      Alcotest.(check bool) "replacement winner fenced commit" true
        (fenced = None);
      accept_advancement new_peer ~result_seq:1l);
    Crux.Driver.request_stop driver;
    (match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
    | _ -> Alcotest.fail "replacement race driver did not stop");
    Eta.Runtime.drain runtime
  in
  run_case ~replacement_first:true;
  run_case ~replacement_first:false

let race_test_clock_movement_both_winners () =
  let run_case ~winner ~loser ~expected_time =
    Eta_test.with_test_clock @@ fun switch _runtime_clock _runtime ->
    let clock = Eta_test.Test_clock.create () in
    Eio.Fiber.fork ~sw:switch (fun () ->
        Eta_test.Test_clock.sleep clock (Eta.Duration.ms 25));
    let rec wait_for_sleepers () =
      if Eta_test.Test_clock.sleeper_count clock = 1 then ()
      else (
        Eio.Fiber.yield ();
        wait_for_sleepers ())
    in
    wait_for_sleepers ();
    let claimed, resolve_claimed = Eio.Promise.create () in
    let release, resolve_release = Eio.Promise.create () in
    let winner_done, resolve_winner_done = Eio.Promise.create () in
    let previous_hook =
      Eta_test__Eta_test_clock_barrier.set_after_movement_claim
        (fun () ->
          Eio.Promise.resolve resolve_claimed ();
          Eio.Promise.await release)
    in
    Eio.Fiber.fork ~sw:switch (fun () ->
        winner clock;
        Eio.Promise.resolve resolve_winner_done ());
    Eio.Promise.await claimed;
    let loser_rejected =
      match loser clock with
      | () -> false
      | exception Invalid_argument message ->
          String.equal message
            "Eta_test.Test_clock: concurrent movement"
    in
    Eio.Promise.resolve resolve_release ();
    Eio.Promise.await winner_done;
    let (_ : unit -> unit) =
      Eta_test__Eta_test_clock_barrier.set_after_movement_claim
        previous_hook
    in
    Alcotest.(check bool) "losing movement was rejected" true
      loser_rejected;
    Alcotest.(check int) "only the winning movement changed time"
      expected_time (Eta_test.Test_clock.now_ms clock);
    Alcotest.(check int) "losing movement woke no future sleeper" 1
      (Eta_test.Test_clock.sleeper_count clock);
    Eta_test.Test_clock.advance_to clock 25
  in
  let winners =
    [
      ( (fun clock ->
          Eta_test.Test_clock.adjust clock (Eta.Duration.ms 10)),
        10 );
      ((fun clock -> Eta_test.Test_clock.set_time clock 15), 15);
      ((fun clock -> Eta_test.Test_clock.advance_to clock 20), 20);
    ]
  in
  let losers =
    [
      (fun clock ->
        Eta_test.Test_clock.adjust clock (Eta.Duration.ms 30));
      (fun clock -> Eta_test.Test_clock.set_time clock 30);
      (fun clock -> Eta_test.Test_clock.advance_to clock 30);
    ]
  in
  List.iter
    (fun (winner, expected_time) ->
      List.iter
        (fun loser ->
          run_case ~winner ~loser ~expected_time)
        losers)
    winners

let race_driver_attachment_both_winners () =
  Eta_test.with_test_clock @@ fun switch _clock _runtime ->
  let make_root value =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return value)
  in
  let attach binding root =
    try
      ignore (Crux.Driver.create binding root);
      `Won
    with Invalid_argument _ -> `Lost
  in
  let run_contenders left right =
    let entered, enter = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let blocked = Atomic.make false in
    let previous =
      Eta_crux__Crux_attachment_barrier.set_after_lock
        (fun () ->
          if Atomic.compare_and_set blocked false true then (
            Eio.Promise.resolve enter ();
            Eio.Promise.await release))
    in
    let left_result, resolve_left = Eio.Promise.create () in
    let right_started, resolve_right_started = Eio.Promise.create () in
    let right_result, resolve_right = Eio.Promise.create () in
    Eio.Fiber.fork ~sw:switch (fun () ->
        Eio.Promise.resolve resolve_left (left ()));
    Eio.Promise.await entered;
    Eio.Fiber.fork ~sw:switch (fun () ->
        Eio.Promise.resolve resolve_right_started ();
        Eio.Promise.resolve resolve_right (right ()));
    Eio.Promise.await right_started;
    Eio.Promise.resolve release_resolver ();
    let results =
      (Eio.Promise.await left_result, Eio.Promise.await right_result)
    in
    let (_ : unit -> unit) =
      Eta_crux__Crux_attachment_barrier.set_after_lock previous
    in
    results
  in
  let shared_root = make_root 1 in
  let left_binding = Crux.Driver.Binding.identity [] in
  let right_binding = Crux.Driver.Binding.identity [] in
  let left, right =
    run_contenders
      (fun () -> attach left_binding shared_root)
      (fun () -> attach right_binding shared_root)
  in
  Alcotest.(check int) "one shared-root attachment won" 1
    (List.length
       (List.filter (( = ) `Won) [ left; right ]));
  let losing_binding =
    match left, right with
    | `Lost, `Won -> left_binding
    | `Won, `Lost -> right_binding
    | _ -> Alcotest.fail "shared-root arbitration was not exclusive"
  in
  Alcotest.(check bool) "losing binding remained unused" true
    (attach losing_binding (make_root 2) = `Won);

  let shared_binding = Crux.Driver.Binding.identity [] in
  let left_root = make_root 3 in
  let right_root = make_root 4 in
  let left, right =
    run_contenders
      (fun () -> attach shared_binding left_root)
      (fun () -> attach shared_binding right_root)
  in
  Alcotest.(check int) "one shared-binding attachment won" 1
    (List.length
       (List.filter (( = ) `Won) [ left; right ]));
  let losing_root =
    match left, right with
    | `Lost, `Won -> left_root
    | `Won, `Lost -> right_root
    | _ -> Alcotest.fail "shared-binding arbitration was not exclusive"
  in
  Alcotest.(check bool) "losing root remained unstarted" true
    (attach (Crux.Driver.Binding.identity []) losing_root = `Won)

let race_handle_shared_clock_movement_both_winners () =
  Eta_test.with_test_clock @@ fun switch _runtime_clock runtime ->
  let shell =
    {
      Eta_crux_test.Test_shell.pp_error =
        (fun _ (error : Crux.never) -> match error with _ -> .);
      deliver = (fun _ -> Eta.Effect.unit);
      request_event = (fun _ -> Eta.Effect.unit);
      crash_detected = (fun _ -> Eta.Effect.unit);
    }
  in
  let make_handle clock =
    let root =
      Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
        (Crux.return ())
    in
    Eta_crux_test.Handle.create ~clock
      ~incoming:Eta_crux_test.Incoming.none ~shell root
  in
  let move handle kind ~winner =
    match kind with
    | `By ->
        Eta_crux_test.Handle.advance_time_by handle
          (Eta.Duration.ms (if winner then 10 else 30))
    | `To ->
        Eta_crux_test.Handle.advance_time_to handle
          (if winner then 20 else 30)
  in
  let expected_time = function `By -> 10 | `To -> 20 in
  let expect_initial_frame handle =
    match run_ok runtime (Eta_crux_test.Handle.frame handle) with
    | Ok
        {
          Eta_crux_test.Handle.outcome =
            Eta_crux_test.Handle.Committed snapshot;
          _;
        }
      when Projection.snapshot_value snapshot = Some () ->
        ()
    | _ -> Alcotest.fail "handle did not advance after clock movement"
  in
  let run_case ~winner_on_left ~winner_kind ~loser_kind =
    let clock = Eta_test.Test_clock.create () in
    let left = make_handle clock in
    let right = make_handle clock in
    let winner = if winner_on_left then left else right in
    let loser = if winner_on_left then right else left in
    let winner_entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let winner_done, done_resolver = Eio.Promise.create () in
    let previous =
      Eta_test__Eta_test_clock_barrier.set_after_movement_claim
        (fun () ->
          Eio.Promise.resolve entered_resolver ();
          Eio.Promise.await release)
    in
    Eio.Fiber.fork ~sw:switch (fun () ->
        move winner winner_kind ~winner:true;
        Eio.Promise.resolve done_resolver ());
    Eio.Promise.await winner_entered;
    let loser_rejected =
      try
        move loser loser_kind ~winner:false;
        false
      with
      | Invalid_argument message ->
          String.equal message
            "Eta_test.Test_clock: concurrent movement"
    in
    Eio.Promise.resolve release_resolver ();
    Eio.Promise.await winner_done;
    let (_ : unit -> unit) =
      Eta_test__Eta_test_clock_barrier.set_after_movement_claim
        previous
    in
    Alcotest.(check bool) "losing handle movement rejected" true
      loser_rejected;
    Alcotest.(check int) "one shared-clock movement won"
      (expected_time winner_kind)
      (Eta_test.Test_clock.now_ms clock);
    Alcotest.(check (option unit)) "movement did not advance left root"
      None (handle_latest_committed_snapshot left);
    Alcotest.(check (option unit)) "movement did not advance right root"
      None (handle_latest_committed_snapshot right);
    expect_initial_frame left;
    expect_initial_frame right;
    ignore (run_ok runtime (Eta_crux_test.Handle.stop left));
    ignore (run_ok runtime (Eta_crux_test.Handle.stop right))
  in
  List.iter
    (fun winner_on_left ->
      List.iter
        (fun winner_kind ->
          List.iter
            (fun loser_kind ->
              run_case ~winner_on_left ~winner_kind
                ~loser_kind)
            [ `By; `To ])
        [ `By; `To ])
    [ true; false ]

let race_pull_vs_commit_both_winners () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let run_case ~block_before ~expected =
    let machine =
      Crux.State_machine.create (Crux.return ())
        ~default_model:0
        ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
          (model + action, None))
    in
    let root =
      Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
        machine
    in
    let driver =
      Crux.Driver.create (Crux.Driver.Binding.identity []) root
    in
    let initial =
      match run_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Deliver delivery) -> delivery
      | Some _ | None -> Alcotest.fail "missing initial delivery"
    in
    ignore
      (run_ok runtime
         (Crux.Driver.Delivery.delivered initial));
    let _, endpoint = output_of_delivery initial in
    ignore
      (run_ok runtime
         (Crux.Endpoint.send endpoint 1
         |> Eta.Effect.or_die (fun _ ->
                Invalid_argument "ingress closed")));
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let hook () =
      Eio.Promise.resolve entered_resolver ();
      Eio.Promise.await release
    in
    let previous_before =
      Eta_crux__Crux_pull_barrier.set_before_publication
        (if block_before then hook else fun () -> ())
    in
    let previous_after =
      Eta_crux__Crux_pull_barrier.set_after_publication
        (if block_before then (fun () -> ()) else hook)
    in
    let polling =
      Eta_test.Async.fork_run switch runtime
        (Crux.Driver.poll driver)
    in
    Eio.Promise.await entered;
    let pulled =
      latest_committed_snapshot driver
      |> Option.map fst
    in
    Eio.Promise.resolve release_resolver ();
    let event =
      Eta_test.Async.await polling |> Eta_test.Expect.expect_ok
    in
    let (_ : unit -> unit) =
      Eta_crux__Crux_pull_barrier.set_before_publication
        previous_before
    in
    let (_ : unit -> unit) =
      Eta_crux__Crux_pull_barrier.set_after_publication
        previous_after
    in
    let delivery =
      match event with
      | Some (Crux.Driver.Deliver delivery) -> delivery
      | Some _ | None -> Alcotest.fail "missing raced delivery"
    in
    Alcotest.(check (option int)) "atomic pull result"
      (Some expected) pulled;
    Alcotest.(check int) "complete delivered output" 1
      (fst (output_of_delivery delivery));
    ignore
      (run_ok runtime
         (Crux.Driver.Delivery.delivered delivery));
    Eta.Runtime.drain runtime
  in
  run_case ~block_before:true ~expected:0;
  run_case ~block_before:false ~expected:1

let race_post_commit_effect_observer_read_both_winners () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let module Observer =
    Eta_crux_test.Post_commit_effect_observer
  in
  let run_operation observer = function
    | `Poll -> `Poll (Observer.poll observer)
    | `Drain -> `Drain (Observer.drain observer)
    | `Expect_empty ->
        Observer.expect_empty observer;
        `Expect_empty
  in
  let run_case ~nonempty ~winner ~loser =
    let observer = Observer.create () in
    if nonempty then (
      let root =
        Projection.root ~projection_capacity:1
          ~post_commit_effect_observer:(Observer.attachment observer)
          ~ingress_capacity:1 ~request_capacity:1
          (Crux.return ())
      in
      ignore (run_ok runtime (Crux.Root.advance root)));
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let done_, done_resolver = Eio.Promise.create () in
    let previous =
      Eta_crux_test__Crux_post_commit_observer_barrier
      .set_after_consumer_claim
        (fun () ->
          Eio.Promise.resolve entered_resolver ();
          Eio.Promise.await release)
    in
    Eio.Fiber.fork ~sw:switch (fun () ->
        let result =
          try Ok (run_operation observer winner)
          with exception_ -> Error exception_
        in
        Eio.Promise.resolve done_resolver result);
    Eio.Promise.await entered;
    let loser_rejected =
      try
        ignore (run_operation observer loser);
        false
      with Invalid_argument _ -> true
    in
    Eio.Promise.resolve release_resolver ();
    let observed = Eio.Promise.await done_ in
    let (_ : unit -> unit) =
      Eta_crux_test__Crux_post_commit_observer_barrier
      .set_after_consumer_claim previous
    in
    Alcotest.(check bool) "losing consumer rejected" true
      loser_rejected;
    (match winner, nonempty, observed with
    | `Poll, true, Ok (`Poll (Some (Observer.Staged _)))
    | `Poll, false, Ok (`Poll None)
    | `Drain, true, Ok (`Drain [ Observer.Staged _ ])
    | `Drain, false, Ok (`Drain [])
    | `Expect_empty, false, Ok `Expect_empty
    | `Expect_empty, true, Error _ ->
        ()
    | _ -> Alcotest.fail "observer winner returned the wrong result");
    let remaining = Observer.drain observer in
    Alcotest.(check int) "winner preserved the exact remaining queue"
      (if nonempty && winner = `Expect_empty then 1 else 0)
      (List.length remaining);
    Observer.expect_empty observer
  in
  List.iter
    (fun nonempty ->
      List.iter
        (fun winner ->
          List.iter
            (fun loser ->
              run_case ~nonempty ~winner ~loser)
            [ `Poll; `Drain; `Expect_empty ])
        [ `Poll; `Drain; `Expect_empty ])
    [ false; true ]

let race_reset_vs_disposal_both_winners () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let make_fixture () =
    let resets = ref 0 in
    let selector =
      Crux.State_machine.create (Crux.return ())
        ~default_model:true
        ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
          (action, None))
    in
    let description =
      Crux.bind selector
        ~f:(fun (active, selector_endpoint) ->
          if not active then
            Crux.return (selector_endpoint, None)
          else
            Crux.Reset.scope (Crux.return ())
              ~f:(fun ~reset ~input ->
                let machine =
                  Crux.State_machine.create input
                    ~default_model:0
                    ~reset:(fun ~self:_ ~input:() ~model ->
                      incr resets;
                      (model, None))
                    ~apply_action:(fun ~self:_ ~input:()
                                      ~model ~action:_ ->
                      (model, None))
                in
                Crux.map (Crux.both reset machine)
                  ~f:(fun (reset, _) ->
                    (selector_endpoint, Some reset))))
    in
    let root =
      Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
        description
    in
    let (selector_endpoint, reset), post =
      committed (run_ok runtime (Crux.Root.advance root))
    in
    start runtime post;
    (root, selector_endpoint, Option.get reset, resets)
  in
  let advance root =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Committed { post_commit; _ }) ->
        start runtime post_commit;
        `Committed
    | Ok (Crux.Root.Rejected Crux.Root.Stale_reset) -> `Stale
    | _ -> Alcotest.fail "unexpected reset/disposal outcome"
  in
  let run_case ~reset_first =
    let root, selector, reset, resets = make_fixture () in
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let hook () =
      Eio.Promise.resolve entered_resolver ();
      Eio.Promise.await release
    in
    let previous_before =
      Eta_crux__Crux_reset_barrier.set_before_admission
        (if reset_first then (fun () -> ()) else hook)
    in
    let previous_after =
      Eta_crux__Crux_reset_barrier.set_after_admission
        (if reset_first then hook else fun () -> ())
    in
    let resetting =
      Eta_test.Async.fork_run switch runtime
        (Crux.Reset.trigger reset
        |> Eta.Effect.or_die (fun _ ->
               Invalid_argument "reset ingress closed"))
    in
    Eio.Promise.await entered;
    ignore
      (run_ok runtime
         (Crux.Endpoint.send selector false
         |> Eta.Effect.or_die (fun _ ->
                Invalid_argument "selector ingress closed")));
    Eio.Promise.resolve release_resolver ();
    ignore
      (Eta_test.Async.await resetting
      |> Eta_test.Expect.expect_ok);
    let (_ : unit -> unit) =
      Eta_crux__Crux_reset_barrier.set_before_admission
        previous_before
    in
    let (_ : unit -> unit) =
      Eta_crux__Crux_reset_barrier.set_after_admission
        previous_after
    in
    if reset_first then (
      Alcotest.(check bool) "reset won before disposal" true
        (advance root = `Committed);
      Alcotest.(check int) "reset callback ran once" 1 !resets;
      Alcotest.(check bool) "queued disposal followed reset" true
        (advance root = `Committed))
    else (
      Alcotest.(check bool) "disposal won before reset" true
        (advance root = `Committed);
      Alcotest.(check bool) "disposed reset became stale" true
        (advance root = `Stale);
      Alcotest.(check int) "stale reset ran no callback" 0 !resets)
  in
  run_case ~reset_first:true;
  run_case ~reset_first:false

let race_poll_completion_vs_disposal_both_winners () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let make_fixture () =
    let controlled = Eta_test.Controlled.create () in
    let selector =
      Crux.State_machine.create (Crux.return ())
        ~default_model:true
        ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
          (action, None))
    in
    let description =
      Crux.bind selector
        ~f:(fun (active, selector_endpoint) ->
          if not active then
            Crux.return (selector_endpoint, None)
          else
            let result, refresh =
              Crux.Poll.manual_refresh
                ~starting:Crux.Poll.Starting.empty
                ~effect:
                  (Crux.return
                     (Eta_test.Controlled.eff controlled ()))
                ()
            in
            Crux.map (Crux.both result refresh)
              ~f:(fun (result, refresh) ->
                (selector_endpoint, Some (result, refresh))))
    in
    let root =
      Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
        description
    in
    let (selector, poll), initial_post =
      committed (run_ok runtime (Crux.Root.advance root))
    in
    start runtime initial_post;
    let _, refresh = Option.get poll in
    ignore
      (run_ok runtime
         (refresh
         |> Eta.Effect.or_die (fun _ ->
                Invalid_argument "refresh ingress closed")));
    let _, trigger_post =
      committed (run_ok runtime (Crux.Root.advance root))
    in
    start runtime trigger_post;
    let call =
      run_ok runtime (Eta_test.Controlled.await_call controlled)
    in
    (root, selector, call)
  in
  let commit root =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Committed { commit; post_commit }) ->
        let output = output_of_commit commit in
        start runtime post_commit;
        `Committed output
    | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> `Stale
    | _ -> Alcotest.fail "unexpected Poll disposal outcome"
  in
  let run_case ~completion_first result =
    let root, selector, call = make_fixture () in
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let admitted, admitted_resolver = Eio.Promise.create () in
    let hook () =
      Eio.Promise.resolve entered_resolver ();
      Eio.Promise.await release
    in
    let previous_before =
      Eta_crux__Crux_poll_barrier
      .set_before_completion_admission
        (if completion_first then (fun () -> ()) else hook)
    in
    let previous_after =
      Eta_crux__Crux_poll_barrier
      .set_after_completion_admission
        (fun () ->
          Eio.Promise.resolve admitted_resolver ();
          if completion_first then hook ())
    in
    Alcotest.(check bool) "Poll body settled" true
      (Eta_test.Controlled.succeed call result = Ok ());
    Eio.Promise.await entered;
    ignore
      (run_ok runtime
         (Crux.Endpoint.send selector false
         |> Eta.Effect.or_die (fun _ ->
                Invalid_argument "selector ingress closed")));
    Eio.Promise.resolve release_resolver ();
    Eio.Promise.await admitted;
    let (_ : unit -> unit) =
      Eta_crux__Crux_poll_barrier
      .set_before_completion_admission previous_before
    in
    let (_ : unit -> unit) =
      Eta_crux__Crux_poll_barrier
      .set_after_completion_admission previous_after
    in
    if completion_first then (
      (match commit root with
      | `Committed (_, Some (Some selected, _))
        when selected = result ->
          ()
      | _ -> Alcotest.fail "completion did not win before disposal");
      match commit root with
      | `Committed (_, None) -> ()
      | _ -> Alcotest.fail "disposal did not follow completion")
    else (
      (match commit root with
      | `Committed (_, None) -> ()
      | _ -> Alcotest.fail "disposal did not win");
      Alcotest.(check bool) "old completion fenced" true
        (commit root = `Stale))
  in
  run_case ~completion_first:true 10;
  run_case ~completion_first:false 20

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
          Alcotest.test_case "session replacement permit wait" `Quick
            test_session_replacement_permit_wait;
          Alcotest.test_case "replacement vs commit both winners" `Quick
            race_replacement_vs_commit_both_winners;
          Alcotest.test_case "test clock movement both winners" `Quick
            race_test_clock_movement_both_winners;
          Alcotest.test_case "driver attachment both winners" `Quick
            race_driver_attachment_both_winners;
          Alcotest.test_case "handle shared clock movement both winners" `Quick
            race_handle_shared_clock_movement_both_winners;
          Alcotest.test_case "pull vs commit both winners" `Quick
            race_pull_vs_commit_both_winners;
          Alcotest.test_case
            "post-commit observer read both winners" `Quick
            race_post_commit_effect_observer_read_both_winners;
          Alcotest.test_case "reset vs disposal both winners" `Quick
            race_reset_vs_disposal_both_winners;
          Alcotest.test_case "poll completion vs disposal both winners" `Quick
            race_poll_completion_vs_disposal_both_winners;
        ] );
    ]
