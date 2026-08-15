module Crux = Eta_crux

let test_clock = Eta_test.Test_clock.create ()
let test_clock_capability = Eta_test.Test_clock.as_capability test_clock

let run_ok eff =
  let outcome =
    Eta_test.Run.run ~clock:test_clock
      (Eta.Effect.with_clock test_clock_capability eff)
  in
  Eta_test.Expect.expect_ok outcome.exit

let run_runtime_ok runtime eff =
  Eta.Runtime.run runtime
    (Eta.Effect.with_clock test_clock_capability eff)
  |> Eta_test.Expect.expect_ok

let committed = function
  | Ok (Crux.Root.Committed committed) ->
      (committed.output, committed.post_commit)
  | Ok Crux.Root.Idle -> Alcotest.fail "expected commit, got idle"
  | Ok (Crux.Root.Rejected _) -> Alcotest.fail "expected commit, got rejection"
  | Ok (Crux.Root.Stopped _) -> Alcotest.fail "expected commit, got stop"
  | Ok (Crux.Root.Failed _) -> Alcotest.fail "expected commit, got failure"
  | Error _ -> Alcotest.fail "expected commit, got advance error"

let test_description_is_inert () =
  let transitions = ref 0 in
  let lifecycle_starts = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        incr transitions;
        (model + action, None))
  in
  let description =
    Crux.both machine
      (Crux.lifecycle
         (Crux.return
            (Eta.Effect.sync (fun () -> incr lifecycle_starts))))
  in
  Alcotest.(check int) "construction did not transition" 0 !transitions;
  Alcotest.(check int) "construction did not start lifecycle" 0
    !lifecycle_starts;
  let root =
    Crux.Root.create ~ingress_capacity:4 ~request_capacity:2 description
  in
  Alcotest.(check int) "root creation did not transition" 0 !transitions;
  Alcotest.(check int) "root creation did not start lifecycle" 0
    !lifecycle_starts;
  let _output, first_post_commit = committed (run_ok (Crux.Root.advance root)) in
  Alcotest.(check int) "start did not transition" 0 !transitions;
  Alcotest.(check int) "lifecycle is staged until post commit" 0
    !lifecycle_starts;
  ignore (run_ok (Crux.Post_commit.start first_post_commit));
  Alcotest.(check int) "post commit starts lifecycle" 1 !lifecycle_starts

let test_roots_are_isolated () =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let left =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 machine
  in
  let right =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 machine
  in
  let left_output, left_start = committed (run_ok (Crux.Root.advance left)) in
  let right_output, right_start = committed (run_ok (Crux.Root.advance right)) in
  let left_model, left_endpoint = left_output in
  let right_model, _right_endpoint = right_output in
  Alcotest.(check int) "left initial model" 0 left_model;
  Alcotest.(check int) "right initial model" 0 right_model;
  ignore (run_ok (Crux.Post_commit.start left_start));
  ignore (run_ok (Crux.Post_commit.start right_start));
  ignore (run_ok (Crux.Endpoint.send left_endpoint 3));
  let left_output, left_next = committed (run_ok (Crux.Root.advance left)) in
  let left_model, _ = left_output in
  Alcotest.(check int) "left advanced" 3 left_model;
  let right_idle = run_ok (Crux.Root.advance right) in
  (match right_idle with
  | Ok Crux.Root.Idle -> ()
  | _ -> Alcotest.fail "right root was not idle");
  ignore (run_ok (Crux.Post_commit.start left_next))

let test_endpoint_acceptance_boundary () =
  let transitions = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        incr transitions;
        (model + action, None))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 machine
  in
  let output, start = committed (run_ok (Crux.Root.advance root)) in
  let _, endpoint = output in
  ignore (run_ok (Crux.Post_commit.start start));
  ignore (run_ok (Crux.Endpoint.send endpoint 1));
  Alcotest.(check int) "send did not run transition" 0 !transitions;
  let output, next = committed (run_ok (Crux.Root.advance root)) in
  Alcotest.(check int) "advance ran one transition" 1 !transitions;
  let model, _ = output in
  Alcotest.(check int) "committed model" 1 model;
  ignore (run_ok (Crux.Post_commit.start next))

let test_transition_effect_is_staged () =
  let effect_starts = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        ( model + action,
          Some (Eta.Effect.sync (fun () -> incr effect_starts)) ))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 machine
  in
  let output, start = committed (run_ok (Crux.Root.advance root)) in
  let _, endpoint = output in
  ignore (run_ok (Crux.Post_commit.start start));
  ignore (run_ok (Crux.Endpoint.send endpoint 1));
  let _output, next = committed (run_ok (Crux.Root.advance root)) in
  Alcotest.(check int) "effect remains staged" 0 !effect_starts;
  ignore (run_ok (Crux.Post_commit.start next));
  Alcotest.(check int) "effect starts after acknowledgment" 1 !effect_starts

let test_driver_delivers_before_post_commit () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let lifecycle_started = ref false in
  let description =
    Crux.both (Crux.return 7)
      (Crux.lifecycle
         (Crux.return
            (Eta.Effect.sync (fun () -> lifecycle_started := true))))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "expected initial delivery"
  in
  Alcotest.(check int) "complete output" 7
    (fst (Crux.Driver.Delivery.output delivery));
  Alcotest.(check bool) "lifecycle remains gated" false !lifecycle_started;
  Alcotest.(check bool) "delivery accepted" true
    (run_runtime_ok runtime (Crux.Driver.Delivery.delivered delivery) = Ok ());
  Eio.Fiber.yield ();
  Alcotest.(check bool) "lifecycle starts after delivery" true
    !lifecycle_started

let test_outbound_request_round_trip () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let int_codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        try Ok (int_of_string (Bytes.to_string bytes))
        with Failure message ->
          Error { Crux.Codec.message = message })
  in
  let string_codec =
    Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
      ~decode:(fun bytes -> Ok (Bytes.to_string bytes))
  in
  let operation =
    Crux.Host_operation.define ~name:"test.echo"
      ~request:int_codec ~response:string_codec
  in
  let different_operation =
    Crux.Host_operation.define ~name:"test.other"
      ~request:int_codec ~response:string_codec
  in
  let binding =
    Crux.Driver.Binding.identity [ Crux.Host_operation.Pack operation ]
  in
  let requester = Crux.Driver.Binding.requester binding operation in
  let response = ref None in
  let request_effect =
    Crux.Requester.request requester 42
    |> Eta.Effect.map (fun value ->
           response := Some value)
    |> Eta.Effect.or_die (function
         | Crux.Requester.Ingress_closed -> Failure "ingress closed"
         | Crux.Requester.Encode_failed _ -> Failure "encode failed"
         | Crux.Requester.Decode_failed _ -> Failure "decode failed"
         | Crux.Requester.Dispatch_failed -> Failure "dispatch failed"
         | Crux.Requester.Closed _ -> Failure "request closed")
  in
  let description =
    Crux.both (Crux.return ())
      (Crux.lifecycle (Crux.return request_effect))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let driver = Crux.Driver.create binding root in
  let delivery =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "expected initial delivery"
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered delivery) :
      (unit, Crux.Driver.Delivery.completion_error) result);
  let rec await_request attempts =
    if attempts = 0 then Alcotest.fail "request event did not arrive"
    else
      match run_runtime_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Request event) -> event
      | Some _ | None ->
          Eio.Fiber.yield ();
          await_request (attempts - 1)
  in
  let event = await_request 100 in
  let mismatched_handler_ran = ref false in
  let mismatched =
    Crux.Request.Driver_event.handle event different_operation
      ~f:(fun _request ~resolve:_ ~on_cancel:_ ->
        mismatched_handler_ran := true;
        Eta.Effect.unit)
    |> run_runtime_ok runtime
  in
  Alcotest.(check bool) "mismatched handler did not claim" true
    (mismatched = Crux.Request.Driver_event.Different_operation);
  Alcotest.(check bool) "mismatched handler did not run" false
    !mismatched_handler_ran;
  let unrun_handler_ran = ref false in
  let _unrun =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun _request ~resolve:_ ~on_cancel:_ ->
        unrun_handler_ran := true;
        Eta.Effect.unit)
  in
  let handled =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun request ~resolve ~on_cancel:_ ->
        resolve (string_of_int request)
        |> Eta.Effect.map (fun _ -> ()))
    |> run_runtime_ok runtime
  in
  (match handled with
  | Crux.Request.Driver_event.Handled -> ()
  | Crux.Request.Driver_event.Different_operation ->
      Alcotest.fail "operation did not match"
  | Crux.Request.Driver_event.Already_handled ->
      Alcotest.fail "first handler did not claim the request"
  | Crux.Request.Driver_event.Closed _ ->
      Alcotest.fail "request closed before its first handler");
  Alcotest.(check bool) "unrun handler did not claim or run" false
    !unrun_handler_ran;
  let second_handler_ran = ref false in
  let handled_again =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun _request ~resolve:_ ~on_cancel:_ ->
        second_handler_ran := true;
        Eta.Effect.unit)
    |> run_runtime_ok runtime
  in
  Alcotest.(check bool) "second matching handler was rejected" true
    (handled_again = Crux.Request.Driver_event.Already_handled);
  Alcotest.(check bool) "second matching handler did not run" false
    !second_handler_ran;
  ignore
    (run_runtime_ok runtime
       (Crux.Request.Driver_event.accepted event) :
      (unit, Crux.Request.Driver_event.completion_error) result);
  let rec await_response attempts =
    if Option.is_some !response then ()
    else if attempts = 0 then Alcotest.fail "request response did not arrive"
    else (
      Eio.Fiber.yield ();
      await_response (attempts - 1))
  in
  await_response 100;
  Alcotest.(check (option string)) "typed response" (Some "42") !response;

  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Requester.request requester 7 |> Eta.Effect.to_result)
  in
  let event = await_request 100 in
  let failed_handler_ran = ref 0 in
  let failed_handler =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun _request ~resolve:_ ~on_cancel:_ ->
        incr failed_handler_ran;
        Eta.Effect.fail `Handler_failed)
    |> Eta.Effect.to_result |> run_runtime_ok runtime
  in
  Alcotest.(check bool) "typed handler failure returned" true
    (failed_handler = Error `Handler_failed);
  let after_failure_ran = ref false in
  let handled_after_failure =
    Crux.Request.Driver_event.handle event operation
      ~f:(fun _request ~resolve:_ ~on_cancel:_ ->
        after_failure_ran := true;
        Eta.Effect.unit)
    |> run_runtime_ok runtime
  in
  Alcotest.(check bool) "typed failure retained handler claim" true
    (handled_after_failure = Crux.Request.Driver_event.Already_handled);
  Alcotest.(check int) "typed handler ran once" 1 !failed_handler_ran;
  Alcotest.(check bool) "fall-through handler did not run" false
    !after_failure_ran;
  let cause =
    Crux.Failure.Packed_cause.make
      ~pp_error:Format.pp_print_string
      (Eta.Cause.fail "handler failed")
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Request.Driver_event.failed event cause));
  let request_result =
    Eta_test.Async.await pending |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "failed dispatch reached requester" true
    (request_result = Error Crux.Requester.Dispatch_failed)

let test_requester_rejects_name_collision () =
  let int_codec =
    Crux.Codec.make
      ~encode:(fun value ->
        Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        try Ok (int_of_string (Bytes.to_string bytes))
        with Failure message ->
          Error { Crux.Codec.message = message })
  in
  let string_codec =
    Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
      ~decode:(fun bytes -> Ok (Bytes.to_string bytes))
  in
  let registered =
    Crux.Host_operation.define ~name:"test.collision"
      ~request:int_codec ~response:string_codec
  in
  let collision =
    Crux.Host_operation.define ~name:"test.collision"
      ~request:string_codec ~response:int_codec
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack registered ]
  in
  Alcotest.(check bool) "descriptor identity is required" true
    (try
       ignore
         (Crux.Driver.Binding.requester binding collision :
           (string, int) Crux.Requester.t);
       false
     with Invalid_argument _ -> true)

let test_cutoff_suppresses_only_dependent_recomputation () =
  let projections = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let model = Crux.map machine ~f:fst in
  let parity =
    Crux.cutoff model
      ~cutoff:
        (Crux.Cutoff.of_equal (fun left right ->
             left mod 2 = right mod 2))
    |> Crux.map ~f:(fun value ->
           incr projections;
           value mod 2)
  in
  let description = Crux.both machine parity in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 description
  in
  let output, start = committed (run_ok (Crux.Root.advance root)) in
  let (model, endpoint), parity = output in
  Alcotest.(check int) "initial model" 0 model;
  Alcotest.(check int) "initial parity" 0 parity;
  Alcotest.(check int) "initial projection" 1 !projections;
  ignore (run_ok (Crux.Post_commit.start start));
  ignore (run_ok (Crux.Endpoint.send endpoint 2));
  let output, batch = committed (run_ok (Crux.Root.advance root)) in
  let (model, _), parity = output in
  Alcotest.(check int) "equal-cutoff commit still delivers model" 2 model;
  Alcotest.(check int) "published parity" 0 parity;
  Alcotest.(check int) "dependent projection suppressed" 1 !projections;
  ignore (run_ok (Crux.Post_commit.start batch))

let test_post_commit_starts_exactly_once () =
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  let _, batch = committed (run_ok (Crux.Root.advance root)) in
  Alcotest.(check bool) "first start"
    true
    (run_ok (Crux.Post_commit.start batch) = Crux.Post_commit.Admitted);
  match (Eta_test.Run.run (Crux.Post_commit.start batch)).exit with
  | Eta.Exit.Error (Eta.Cause.Fail Crux.Post_commit.Already_started) -> ()
  | _ -> Alcotest.fail "second post-commit start did not fail"

let test_idle_is_inert () =
  let evaluations = ref 0 in
  let description =
    Crux.map (Crux.return 1) ~f:(fun value ->
        incr evaluations;
        value)
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let _, start = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_ok (Crux.Post_commit.start start));
  Alcotest.(check int) "initial stabilization" 1 !evaluations;
  (match run_ok (Crux.Root.advance root) with
  | Ok Crux.Root.Idle -> ()
  | _ -> Alcotest.fail "empty root did not return Idle");
  Alcotest.(check int) "idle did not stabilize" 1 !evaluations

let test_transition_rollback () =
  let projections = ref 0 in
  let staged_starts = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:3
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        if action < 0 then raise Exit;
        ( model + action,
          Some (Eta.Effect.sync (fun () -> incr staged_starts)) ))
  in
  let description =
    Crux.map machine ~f:(fun (model, endpoint) ->
        incr projections;
        (model, endpoint))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 description
  in
  let (_, endpoint), start = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_ok (Crux.Post_commit.start start));
  ignore (run_ok (Crux.Endpoint.send endpoint (-1)));
  let failed_post_commit =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { post_commit; _ }) -> post_commit
    | _ -> Alcotest.fail "transition exception did not fail the root"
  in
  Alcotest.(check int) "no derived stabilization was published" 1 !projections;
  Alcotest.(check int) "staged effect did not start" 0 !staged_starts;
  ignore (run_ok (Crux.Post_commit.start failed_post_commit));
  Alcotest.(check int) "crash settlement did not release staged effect" 0
    !staged_starts

let test_stale_endpoint_rejection () =
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let child initial =
    Crux.State_machine.create (Crux.return ()) ~default_model:initial
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let present = child 10 in
  let absent = child 20 in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun value ->
        if value then present else absent)
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both selector selected)
  in
  let ((_, selector_endpoint), (_, old_endpoint)), start =
    committed (run_ok (Crux.Root.advance root))
  in
  ignore (run_ok (Crux.Post_commit.start start));
  ignore (run_ok (Crux.Endpoint.send selector_endpoint false));
  let _, switched = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_ok (Crux.Post_commit.start switched));
  ignore (run_ok (Crux.Endpoint.send old_endpoint 1));
  match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Rejected Crux.Root.Stale_endpoint) -> ()
  | _ -> Alcotest.fail "disposed child endpoint was not rejected as stale"

let test_lifecycle_resource_cleanup () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let started = ref false in
  let finalized = ref false in
  let program =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> started := true))
    |> Eta.Effect.finally
         (Eta.Effect.sync (fun () -> finalized := true))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return program))
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_runtime_ok runtime (Crux.Post_commit.start initial_post));
  let rec await flag attempts =
    if !flag then ()
    else if attempts = 0 then Alcotest.fail "owned lifecycle did not make progress"
    else (
      Eio.Fiber.yield ();
      await flag (attempts - 1))
  in
  await started 100;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "stop did not produce terminal post-commit work"
  in
  Alcotest.(check bool) "not finalized before stop settlement" false !finalized;
  (match run_runtime_ok runtime (Crux.Post_commit.start stop_post) with
  | Crux.Post_commit.Stop_settled -> ()
  | _ -> Alcotest.fail "stop did not settle");
  Alcotest.(check bool) "resource finalized before stop settled" true !finalized

let test_structural_scope_settlement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let parent_started = ref false in
  let child_started = ref false in
  let replacement_started = ref false in
  let cleanup_order = ref [] in
  let release_child = Eta.Promise.create () in
  let long_lived started cleanup =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> started := true))
    |> Eta.Effect.finally cleanup
  in
  let parent_program =
    long_lived parent_started
      (Eta.Effect.sync (fun () ->
           cleanup_order := !cleanup_order @ [ "parent" ]))
  in
  let child_program =
    long_lived child_started
      (Eta.Effect.bind
         (fun () ->
           Eta.Effect.sync (fun () ->
               cleanup_order := !cleanup_order @ [ "child" ]))
         (Eta.Promise.await release_child))
  in
  let replacement_program =
    long_lived replacement_started Eta.Effect.unit
  in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let old_subtree =
    Crux.both (Crux.lifecycle (Crux.return parent_program))
      (Crux.bind (Crux.return ()) ~f:(fun () ->
           Crux.lifecycle (Crux.return child_program)))
    |> Crux.map ~f:(fun _ -> ())
  in
  let replacement =
    Crux.lifecycle (Crux.return replacement_program)
  in
  let description =
    Crux.both selector
      (Crux.bind (Crux.map selector ~f:fst) ~f:(fun present ->
           if present then old_subtree else replacement))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 description
  in
  let start post_commit =
    Crux.Post_commit.start post_commit
    |> Eta.Effect.or_die (function
         | Crux.Post_commit.Already_started ->
             Failure "post-commit token started twice")
    |> run_runtime_ok runtime
    |> ignore
  in
  let send endpoint value =
    Crux.Endpoint.send endpoint value
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed -> Failure "ingress closed")
    |> run_runtime_ok runtime
    |> ignore
  in
  let ((_, selector_endpoint), _), initial_post =
    committed (run_ok (Crux.Root.advance root))
  in
  start initial_post;
  let rec await flag message attempts =
    if !flag then ()
    else if attempts = 0 then Alcotest.fail message
    else (
      Eio.Fiber.yield ();
      await flag message (attempts - 1))
  in
  await parent_started "parent lifecycle did not start" 100;
  await child_started "child lifecycle did not start" 100;
  send selector_endpoint false;
  let _, replacement_post = committed (run_ok (Crux.Root.advance root)) in
  start replacement_post;
  await replacement_started
    "replacement did not start while removed cleanup was pending" 100;
  Alcotest.(check (list string)) "old cleanup remains gated" [] !cleanup_order;
  ignore
    (run_runtime_ok runtime
       (Eta.Promise.resolve release_child (Eta.Exit.Ok ())));
  let rec await_cleanup attempts =
    if List.length !cleanup_order = 2 then ()
    else if attempts = 0 then Alcotest.fail "removed subtree did not settle"
    else (
      Eio.Fiber.yield ();
      await_cleanup (attempts - 1))
  in
  await_cleanup 100;
  Alcotest.(check (list string)) "child settles before parent"
    [ "child"; "parent" ] !cleanup_order;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not stop"
  in
  start stop_post

let test_cleanup_overlap () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let cleanup_entered = Eta.Promise.create () in
  let release_cleanup = Eta.Promise.create () in
  let old_started = ref false in
  let new_started = ref false in
  let cleanup_settled = ref false in
  let old_program =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> old_started := true))
    |> Eta.Effect.finally
         (let open Eta.Syntax in
          let* _ =
            Eta.Promise.resolve cleanup_entered (Eta.Exit.Ok ())
          in
          let* () = Eta.Promise.await release_cleanup in
          Eta.Effect.sync (fun () -> cleanup_settled := true))
  in
  let new_program =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> new_started := true))
  in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun old_present ->
        if old_present then
          Crux.lifecycle (Crux.return old_program)
        else Crux.lifecycle (Crux.return new_program))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both selector selected)
  in
  let start post_commit =
    ignore
      (run_runtime_ok runtime
         (Crux.Post_commit.start post_commit
         |> Eta.Effect.or_die (function
              | Crux.Post_commit.Already_started ->
                  Failure "cleanup overlap token started twice")))
  in
  let ((_, selector_endpoint), _), initial_post =
    committed (run_ok (Crux.Root.advance root))
  in
  start initial_post;
  let rec await flag failure attempts =
    if !flag then ()
    else if attempts = 0 then Alcotest.fail failure
    else (
      Eio.Fiber.yield ();
      await flag failure (attempts - 1))
  in
  await old_started "old work did not start" 100;
  ignore
    (run_runtime_ok runtime
       (Crux.Endpoint.send selector_endpoint false
       |> Eta.Effect.or_die (function
            | Crux.Endpoint.Ingress_closed ->
                Failure "cleanup overlap ingress closed")));
  let _, replacement_post = committed (run_ok (Crux.Root.advance root)) in
  start replacement_post;
  await new_started "new work waited for old cleanup" 100;
  ignore (run_runtime_ok runtime (Eta.Promise.await cleanup_entered));
  Alcotest.(check bool) "new work overlaps blocked cleanup" false
    !cleanup_settled;
  ignore
    (run_runtime_ok runtime
       (Eta.Promise.resolve release_cleanup (Eta.Exit.Ok ())));
  await cleanup_settled "old cleanup did not settle" 100;
  Crux.Root.request_stop root;
  match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) -> start post_commit
  | _ -> Alcotest.fail "cleanup overlap root did not stop"

let test_concurrent_source_opening () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let open Eta.Syntax in
  let events = ref [] in
  let opening_count = ref 0 in
  let opening_gate = Eta.Promise.create () in
  let producer id ~emit:_ =
    let* () =
      Eta.Effect.sync (fun () ->
          incr opening_count;
          events := !events @ [ Printf.sprintf "opening:%d" id ])
    in
    let* () =
      if !opening_count = 2 then
        Eta.Promise.resolve opening_gate (Eta.Exit.Ok ())
        |> Eta.Effect.map (fun _ -> ())
      else Eta.Effect.unit
    in
    let* () = Eta.Promise.await opening_gate in
    let* () =
      Eta.Effect.sync (fun () ->
          events := !events @ [ Printf.sprintf "ready:%d" id ])
    in
    Eta.Effect.pure
      (let* () =
         Eta.Effect.sync (fun () ->
             events := !events @ [ Printf.sprintf "running:%d" id ])
       in
       Eta.Effect.never)
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:[]
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model @ [ action ], None))
  in
  let target = Crux.map machine ~f:snd in
  let source id =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Int.equal)
      ~spec:(Crux.return id)
      ~producer:(Crux.return producer) ~target
      ~on_item:(Crux.return (fun item -> item))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> "completed"
          | Crux.Source.Failed _ -> "failed"))
  in
  let description =
    Crux.both machine (Crux.both (source 1) (source 2))
  in
  let root =
    Crux.Root.create ~ingress_capacity:4 ~request_capacity:1 description
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  let start post_commit =
    Crux.Post_commit.start post_commit
    |> Eta.Effect.or_die (function
         | Crux.Post_commit.Already_started ->
             Failure "post-commit token started twice")
    |> run_runtime_ok runtime
    |> ignore
  in
  start initial_post;
  let rec await_running attempts =
    let running =
      List.filter
        (fun event -> String.starts_with ~prefix:"running:" event)
        !events
      |> List.length
    in
    if running = 2 then ()
    else if attempts = 0 then Alcotest.fail "source producers did not start"
    else (
      Eio.Fiber.yield ();
      await_running (attempts - 1))
  in
  await_running 100;
  let indexed = List.mapi (fun index event -> (index, event)) !events in
  let ready_positions =
    List.filter
      (fun (_, event) -> String.starts_with ~prefix:"ready:" event)
      indexed
  in
  let running_positions =
    List.filter
      (fun (_, event) -> String.starts_with ~prefix:"running:" event)
      indexed
  in
  Alcotest.(check int) "both openings entered" 2 !opening_count;
  Alcotest.(check int) "both sources reported ready" 2
    (List.length ready_positions);
  Alcotest.(check int) "both producers started" 2
    (List.length running_positions);
  let last_ready =
    ready_positions |> List.map fst |> List.fold_left max min_int
  in
  let first_running =
    running_positions |> List.map fst |> List.fold_left min max_int
  in
  Alcotest.(check bool) "producers start after every ready report" true
    (last_ready < first_running);
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not stop"
  in
  start stop_post

let test_source_opening_barrier () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let open Eta.Syntax in
  let opening_entered = Eta.Promise.create () in
  let allow_ready = Eta.Promise.create () in
  let producer_started = ref false in
  let sibling_started = ref false in
  let producer () ~emit:_ =
    let* _ =
      Eta.Promise.resolve opening_entered (Eta.Exit.Ok ())
    in
    let* () = Eta.Promise.await allow_ready in
    Eta.Effect.pure
      (let* () =
         Eta.Effect.sync (fun () -> producer_started := true)
       in
       Eta.Effect.never)
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:()
      ~apply_action:(fun ~self:_ ~input:() ~model:() ~action:() ->
        ((), None))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Unit.equal)
      ~spec:(Crux.return ()) ~producer:(Crux.return producer)
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> ()))
      ~on_terminal:
        (Crux.return (fun (_ : string Crux.Source.terminal) -> ()))
  in
  let sibling =
    Crux.lifecycle
      (Crux.return
         (let* () =
            Eta.Effect.sync (fun () -> sibling_started := true)
          in
          Eta.Effect.never))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both machine (Crux.both source sibling))
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Post_commit.start initial_post
      |> Eta.Effect.or_die (function
           | Crux.Post_commit.Already_started ->
               Failure "source barrier token started twice"))
  in
  ignore (run_runtime_ok runtime (Eta.Promise.await opening_entered));
  Alcotest.(check bool) "producer remains gated before ready" false
    !producer_started;
  Alcotest.(check bool) "sibling work remains gated before ready" false
    !sibling_started;
  Alcotest.(check bool) "post-commit waits for ready" false
    (Eio.Promise.is_resolved pending);
  ignore
    (run_runtime_ok runtime
       (Eta.Promise.resolve allow_ready (Eta.Exit.Ok ())));
  (match Eta_test.Async.await pending |> Eta_test.Expect.expect_ok with
  | Crux.Post_commit.Admitted -> ()
  | Crux.Post_commit.Stop_settled
  | Crux.Post_commit.Crash_settled _ ->
      Alcotest.fail "source ready terminated the root");
  let rec await_started attempts =
    if !producer_started && !sibling_started then ()
    else if attempts = 0 then
      Alcotest.fail "post-ready work did not start"
    else (
      Eio.Fiber.yield ();
      await_started (attempts - 1))
  in
  await_started 100;
  Crux.Root.request_stop root;
  match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) ->
      ignore
        (run_runtime_ok runtime
           (Crux.Post_commit.start post_commit
           |> Eta.Effect.or_die (function
                | Crux.Post_commit.Already_started ->
                    Failure "source stop token started twice")))
  | _ -> Alcotest.fail "source barrier root did not stop"

let test_source_argument_work_starts_once () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let starts = ref 0 in
  let producer () ~emit:_ =
    Eta.Effect.pure Eta.Effect.never
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:()
      ~apply_action:(fun ~self:_ ~input:() ~model:() ~action:() ->
        ((), None))
  in
  let producer =
    Crux.map
      (Crux.both (Crux.return producer)
         (Crux.lifecycle
            (Crux.return
               (Eta.Effect.sync (fun () -> incr starts)))))
      ~f:fst
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Unit.equal)
      ~spec:(Crux.return ()) ~producer
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> ()))
      ~on_terminal:
        (Crux.return (fun (_ : string Crux.Source.terminal) -> ()))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both machine source)
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  ignore
    (run_runtime_ok runtime
       (Crux.Post_commit.start initial_post
       |> Eta.Effect.or_die (function
            | Crux.Post_commit.Already_started ->
                Failure "post-commit token started twice")));
  let rec await_start attempts =
    if !starts = 1 then ()
    else if attempts = 0 then
      Alcotest.failf "source argument work started %d times" !starts
    else (
      Eio.Fiber.yield ();
      await_start (attempts - 1))
  in
  await_start 100;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "source argument root did not stop"
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Post_commit.start stop_post
       |> Eta.Effect.or_die (function
            | Crux.Post_commit.Already_started ->
                Failure "post-commit token started twice")))

let test_crash_latch () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle
         (Crux.return (Eta.Effect.die_message "owned lifecycle crashed")))
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_runtime_ok runtime (Crux.Post_commit.start initial_post));
  let rec await_failure attempts =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { failure; post_commit }) ->
        (failure, post_commit)
    | Ok Crux.Root.Idle when attempts > 0 ->
        Eio.Fiber.yield ();
        await_failure (attempts - 1)
    | _ -> Alcotest.fail "owned defect did not latch root failure"
  in
  let failure, crash_post = await_failure 100 in
  Alcotest.(check bool) "owned work is the primary failure" true
    (failure.primary.origin = Crux.Failure.Owned_work);
  Alcotest.(check bool) "lifecycle trigger is retained" true
    (failure.primary.trigger = Crux.Failure.Lifecycle_program);
  match run_runtime_ok runtime (Crux.Post_commit.start crash_post) with
  | Crux.Post_commit.Crash_settled settlement ->
      Alcotest.(check bool) "teardown settled" true
        settlement.teardown_settled
  | _ -> Alcotest.fail "crash did not settle"

let test_driver_await_wakes_on_fatal () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let entered = Eta.Promise.create () in
  let release = Eta.Promise.create () in
  let program =
    let open Eta.Syntax in
    let* _ = Eta.Promise.resolve entered (Eta.Exit.Ok ()) in
    let* () = Eta.Promise.await release in
    Eta.Effect.die_message "await wake defect"
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return program))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None -> Alcotest.fail "expected initial delivery"
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered delivery));
  ignore (run_runtime_ok runtime (Eta.Promise.await entered));
  let waiter =
    Eta_test.Async.fork_run switch runtime
      (Eta.Effect.with_clock test_clock_capability
         (Crux.Driver.await driver
         |> Eta.Effect.map_error (fun (value : Crux.never) ->
              match value with _ -> .)
         |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
              ~on_timeout:`Timeout
         |> Eta.Effect.or_die (fun `Timeout ->
              Failure "driver remained asleep after fatal work")))
  in
  ignore
    (run_runtime_ok runtime
       (Eta.Promise.resolve release (Eta.Exit.Ok ())));
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  if not (Eio.Promise.is_resolved waiter) then
    Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await waiter with
  | Eta.Exit.Ok (Crux.Driver.Crash_detected failure) ->
      Alcotest.(check bool) "fatal origin" true
        (failure.primary.origin = Crux.Failure.Owned_work)
  | Eta.Exit.Ok _ ->
      Alcotest.fail "driver awoke with a non-crash event"
  | Eta.Exit.Error cause ->
      Alcotest.failf "driver await failed: %a"
        (Eta.Cause.pp (fun _ (value : Crux.never) ->
             match value with _ -> .))
        cause);
  match run_runtime_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed (Crux.Driver.Crashed settlement)) ->
      Alcotest.(check bool) "crash settled" true
        settlement.teardown_settled
  | Some _ | None ->
      Alcotest.fail "driver did not close after crash detection"

let test_cleanup_failure_precedence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let started = ref false in
  let program =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> started := true))
    |> Eta.Effect.finally (Eta.Effect.die_message "cleanup failed")
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return program))
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_runtime_ok runtime (Crux.Post_commit.start initial_post));
  let rec await_started attempts =
    if !started then ()
    else if attempts = 0 then Alcotest.fail "lifecycle did not start"
    else (
      Eio.Fiber.yield ();
      await_started (attempts - 1))
  in
  await_started 100;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not enter stop teardown"
  in
  match run_runtime_ok runtime (Crux.Post_commit.start stop_post) with
  | Crux.Post_commit.Crash_settled settlement ->
      Alcotest.(check bool) "cleanup failure is primary" true
        (settlement.failure.primary.origin = Crux.Failure.Cleanup);
      Alcotest.(check bool) "stop teardown trigger" true
        (settlement.failure.primary.trigger = Crux.Failure.Stop_teardown);
      Alcotest.(check bool) "cleanup teardown settled" true
        settlement.teardown_settled
  | _ -> Alcotest.fail "cleanup failure did not change stop to crash"

let test_source_opening_defect () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let lifecycle_started = ref false in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:()
      ~apply_action:(fun ~self:_ ~input:() ~model:() ~action:() ->
        ((), None))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Unit.equal)
      ~spec:(Crux.return ())
      ~producer:
        (Crux.return (fun () ~emit:_ ->
             Eta.Effect.die_message "source opening defect"))
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> ()))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> ()
          | Crux.Source.Failed (_ : string) -> ()))
  in
  let description =
    Crux.both machine
      (Crux.both
         (Crux.lifecycle
            (Crux.return
               (Eta.Effect.sync (fun () -> lifecycle_started := true))))
         source)
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 description
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  match run_runtime_ok runtime (Crux.Post_commit.start initial_post) with
  | Crux.Post_commit.Crash_settled settlement ->
      Alcotest.(check bool) "source opening is primary" true
        (settlement.failure.primary.trigger = Crux.Failure.Source_opening);
      Alcotest.(check bool) "other batch work was suppressed" false
        !lifecycle_started;
      Alcotest.(check bool) "opening crash teardown settled" true
        settlement.teardown_settled
  | _ -> Alcotest.fail "source opening defect did not crash the root"

let await_post_start switch clock runtime post_commit =
  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Post_commit.start post_commit
      |> Eta.Effect.map_error
           (fun Crux.Post_commit.Already_started -> `Already_started)
      |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
           ~on_timeout:`Timeout
      |> Eta.Effect.or_die (function
           | `Already_started ->
               Failure "post-commit token was already started"
           | `Timeout ->
               Failure "post-commit source opening did not settle"))
  in
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  if not (Eio.Promise.is_resolved pending) then
    Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  Eta_test.Async.await pending |> Eta_test.Expect.expect_ok

let test_source_opening_failures_do_not_block_admission () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let sink =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let producer () ~emit:_ =
    Eta.Effect.fail "opening failed"
  in
  let source () =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Unit.equal)
      ~spec:(Crux.return ()) ~producer:(Crux.return producer)
      ~target:(Crux.map sink ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> 0))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> 0
          | Crux.Source.Failed (_ : string) -> 1))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both sink (Crux.both (source ()) (source ())))
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  (match await_post_start switch clock runtime initial_post with
  | Crux.Post_commit.Admitted -> ()
  | Crux.Post_commit.Stop_settled
  | Crux.Post_commit.Crash_settled _ ->
      Alcotest.fail "typed opening failure terminated the root");
  let rec await_model remaining =
    if remaining = 0 then
      Alcotest.fail "source terminals did not reach ingress"
    else
      match run_ok (Crux.Root.advance root) with
      | Ok
          (Crux.Root.Committed
            { output = ((model, _), _); post_commit }) ->
          ignore
            (run_runtime_ok runtime
               (Crux.Post_commit.start post_commit));
          if model = 2 then model else await_model (remaining - 1)
      | Ok Crux.Root.Idle | Ok (Crux.Root.Rejected _) ->
          Eio.Fiber.yield ();
          await_model (remaining - 1)
      | Ok (Crux.Root.Stopped _)
      | Ok (Crux.Root.Failed _)
      | Error _ ->
          Alcotest.fail "root terminated before both source terminals"
  in
  Alcotest.(check int) "both terminal actions admitted" 2
    (await_model 100);
  Crux.Root.request_stop root;
  (match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) ->
      ignore
        (run_runtime_ok runtime
           (Crux.Post_commit.start post_commit))
  | _ -> Alcotest.fail "source failure root did not stop")

let test_stop_cancels_source_opening () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let entered = Eta.Promise.create () in
  let cancelled = ref false in
  let producer () ~emit:_ =
    Eta.Effect.finally
      (Eta.Effect.sync (fun () -> cancelled := true))
      (let open Eta.Syntax in
       let* _ = Eta.Promise.resolve entered (Eta.Exit.Ok ()) in
       Eta.Effect.never)
  in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:()
      ~apply_action:(fun ~self:_ ~input:() ~model:() ~action:() ->
        ((), None))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Unit.equal)
      ~spec:(Crux.return ()) ~producer:(Crux.return producer)
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> ()))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> ()
          | Crux.Source.Failed (_ : string) -> ()))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.both machine source)
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Post_commit.start initial_post
      |> Eta.Effect.map_error
           (fun Crux.Post_commit.Already_started -> `Already_started)
      |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
           ~on_timeout:`Timeout
      |> Eta.Effect.or_die (function
           | `Already_started ->
               Failure "post-commit token was already started"
           | `Timeout ->
               Failure "stop did not cancel source opening"))
  in
  ignore (run_runtime_ok runtime (Eta.Promise.await entered));
  Crux.Root.request_stop root;
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  if not (Eio.Promise.is_resolved pending) then
    Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await pending |> Eta_test.Expect.expect_ok with
  | Crux.Post_commit.Stop_settled -> ()
  | Crux.Post_commit.Admitted
  | Crux.Post_commit.Crash_settled _ ->
      Alcotest.fail "stop did not settle the opening batch");
  Alcotest.(check bool) "opening cancellation completed" true !cancelled;
  Alcotest.(check bool) "root closed after stop" true
    (run_ok (Crux.Root.advance root) = Error Crux.Root.Closed)

let test_post_commit_phase_order () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let opening_entered = Eta.Promise.create () in
  let release_opening = Eta.Promise.create () in
  let transition_started = ref false in
  let producer spec ~emit:_ =
    if spec = 0 then Eta.Effect.pure Eta.Effect.never
    else
      let open Eta.Syntax in
      let* _ = Eta.Promise.resolve opening_entered (Eta.Exit.Ok ()) in
      let* () = Eta.Promise.await release_opening in
      Eta.Effect.pure Eta.Effect.never
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some (Eta.Effect.sync (fun () -> transition_started := true)) ))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Int.equal)
      ~spec:(Crux.map machine ~f:fst)
      ~producer:(Crux.return producer)
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return Fun.id)
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> 0
          | Crux.Source.Failed (_ : string) -> 0))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both machine source)
  in
  let ((_, endpoint), _), initial_post =
    committed (run_ok (Crux.Root.advance root))
  in
  let start_effect post_commit =
    Crux.Post_commit.start post_commit
    |> Eta.Effect.or_die (function
         | Crux.Post_commit.Already_started ->
             Failure "post-commit token started twice")
  in
  ignore (run_runtime_ok runtime (start_effect initial_post));
  ignore
    (run_runtime_ok runtime
       (Crux.Endpoint.send endpoint 1
       |> Eta.Effect.or_die (function
            | Crux.Endpoint.Ingress_closed -> Failure "ingress closed")));
  let _, replacement_post = committed (run_ok (Crux.Root.advance root)) in
  let observer =
    let open Eta.Syntax in
    let* () = Eta.Promise.await opening_entered in
    let* () =
      Eta.Effect.sync_result (fun () ->
          if !transition_started then
            Error (Failure "transition started before source opening finished")
          else Ok ())
      |> Eta.Effect.or_die Fun.id
    in
    let+ _ = Eta.Promise.resolve release_opening (Eta.Exit.Ok ()) in
    ()
  in
  ignore
    (run_runtime_ok runtime
       (Eta.Effect.par (start_effect replacement_post) observer));
  let rec await_transition attempts =
    if !transition_started then ()
    else if attempts = 0 then Alcotest.fail "transition effect did not start"
    else (
      Eio.Fiber.yield ();
      await_transition (attempts - 1))
  in
  await_transition 100;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not stop"
  in
  ignore (run_runtime_ok runtime (start_effect stop_post))

let test_diagnostic_hook_failure () =
  let model_diagnostics = ref 0 in
  let action_diagnostics = ref 0 in
  let diagnostics =
    {
      Crux.Diagnostic.model =
        (fun model ->
          incr model_diagnostics;
          {
            Crux.Diagnostic.summary = Printf.sprintf "model=%d" model;
            fields = [];
          });
      action =
        (fun _action ->
          incr action_diagnostics;
          raise (Failure "action diagnostic failed"));
    }
  in
  let machine =
    Crux.State_machine.create ~diagnostics (Crux.return ())
      ~default_model:5
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        if action < 0 then raise Exit;
        (model + action, None))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1 machine
  in
  let (_, endpoint), initial_post = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_ok (Crux.Post_commit.start initial_post));
  Alcotest.(check int) "model hook is lazy" 0 !model_diagnostics;
  Alcotest.(check int) "action hook is lazy" 0 !action_diagnostics;
  ignore (run_ok (Crux.Endpoint.send endpoint 0));
  let _, successful_post = committed (run_ok (Crux.Root.advance root)) in
  ignore (run_ok (Crux.Post_commit.start successful_post));
  Alcotest.(check int) "successful transition did not diagnose model" 0
    !model_diagnostics;
  Alcotest.(check int) "successful transition did not diagnose action" 0
    !action_diagnostics;
  ignore (run_ok (Crux.Endpoint.send endpoint (-1)));
  let failure, failed_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { failure; post_commit }) ->
        (failure, post_commit)
    | _ -> Alcotest.fail "transition defect did not fail"
  in
  Alcotest.(check int) "model hook ran once" 1 !model_diagnostics;
  Alcotest.(check int) "action hook ran once" 1 !action_diagnostics;
  Alcotest.(check bool) "failed action snapshot is absent" true
    (Option.is_none failure.primary.action_snapshot);
  (match failure.primary.model_snapshot with
  | Some snapshot ->
      Alcotest.(check string) "committed model snapshot" "model=5"
        snapshot.summary
  | None -> Alcotest.fail "successful model diagnostic was absent");
  Alcotest.(check bool) "cell identity captured" true
    (Option.is_some failure.primary.cell);
  Alcotest.(check bool) "endpoint identity captured" true
    (Option.is_some failure.primary.endpoint);
  (match failure.secondary with
  | [ diagnostic_failure ] ->
      Alcotest.(check bool) "diagnostic failure origin" true
        (diagnostic_failure.origin = Crux.Failure.Crash_handler);
      Alcotest.(check bool) "diagnostic failure follows primary" true
        (Crux.Failure.Observation_position.compare
           failure.primary.position diagnostic_failure.position
        < 0)
  | _ -> Alcotest.fail "expected one secondary diagnostic failure");
  ignore (run_ok (Crux.Post_commit.start failed_post))

let test_self_disposing_effect () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let transition_effect_starts = ref 0 in
  let producer spec ~emit:_ =
    Eta.Effect.pure
      (if spec = 0 then Eta.Effect.unit else Eta.Effect.never)
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        ( action,
          Some
            (Eta.Effect.sync (fun () -> incr transition_effect_starts)) ))
  in
  let source =
    Crux.Source.create
      ~spec_cutoff:(Crux.Cutoff.of_equal Int.equal)
      ~spec:(Crux.map machine ~f:fst)
      ~producer:(Crux.return producer)
      ~target:(Crux.map machine ~f:snd)
      ~on_item:(Crux.return (fun (_ : int) -> 0))
      ~on_terminal:
        (Crux.return (function
          | Crux.Source.Completed -> 1
          | Crux.Source.Failed (_ : string) -> 2))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both machine source)
  in
  let _, initial_post = committed (run_ok (Crux.Root.advance root)) in
  let start post_commit =
    Crux.Post_commit.start post_commit
    |> Eta.Effect.or_die (function
         | Crux.Post_commit.Already_started ->
             Failure "post-commit token started twice")
    |> run_runtime_ok runtime
    |> ignore
  in
  start initial_post;
  let rec await_terminal attempts =
    if attempts = 0 then Alcotest.fail "source terminal action did not arrive"
    else
      match run_ok (Crux.Root.advance root) with
      | Ok
          (Crux.Root.Committed
            { output = ((model, _), _); post_commit }) ->
          (model, post_commit)
      | Ok Crux.Root.Idle ->
          Eio.Fiber.yield ();
          await_terminal (attempts - 1)
      | _ -> Alcotest.fail "unexpected source terminal outcome"
  in
  let model, terminal_post = await_terminal 100 in
  Alcotest.(check int) "terminal transition committed" 1 model;
  start terminal_post;
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check int) "disposed owner effect never started" 0
    !transition_effect_starts;
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not stop"
  in
  start stop_post

let test_export_callback_defect () =
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let target =
    Crux.map machine ~f:(fun (_, endpoint) ->
        Crux.Endpoint.contramap endpoint ~f:(fun (_ : int) ->
            raise (Failure "export mapper defect")))
  in
  let codec =
    Crux.Codec.make ~encode:(fun _ -> Ok (Bytes.empty))
      ~decode:(fun _ -> Ok 0)
  in
  let description =
    Crux.both machine
      (Crux.Exported_endpoint.create target ~codec)
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let _, export, initial_post =
    match committed (run_ok (Crux.Root.advance root)) with
    | ((_, _), export), post_commit ->
        ((), export, post_commit)
  in
  ignore (run_ok (Crux.Post_commit.start initial_post));
  let invoke () =
    match Crux.Exported_endpoint.try_invoke export 1 with
    | _ -> Alcotest.fail "export mapper defect was swallowed"
    | exception Failure _ -> ()
    | exception exn ->
        Alcotest.failf "unexpected mapper exception: %s"
          (Printexc.to_string exn)
  in
  invoke ();
  invoke ();
  let failure, crash_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Failed { failure; post_commit }) ->
        (failure, post_commit)
    | _ -> Alcotest.fail "export mapper defect did not latch root crash"
  in
  Alcotest.(check bool) "export dispatch origin" true
    (failure.primary.origin = Crux.Failure.Export_dispatch);
  Alcotest.(check bool) "local invocation trigger" true
    (failure.primary.trigger = Crux.Failure.Local_export_invocation);
  ignore (run_ok (Crux.Post_commit.start crash_post))

let observe_adapter_delivery_failure runtime =
  let lifecycle_started = ref false in
  let description =
    Crux.both (Crux.return 7)
      (Crux.lifecycle
         (Crux.return
            (Eta.Effect.sync (fun () -> lifecycle_started := true))))
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "expected committed output delivery"
  in
  let cause =
    Crux.Failure.Packed_cause.make
      ~pp_error:Format.pp_print_string
      (Eta.Cause.fail "adapter delivery failed")
  in
  Alcotest.(check bool) "failure answer accepted" true
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.failed delivery cause)
    = Ok ());
  Alcotest.(check bool) "ordinary work suppressed" false
    !lifecycle_started;
  let detected =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Crash_detected failure) -> failure
    | _ -> Alcotest.fail "crash was not detected before teardown"
  in
  Alcotest.(check bool) "ordinary work still suppressed" false
    !lifecycle_started;
  let settlement =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Closed (Crux.Driver.Crashed settlement)) ->
        settlement
    | _ -> Alcotest.fail "crash did not settle and close"
  in
  (detected, settlement, !lifecycle_started)

let test_adapter_delivery_failure () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let detected, settlement, lifecycle_started =
    observe_adapter_delivery_failure runtime
  in
  Alcotest.(check bool) "adapter origin" true
    (detected.primary.origin = Crux.Failure.Adapter_delivery);
  Alcotest.(check bool) "output-delivery trigger" true
    (detected.primary.trigger = Crux.Failure.Output_delivery);
  Alcotest.(check bool) "commit retained through teardown" false
    lifecycle_started;
  Alcotest.(check bool) "teardown settled" true
    settlement.teardown_settled

let test_crash_detection_and_settlement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let detected, settlement, _ =
    observe_adapter_delivery_failure runtime
  in
  Alcotest.(check int64) "same primary position"
    (Crux.Failure.Observation_position.to_int64
       detected.primary.position)
    (Crux.Failure.Observation_position.to_int64
       settlement.failure.primary.position);
  Alcotest.(check int) "same secondary count"
    (List.length detected.secondary)
    (List.length settlement.failure.secondary);
  Alcotest.(check bool) "complete settlement" true
    settlement.teardown_settled

let test_request_dispatch_fence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let int_codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let operation =
    Crux.Host_operation.define ~name:"test.dispatch-fence"
      ~request:int_codec ~response:int_codec
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack operation ]
  in
  let requester = Crux.Driver.Binding.requester binding operation in
  let response = ref None in
  let request_program =
    Crux.Requester.request requester 41
    |> Eta.Effect.map (fun value -> response := Some value)
    |> Eta.Effect.or_die (function
         | Crux.Requester.Ingress_closed -> Failure "ingress closed"
         | Crux.Requester.Encode_failed _ -> Failure "encode failed"
         | Crux.Requester.Decode_failed _ -> Failure "decode failed"
         | Crux.Requester.Dispatch_failed -> Failure "dispatch failed"
         | Crux.Requester.Closed _ -> Failure "request closed")
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return request_program))
  in
  let driver = Crux.Driver.create binding root in
  let initial =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "expected initial delivery"
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered initial));
  let rec await_request attempts =
    if attempts = 0 then Alcotest.fail "request was not dispatched"
    else
      match run_runtime_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Request event) -> event
      | Some _ | None ->
          Eio.Fiber.yield ();
          await_request (attempts - 1)
  in
  let event = await_request 100 in
  let host_work_finished = ref false in
  let resolve_response = ref None in
  let handled =
    run_runtime_ok runtime
      (Crux.Request.Driver_event.handle event operation
         ~f:(fun _request ~resolve ~on_cancel ->
           on_cancel (fun _ -> ());
           resolve_response := Some resolve;
           Eta.Effect.unit))
  in
  Alcotest.(check bool) "dispatch paths installed" true
    (handled = Crux.Request.Driver_event.Handled);
  Alcotest.(check bool) "dispatch accepted" true
    (run_runtime_ok runtime
       (Crux.Request.Driver_event.accepted event)
    = Ok ());
  Alcotest.(check bool) "host work need not be finished" false
    !host_work_finished;
  host_work_finished := true;
  let resolve =
    match !resolve_response with
    | Some resolve -> resolve
    | None -> Alcotest.fail "response path was not installed"
  in
  Alcotest.(check bool) "installed response path works" true
    (run_runtime_ok runtime (resolve 42) = Ok ());
  let rec await_response attempts =
    if !response = Some 42 then ()
    else if attempts = 0 then Alcotest.fail "request did not resolve"
    else (
      Eio.Fiber.yield ();
      await_response (attempts - 1))
  in
  await_response 100;
  Crux.Driver.request_stop driver;
  let rec await_closed attempts =
    if attempts = 0 then Alcotest.fail "driver did not close"
    else
      match run_runtime_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
      | Some _ | None ->
          Eio.Fiber.yield ();
          await_closed (attempts - 1)
  in
  await_closed 100

let test_stop_from_each_driver_phase () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let dormant_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 1)
  in
  let dormant_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) dormant_root
  in
  Crux.Driver.request_stop dormant_driver;
  (match run_runtime_ok runtime (Crux.Driver.poll dormant_driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "stop did not replace pending start");

  let pending_started = ref false in
  let pending_machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let pending_root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both pending_machine
         (Crux.lifecycle
            (Crux.return
               (Eta.Effect.sync (fun () ->
                    pending_started := true)))))
  in
  let pending_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) pending_root
  in
  let pending_delivery =
    match run_runtime_ok runtime (Crux.Driver.poll pending_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "pending-phase driver did not deliver"
  in
  let (pending_model, pending_endpoint), _ =
    Crux.Driver.Delivery.output pending_delivery
  in
  Alcotest.(check int) "pending output retained" 0 pending_model;
  ignore
    (run_runtime_ok runtime
       (Crux.Endpoint.send pending_endpoint 1
       |> Eta.Effect.or_die (function
            | Crux.Endpoint.Ingress_closed ->
                Failure "pending ingress closed")));
  Crux.Driver.request_stop pending_driver;
  Alcotest.(check bool) "pending delivery remains visible" true
    (run_runtime_ok runtime (Crux.Driver.poll pending_driver) = None);
  Alcotest.(check bool) "pending delivery answer accepted" true
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered pending_delivery)
    = Ok ());
  Alcotest.(check bool) "pending ordinary work replaced" false
    !pending_started;
  (match run_runtime_ok runtime (Crux.Driver.poll pending_driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "pending-delivery stop did not close");
  Alcotest.(check bool) "buffered action discarded" true
    (run_runtime_ok runtime
       (Eta.Effect.to_result
          (Crux.Endpoint.send pending_endpoint 1))
    = Error Crux.Endpoint.Ingress_closed);

  let active_started = ref false in
  let active_finalized = ref false in
  let active_program =
    Eta.Effect.bind
      (fun () -> Eta.Effect.never)
      (Eta.Effect.sync (fun () -> active_started := true))
    |> Eta.Effect.finally
         (Eta.Effect.sync (fun () -> active_finalized := true))
  in
  let active_machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let active_root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both active_machine
         (Crux.lifecycle (Crux.return active_program)))
  in
  let active_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) active_root
  in
  let active_delivery =
    match run_runtime_ok runtime (Crux.Driver.poll active_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "active-phase driver did not deliver"
  in
  let (_, active_endpoint), _ =
    Crux.Driver.Delivery.output active_delivery
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered active_delivery));
  let rec await_started attempts =
    if !active_started then ()
    else if attempts = 0 then Alcotest.fail "owned work did not start"
    else (
      Eio.Fiber.yield ();
      await_started (attempts - 1))
  in
  await_started 100;
  ignore
    (run_runtime_ok runtime
       (Crux.Endpoint.send active_endpoint 1
       |> Eta.Effect.or_die (function
            | Crux.Endpoint.Ingress_closed ->
                Failure "active ingress closed")));
  Crux.Driver.request_stop active_driver;
  (match run_runtime_ok runtime (Crux.Driver.poll active_driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "running-phase stop did not close");
  Alcotest.(check bool) "work tree settled before closed" true
    !active_finalized

type hosted_error =
  | Acquire_failed
  | Release_failed

let pp_hosted_error formatter = function
  | Acquire_failed ->
      Format.pp_print_string formatter "acquire failed"
  | Release_failed ->
      Format.pp_print_string formatter "release failed"

let hosted_root () =
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return ())
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  (root, driver)

let test_hosted_resource_boundary () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let acquire_root, acquire_driver = hosted_root () in
  let acquire_released = ref false in
  let acquire_adapter _control =
    Crux.Adapter.resource ~pp_error:pp_hosted_error
      ~acquire:(Eta.Effect.fail Acquire_failed)
      ~release:(fun () ->
        Eta.Effect.sync (fun () -> acquire_released := true))
      ~deliver:(fun () _ -> Eta.Effect.unit)
      ~request_event:(fun () _ -> Eta.Effect.unit)
      ~crash_detected:(fun () _ -> Eta.Effect.unit)
  in
  let acquire_exit =
    run_runtime_ok runtime
      (Eta.Effect.to_exit
         (Crux.Hosted.run acquire_driver
            ~adapter:acquire_adapter))
  in
  (match acquire_exit with
  | Eta.Exit.Error cause ->
      Alcotest.(check bool) "acquisition error stayed outside root" true
        (Eta.Cause.failures cause = [ Acquire_failed ])
  | Eta.Exit.Ok _ ->
      Alcotest.fail "hosted acquisition unexpectedly succeeded");
  Alcotest.(check bool) "unacquired resource was not released" false
    !acquire_released;
  Alcotest.(check bool) "acquisition failure settled root" true
    (run_ok (Crux.Root.advance acquire_root) = Error Crux.Root.Driver_attached);

  let release_root, release_driver = hosted_root () in
  let delivered = ref false in
  let released = ref false in
  let release_adapter control =
    Crux.Adapter.resource ~pp_error:pp_hosted_error
      ~acquire:(Eta.Effect.pure ())
      ~release:(fun () ->
        released := true;
        Eta.Effect.fail Release_failed)
      ~deliver:(fun () _ ->
        delivered := true;
        Crux.Hosted.Control.request_stop control;
        Eta.Effect.unit)
      ~request_event:(fun () _ -> Eta.Effect.unit)
      ~crash_detected:(fun () _ -> Eta.Effect.unit)
  in
  let release_exit =
    run_runtime_ok runtime
      (Eta.Effect.to_exit
         (Crux.Hosted.run release_driver
            ~adapter:release_adapter))
  in
  (match release_exit with
  | Eta.Exit.Error (Eta.Cause.Finalizer _) ->
      Alcotest.(check bool) "release error stayed outside root" true
        true
  | Eta.Exit.Error _ ->
      Alcotest.fail "release error escaped as a root/body failure"
  | Eta.Exit.Ok _ ->
      Alcotest.fail "hosted release unexpectedly succeeded");
  Alcotest.(check bool) "adapter received committed output" true !delivered;
  Alcotest.(check bool) "binding release ran" true !released;
  Alcotest.(check bool) "release failure left root settled" true
    (run_ok (Crux.Root.advance release_root) = Error Crux.Root.Driver_attached);

  let interrupt_root, interrupt_driver = hosted_root () in
  let delivery_entered = Eta.Promise.create () in
  let interrupt_released = ref false in
  let interrupt_adapter _control =
    Crux.Adapter.resource ~pp_error:pp_hosted_error
      ~acquire:(Eta.Effect.pure ())
      ~release:(fun () ->
        Eta.Effect.sync (fun () -> interrupt_released := true))
      ~deliver:(fun () _ ->
        let open Eta.Syntax in
        let* _ =
          Eta.Promise.resolve delivery_entered (Eta.Exit.Ok ())
        in
        Eta.Effect.never)
      ~request_event:(fun () _ -> Eta.Effect.unit)
      ~crash_detected:(fun () _ -> Eta.Effect.unit)
  in
  let hosted =
    Crux.Hosted.run interrupt_driver ~adapter:interrupt_adapter
    |> Eta.Effect.map (fun _ -> `Hosted_completed)
  in
  let interrupt =
    Eta.Promise.await delivery_entered
    |> Eta.Effect.map (fun () -> `Interrupted)
  in
  Alcotest.(check bool) "race interrupted hosted body" true
    (run_runtime_ok runtime (Eta.Effect.race [ hosted; interrupt ])
    = `Interrupted);
  Alcotest.(check bool) "interruption released binding after settlement" true
    !interrupt_released;
  Alcotest.(check bool) "interruption settled root" true
    (run_ok (Crux.Root.advance interrupt_root) = Error Crux.Root.Driver_attached)

let test_request_terminal_handoff_fence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let operation =
    Crux.Host_operation.define ~name:"test.terminal-handoff"
      ~request:codec ~response:codec
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack operation ]
  in
  let requester = Crux.Driver.Binding.requester binding operation in
  let program =
    Crux.Requester.request requester 1
    |> Eta.Effect.to_result
    |> Eta.Effect.map (fun _ -> ())
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return program))
  in
  let driver = Crux.Driver.create binding root in
  let initial =
    match run_runtime_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "terminal-handoff driver did not start"
  in
  ignore
    (run_runtime_ok runtime
       (Crux.Driver.Delivery.delivered initial));
  let rec await_request attempts =
    if attempts = 0 then Alcotest.fail "request was not dispatched"
    else
      match run_runtime_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Request event) -> event
      | Some _ | None ->
          Eio.Fiber.yield ();
          await_request (attempts - 1)
  in
  let event = await_request 100 in
  let handoffs = ref [] in
  ignore
    (run_runtime_ok runtime
       (Crux.Request.Driver_event.handle event operation
          ~f:(fun _ ~resolve:_ ~on_cancel ->
            on_cancel (fun reason ->
                handoffs := reason :: !handoffs);
            Eta.Effect.unit)));
  ignore
    (run_runtime_ok runtime
       (Crux.Request.Driver_event.accepted event));
  Crux.Driver.request_stop driver;
  (match run_runtime_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "root closed before terminal handoff settled");
  Alcotest.(check int) "one local terminal handoff" 1
    (List.length !handoffs);
  Alcotest.(check bool) "handoff has exact terminal reason" true
    (!handoffs = [ Crux.Request.Root_stopped ])

let test_request_export_closes_on_owner_and_root_termination () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let int_codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "expected integer" })
  in
  let string_codec =
    Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
      ~decode:(fun bytes -> Ok (Bytes.to_string bytes))
  in
  let run_case expected terminate =
    let machine =
      Crux.State_machine.create (Crux.return ())
        ~default_model:()
        ~apply_action:(fun ~self:_ ~input:() ~model:() ~action ->
          match action with
          | `Request
              ((_request : int),
               (_responder : string Crux.Responder.t)) ->
              ((), None)
          | `Crash ->
              ((), Some (Eta.Effect.die_message "request export crash")))
    in
    let selector =
      Crux.State_machine.create (Crux.return ())
        ~default_model:true
        ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
          (action, None))
    in
    let request_target =
      Crux.map machine ~f:(fun (_, endpoint) ->
          Crux.Endpoint.contramap endpoint ~f:(fun request ->
              `Request request))
    in
    let export =
      Crux.bind (Crux.map selector ~f:fst) ~f:(fun enabled ->
          if enabled then
            Crux.Request_export.create request_target
              ~request:int_codec ~response:string_codec
            |> Crux.map ~f:Option.some
          else Crux.return None)
    in
    let root =
      Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
        (Crux.both machine (Crux.both selector export))
    in
    let initial, post_commit = committed (run_ok (Crux.Root.advance root)) in
    ignore
      (run_runtime_ok runtime
         (Crux.Post_commit.start post_commit
         |> Eta.Effect.or_die (function
              | Crux.Post_commit.Already_started ->
                  Failure "post-commit token was already started")));
    let
      ( (_model, machine_endpoint),
        ((_selected, selector_endpoint), export) )
      =
      initial
    in
    let export =
      match export with
      | Some export -> export
      | None -> Alcotest.fail "request export was not created"
    in
    let pending =
      Eta_test.Async.fork_run switch runtime
        (Crux.Request_export.invoke export 7
        |> Eta.Effect.to_result
        |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
             ~on_timeout:`Timeout
        |> Eta.Effect.to_result)
    in
    for _ = 1 to 10 do
      Eio.Fiber.yield ()
    done;
    let _, request_post = committed (run_ok (Crux.Root.advance root)) in
    ignore
      (run_runtime_ok runtime
         (Crux.Post_commit.start request_post
         |> Eta.Effect.or_die (function
              | Crux.Post_commit.Already_started ->
                  Failure "post-commit token was already started")));
    terminate runtime root machine_endpoint selector_endpoint;
    for _ = 1 to 10 do
      Eio.Fiber.yield ()
    done;
    if not (Eio.Promise.is_resolved pending) then
      Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
    match Eta_test.Async.await pending |> Eta_test.Expect.expect_ok with
    | Ok (Error (Crux.Request_export.Closed reason)) ->
        Alcotest.(check bool) "exact request-export closure reason" true
          (reason = expected)
    | Ok (Ok _) ->
        Alcotest.fail "pending request export unexpectedly resolved"
    | Ok (Error _) ->
        Alcotest.fail "pending request export closed with wrong error"
    | Error `Timeout ->
        Alcotest.fail "pending request export was not closed"
  in
  run_case Crux.Request.Owner_disposed
    (fun runtime root _machine_endpoint selector_endpoint ->
      ignore
        (run_runtime_ok runtime
           (Crux.Endpoint.send selector_endpoint false
           |> Eta.Effect.or_die (function
                | Crux.Endpoint.Ingress_closed ->
                    Failure "selector ingress closed")));
      let _, post_commit = committed (run_ok (Crux.Root.advance root)) in
      ignore
        (run_runtime_ok runtime
           (Crux.Post_commit.start post_commit
           |> Eta.Effect.or_die (function
                | Crux.Post_commit.Already_started ->
                    Failure "post-commit token was already started"))));
  run_case Crux.Request.Root_stopped
    (fun runtime root _machine_endpoint _selector_endpoint ->
      Crux.Root.request_stop root;
      match run_ok (Crux.Root.advance root) with
      | Ok (Crux.Root.Stopped { post_commit }) ->
          ignore
            (run_runtime_ok runtime
               (Crux.Post_commit.start post_commit
               |> Eta.Effect.or_die (function
                    | Crux.Post_commit.Already_started ->
                        Failure
                          "post-commit token was already started")))
      | _ -> Alcotest.fail "request-export root did not stop");
  run_case Crux.Request.Root_crashed
    (fun runtime root machine_endpoint _selector_endpoint ->
      ignore
        (run_runtime_ok runtime
           (Crux.Endpoint.send machine_endpoint `Crash
           |> Eta.Effect.or_die (function
                | Crux.Endpoint.Ingress_closed ->
                    Failure "machine ingress closed")));
      let _, post_commit = committed (run_ok (Crux.Root.advance root)) in
      ignore
        (run_runtime_ok runtime
           (Crux.Post_commit.start post_commit
           |> Eta.Effect.or_die (function
                | Crux.Post_commit.Already_started ->
                    Failure "post-commit token was already started")));
      let rec settle attempts =
        if attempts = 0 then
          Alcotest.fail "request-export root did not crash"
        else
          match run_ok (Crux.Root.advance root) with
          | Ok (Crux.Root.Failed { post_commit; _ }) ->
              ignore
                (run_runtime_ok runtime
                   (Crux.Post_commit.start post_commit
                   |> Eta.Effect.or_die (function
                        | Crux.Post_commit.Already_started ->
                            Failure
                              "post-commit token was already started")))
          | Ok Crux.Root.Idle ->
              Eio.Fiber.yield ();
              settle (attempts - 1)
          | _ ->
              Alcotest.fail "unexpected request-export crash outcome"
      in
      settle 100)

let int_bytes_codec =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
    ~decode:(fun bytes ->
      match int_of_string_opt (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid integer" })

let unit_bytes_codec =
  Crux.Codec.make
    ~encode:(fun () -> Ok Bytes.empty)
    ~decode:(fun _ -> Ok ())

let rec stop_driver driver leftover =
  let open Eta.Syntax in
  if leftover = 0 then Eta.Effect.unit
  else
    let* event = Crux.Driver.poll driver in
    match event with
    | Some (Crux.Driver.Closed _) | None -> Eta.Effect.unit
    | Some (Crux.Driver.Deliver delivery) ->
        let* _ = Crux.Driver.Delivery.delivered delivery in
        stop_driver driver (leftover - 1)
    | Some _ -> stop_driver driver (leftover - 1)

let ack_output peer driver =
  let open Eta.Syntax in
  let rec await attempts =
    if attempts = 0 then
      Eta.Effect.sync (fun () -> Alcotest.fail "serialized output missing")
    else
      let* outgoing = Crux.Serialized_session.poll_outgoing peer in
      match outgoing with
      | Some bytes -> (
          match Eta_crux_json.Format.decode bytes with
          | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) ->
              let* () =
                Crux.Serialized_session.receive peer
                  (Eta_crux_json.Format.encode
                     (Crux.Wire.Frame.Output_result
                        { seq = 0l; reply_to = seq; result = `Accepted }))
                |> Eta.Effect.map (fun _ -> ())
              in
              let* _ = Crux.Driver.poll driver in
              Eta.Effect.unit
          | Ok (Crux.Wire.Frame.Request_dispatch _) ->
              Eta.Effect.sync (fun () ->
                  Alcotest.fail "unexpected request dispatch frame")
          | Ok _ | Error _ ->
              let* _ = Crux.Driver.poll driver in
              let* () = Eta.Effect.yield in
              await (attempts - 1))
      | None ->
          let* _ = Crux.Driver.poll driver in
          let* () = Eta.Effect.yield in
          await (attempts - 1)
  in
  await 100

let test_requester_encode_failed () =
  let clock = Eta_test.Test_clock.create () in
  let encode_calls = ref 0 in
  let request_codec =
    Crux.Codec.make
      ~encode:(fun _value ->
        incr encode_calls;
        Error { Crux.Codec.message = "outbound encode refused" })
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let operation =
    Crux.Host_operation.define ~name:"test.encode-failed"
      ~request:request_codec ~response:int_bytes_codec
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_bytes_codec
      ~operations:[ Crux.Host_operation.Pack operation ]
      ~session:candidate
  in
  let requester = Crux.Driver.Binding.requester binding operation in
  let first = ref None in
  let second = ref None in
  let seen_request_event = ref false in
  let program =
    let open Eta.Syntax in
    let request value cell =
      Crux.Requester.request requester value
      |> Eta.Effect.to_result
      |> Eta.Effect.map (fun result -> cell := Some result)
    in
    let description =
      Crux.lifecycle
        (Crux.return
           (let* () = request 1 first in
            request 1 second))
    in
    let root =
      Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
    in
    let driver = Crux.Driver.create binding root in
    let rec note_events leftover =
      if leftover = 0 then Eta.Effect.unit
      else
        let* event = Crux.Driver.poll driver in
        match event with
        | Some (Crux.Driver.Request _) ->
            seen_request_event := true;
            note_events (leftover - 1)
        | Some (Crux.Driver.Deliver delivery) ->
            let* _ = Crux.Driver.Delivery.delivered delivery in
            note_events (leftover - 1)
        | Some _ | None -> Eta.Effect.unit
    in
    let rec await_results attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "encode-failed scenario did not finish")
      else if Option.is_some !first && Option.is_some !second then
        Eta.Effect.unit
      else
        let* () = note_events 4 in
        let* () = Eta.Effect.yield in
        await_results (attempts - 1)
    in
    let* () = note_events 4 in
    let* () = ack_output peer driver in
    let* () = await_results 100 in
    let rec assert_no_dispatch leftover =
      if leftover = 0 then Eta.Effect.unit
      else
        let* outgoing = Crux.Serialized_session.poll_outgoing peer in
        match outgoing with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok (Crux.Wire.Frame.Request_dispatch _) ->
                Eta.Effect.sync (fun () ->
                    Alcotest.fail "encode failure wrote a request frame")
            | Ok _ | Error _ -> assert_no_dispatch (leftover - 1))
        | None -> Eta.Effect.unit
    in
    let* () = assert_no_dispatch 8 in
    Crux.Driver.request_stop driver;
    stop_driver driver 20
  in
  let outcome = Eta_test.Run.run ~clock program in
  ignore (Eta_test.Expect.expect_ok outcome.exit);
  (match !first with
  | Some
      (Error
        (Crux.Requester.Encode_failed { message = "outbound encode refused" })) ->
      ()
  | Some other ->
      Alcotest.failf "expected Encode_failed, got %s"
        (match other with
        | Ok _ -> "Ok"
        | Error Crux.Requester.Ingress_closed -> "Ingress_closed"
        | Error (Crux.Requester.Encode_failed _) -> "other Encode_failed"
        | Error (Crux.Requester.Decode_failed _) -> "Decode_failed"
        | Error Crux.Requester.Dispatch_failed -> "Dispatch_failed"
        | Error (Crux.Requester.Closed _) -> "Closed")
  | None -> Alcotest.fail "first request did not finish");
  (match !second with
  | Some
      (Error
        (Crux.Requester.Encode_failed { message = "outbound encode refused" })) ->
      ()
  | Some _ -> Alcotest.fail "second request did not return Encode_failed"
  | None -> Alcotest.fail "second request did not start");
  Alcotest.(check int) "encode ran before allocation" 2 !encode_calls;
  Alcotest.(check bool) "no request driver event" false !seen_request_event;
  Eta_test.Run.expect_no_pending_fibers outcome

let test_requester_decode_failed () =
  let clock = Eta_test.Test_clock.create () in
  let operation =
    Crux.Host_operation.define ~name:"test.decode-failed"
      ~request:int_bytes_codec ~response:int_bytes_codec
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:2048
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_bytes_codec
      ~operations:[ Crux.Host_operation.Pack operation ]
      ~session:candidate
  in
  let requester = Crux.Driver.Binding.requester binding operation in
  let request_result = ref None in
  let program =
    let open Eta.Syntax in
    let root =
      Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
        (Crux.lifecycle
           (Crux.return
              (Crux.Requester.request requester 7
              |> Eta.Effect.to_result
              |> Eta.Effect.map (fun result ->
                     request_result := Some result))))
    in
    let driver = Crux.Driver.create binding root in
    let rec await_dispatch attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "decode-failed dispatch missing")
      else
        let* outgoing = Crux.Serialized_session.poll_outgoing peer in
        match outgoing with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) ->
                let* () =
                  Crux.Serialized_session.receive peer
                    (Eta_crux_json.Format.encode
                       (Crux.Wire.Frame.Output_result
                          {
                            seq = 0l;
                            reply_to = seq;
                            result = `Accepted;
                          }))
                  |> Eta.Effect.map (fun _ -> ())
                in
                let* _ = Crux.Driver.poll driver in
                await_dispatch (attempts - 1)
            | Ok
                (Crux.Wire.Frame.Request_dispatch
                  { seq; request; _ }) ->
                Eta.Effect.pure (seq, request)
            | Ok _ | Error _ ->
                Eta.Effect.sync (fun () ->
                    Alcotest.fail "decode-failed unexpected frame"))
        | None ->
            let* _ = Crux.Driver.poll driver in
            let* () = Eta.Effect.yield in
            await_dispatch (attempts - 1)
    in
    let* dispatch_sequence, request = await_dispatch 100 in
    let* () =
      Crux.Serialized_session.receive peer
        (Eta_crux_json.Format.encode
           (Crux.Wire.Frame.Request_dispatch_result
              {
                seq = 1l;
                reply_to = dispatch_sequence;
                accepted = true;
              }))
      |> Eta.Effect.map (fun _ -> ())
    in
    let* _ = Crux.Driver.poll driver in
    let* () =
      Crux.Serialized_session.receive peer
        (Eta_crux_json.Format.encode
           (Crux.Wire.Frame.Request_resolved
              {
                seq = 2l;
                request;
                payload = Bytes.of_string "not-an-int";
              }))
      |> Eta.Effect.map (fun _ -> ())
    in
    let* _ = Crux.Driver.poll driver in
    let rec await_result attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "decode-failed request did not finish")
      else if Option.is_some !request_result then Eta.Effect.unit
      else
        let* _ = Crux.Driver.poll driver in
        let* () = Eta.Effect.yield in
        await_result (attempts - 1)
    in
    let* () = await_result 100 in
    let* still_open = Crux.Serialized_session.poll_outgoing peer in
    (match still_open with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Crash_notify _) ->
            Alcotest.fail "decode error closed the session"
        | Ok _ | Error _ -> ())
    | None -> ());
    Crux.Driver.request_stop driver;
    let rec close leftover =
      if leftover = 0 then Eta.Effect.unit
      else
        let* event = Crux.Driver.poll driver in
        match event with
        | Some (Crux.Driver.Closed _) | None -> Eta.Effect.unit
        | Some (Crux.Driver.Deliver delivery) ->
            let* _ = Crux.Driver.Delivery.delivered delivery in
            close (leftover - 1)
        | Some _ -> close (leftover - 1)
    in
    close 20
  in
  let outcome = Eta_test.Run.run ~clock program in
  ignore (Eta_test.Expect.expect_ok outcome.exit);
  (match !request_result with
  | Some (Error (Crux.Requester.Decode_failed { message = "invalid integer" }))
    ->
      ()
  | Some (Error (Crux.Requester.Decode_failed _)) -> ()
  | Some (Error (Crux.Requester.Closed Crux.Request.Session_closed)) ->
      Alcotest.fail "decode error closed the request as Session_closed"
  | Some _ -> Alcotest.fail "expected Decode_failed, got unexpected result"
  | None -> Alcotest.fail "decode-failed request missing");
  Eta_test.Run.expect_no_pending_fibers outcome

let test_responder_encode_failed () =
  let clock = Eta_test.Test_clock.create () in
  let fail_encode = ref true in
  let captured = ref None in
  let response_codec =
    Crux.Codec.make
      ~encode:(fun value ->
        if !fail_encode then
          Error { Crux.Codec.message = "inbound encode refused" }
        else Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        match int_of_string_opt (Bytes.to_string bytes) with
        | Some value -> Ok value
        | None -> Error { Crux.Codec.message = "invalid integer" })
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:
        (fun ~self:_ ~input:() ~model:_
             ~action:(request, responder) ->
          captured := Some responder;
          (request, None))
  in
  let export =
    Crux.Request_export.create (Crux.map machine ~f:snd)
      ~request:int_bytes_codec ~response:response_codec
  in
  let output_codec =
    Crux.Codec.make
      ~encode:(fun export -> Ok (Crux.Request_export.remote_handle export))
      ~decode:(fun _ ->
        Error
          { Crux.Codec.message = "request export output is encode-only" })
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:output_codec ~operations:[]
      ~session:candidate
  in
  let program =
    let open Eta.Syntax in
    let root =
      Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 export
    in
    let driver = Crux.Driver.create binding root in
    let rec await_output attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "responder encode output missing")
      else
        let* outgoing = Crux.Serialized_session.poll_outgoing peer in
        match outgoing with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok (Crux.Wire.Frame.Output_deliver { seq; output; _ }) ->
                Eta.Effect.pure (seq, output)
            | Ok _ | Error _ ->
                Eta.Effect.sync (fun () ->
                    Alcotest.fail "responder encode output malformed"))
        | None ->
            let* _ = Crux.Driver.poll driver in
            let* () = Eta.Effect.yield in
            await_output (attempts - 1)
    in
    let* initial_sequence, handle = await_output 100 in
    let* () =
      Crux.Serialized_session.receive peer
        (Eta_crux_json.Format.encode
           (Crux.Wire.Frame.Output_result
              {
                seq = 0l;
                reply_to = initial_sequence;
                result = `Accepted;
              }))
      |> Eta.Effect.map (fun _ -> ())
    in
    let* _ = Crux.Driver.poll driver in
    let start_payload =
      match Crux.Codec.encode int_bytes_codec 21 with
      | Ok payload -> payload
      | Error _ -> Alcotest.fail "request payload encode failed"
    in
    let* () =
      Crux.Serialized_session.receive peer
        (Eta_crux_json.Format.encode
           (Crux.Wire.Frame.Request_start
              { seq = 1l; handle; payload = start_payload }))
      |> Eta.Effect.map (fun _ -> ())
    in
    let* _ = Crux.Driver.poll driver in
    let rec await_started attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "request export did not start")
      else
        let* outgoing = Crux.Serialized_session.poll_outgoing peer in
        match outgoing with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok
                (Crux.Wire.Frame.Request_start_result
                  { result = `Started _; _ }) ->
                Eta.Effect.unit
            | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) ->
                let* () =
                  Crux.Serialized_session.receive peer
                    (Eta_crux_json.Format.encode
                       (Crux.Wire.Frame.Output_result
                          {
                            seq = Int32.add seq 10l;
                            reply_to = seq;
                            result = `Accepted;
                          }))
                  |> Eta.Effect.map (fun _ -> ())
                in
                let* _ = Crux.Driver.poll driver in
                await_started (attempts - 1)
            | Ok _ | Error _ ->
                Eta.Effect.sync (fun () ->
                    Alcotest.fail "request export start malformed"))
        | None ->
            let* _ = Crux.Driver.poll driver in
            let* () = Eta.Effect.yield in
            await_started (attempts - 1)
    in
    let* () = await_started 100 in
    let rec await_responder attempts =
      if attempts = 0 then
        Eta.Effect.sync (fun () ->
            Alcotest.fail "responder was not captured")
      else
        match !captured with
        | Some responder -> Eta.Effect.pure responder
        | None ->
            let* _ = Crux.Driver.poll driver in
            let* () = Eta.Effect.yield in
            await_responder (attempts - 1)
    in
    let* responder = await_responder 100 in
    let* first = Crux.Responder.resolve responder 42 |> Eta.Effect.to_result in
    let* outgoing_after_fail = Crux.Serialized_session.poll_outgoing peer in
    (match outgoing_after_fail with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Request_resolve _) ->
            Alcotest.fail "failed response encode wrote a resolve frame"
        | Ok _ | Error _ -> ())
    | None -> ());
    fail_encode := false;
    let* second = Crux.Responder.resolve responder 42 |> Eta.Effect.to_result in
    let rec ack_resolve leftover =
      if leftover = 0 then Eta.Effect.unit
      else
        let* outgoing = Crux.Serialized_session.poll_outgoing peer in
        match outgoing with
        | Some bytes -> (
            match Eta_crux_json.Format.decode bytes with
            | Ok (Crux.Wire.Frame.Request_resolve { seq; _ }) ->
                Crux.Serialized_session.receive peer
                  (Eta_crux_json.Format.encode
                     (Crux.Wire.Frame.Request_resolve_result
                        {
                          seq = Int32.add seq 1l;
                          reply_to = seq;
                          result = `Identity `Accepted;
                        }))
                |> Eta.Effect.map (fun _ -> ())
            | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) ->
                let* () =
                  Crux.Serialized_session.receive peer
                    (Eta_crux_json.Format.encode
                       (Crux.Wire.Frame.Output_result
                          {
                            seq = Int32.add seq 20l;
                            reply_to = seq;
                            result = `Accepted;
                          }))
                  |> Eta.Effect.map (fun _ -> ())
                in
                let* _ = Crux.Driver.poll driver in
                ack_resolve (leftover - 1)
            | Ok _ | Error _ -> ack_resolve (leftover - 1))
        | None ->
            let* _ = Crux.Driver.poll driver in
            let* () = Eta.Effect.yield in
            ack_resolve (leftover - 1)
    in
    let* () = ack_resolve 100 in
    Crux.Driver.request_stop driver;
    let* () = stop_driver driver 20 in
    Eta.Effect.pure (first, second)
  in
  let outcome = Eta_test.Run.run ~clock program in
  let first, second = Eta_test.Expect.expect_ok outcome.exit in
  (match first with
  | Error
      (Crux.Responder.Encode_failed { message = "inbound encode refused" }) ->
      ()
  | Error Crux.Responder.Not_pending ->
      Alcotest.fail "encode failure consumed the pending request"
  | Error (Crux.Responder.Encode_failed _) -> ()
  | Ok () -> Alcotest.fail "failing response encode succeeded");
  (match second with
  | Ok () -> ()
  | Error Crux.Responder.Not_pending ->
      Alcotest.fail "request was not pending for the retry"
  | Error (Crux.Responder.Encode_failed _) ->
      Alcotest.fail "retry encode failed");
  Eta_test.Run.expect_no_pending_fibers outcome

let () =
  Alcotest.run "eta_crux core"
    [
      ( "core",
        [
          Alcotest.test_case "description is inert" `Quick
            test_description_is_inert;
          Alcotest.test_case "roots are isolated" `Quick
            test_roots_are_isolated;
          Alcotest.test_case "endpoint acceptance boundary" `Quick
            test_endpoint_acceptance_boundary;
          Alcotest.test_case "transition effect is staged" `Quick
            test_transition_effect_is_staged;
          Alcotest.test_case "driver delivery fence" `Quick
            test_driver_delivers_before_post_commit;
          Alcotest.test_case "outbound request round trip" `Quick
            test_outbound_request_round_trip;
          Alcotest.test_case "requester rejects name collision" `Quick
            test_requester_rejects_name_collision;
          Alcotest.test_case "cutoff boundary" `Quick
            test_cutoff_suppresses_only_dependent_recomputation;
          Alcotest.test_case "post commit exactly once" `Quick
            test_post_commit_starts_exactly_once;
          Alcotest.test_case "idle is inert" `Quick test_idle_is_inert;
          Alcotest.test_case "transition rollback" `Quick
            test_transition_rollback;
          Alcotest.test_case "stale endpoint rejection" `Quick
            test_stale_endpoint_rejection;
          Alcotest.test_case "lifecycle resource cleanup" `Quick
            test_lifecycle_resource_cleanup;
          Alcotest.test_case "structural scope settlement" `Quick
            test_structural_scope_settlement;
          Alcotest.test_case "cleanup overlap" `Quick
            test_cleanup_overlap;
          Alcotest.test_case "concurrent source opening" `Quick
            test_concurrent_source_opening;
          Alcotest.test_case "source opening barrier" `Quick
            test_source_opening_barrier;
          Alcotest.test_case "source argument work starts once" `Quick
            test_source_argument_work_starts_once;
          Alcotest.test_case "crash latch" `Quick test_crash_latch;
          Alcotest.test_case "driver await wakes on fatal" `Quick
            test_driver_await_wakes_on_fatal;
          Alcotest.test_case "cleanup failure precedence" `Quick
            test_cleanup_failure_precedence;
          Alcotest.test_case "source opening defect" `Quick
            test_source_opening_defect;
          Alcotest.test_case "source opening failures admit terminals" `Quick
            test_source_opening_failures_do_not_block_admission;
          Alcotest.test_case "stop cancels source opening" `Quick
            test_stop_cancels_source_opening;
          Alcotest.test_case "post commit phase order" `Quick
            test_post_commit_phase_order;
          Alcotest.test_case "diagnostic hook failure" `Quick
            test_diagnostic_hook_failure;
          Alcotest.test_case "self disposing effect" `Quick
            test_self_disposing_effect;
          Alcotest.test_case "export callback defect" `Quick
            test_export_callback_defect;
          Alcotest.test_case "adapter delivery failure" `Quick
            test_adapter_delivery_failure;
          Alcotest.test_case "crash detection and settlement" `Quick
            test_crash_detection_and_settlement;
          Alcotest.test_case "request dispatch fence" `Quick
            test_request_dispatch_fence;
          Alcotest.test_case "stop from each driver phase" `Quick
            test_stop_from_each_driver_phase;
          Alcotest.test_case "hosted resource boundary" `Quick
            test_hosted_resource_boundary;
          Alcotest.test_case "request terminal handoff fence" `Quick
            test_request_terminal_handoff_fence;
          Alcotest.test_case "request export terminal closure" `Quick
            test_request_export_closes_on_owner_and_root_termination;
          Alcotest.test_case "requester encode failed" `Quick
            test_requester_encode_failed;
          Alcotest.test_case "requester decode failed" `Quick
            test_requester_decode_failed;
          Alcotest.test_case "responder encode failed" `Quick
            test_responder_encode_failed;
        ] );
    ]
