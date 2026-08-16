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

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let deliver runtime witness = function
  | Some (Crux.Driver.Deliver delivery) ->
      let output = output_of_delivery witness delivery in
      let completion =
        run_ok runtime (Crux.Driver.Delivery.delivered delivery)
      in
      Alcotest.(check bool) "delivery accepted" true
        (completion = Ok ());
      output
  | _ -> Alcotest.fail "expected projection delivery"

let test_graph_time_shared_sample_and_due_coalescing () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let description =
    let open Crux.Syntax in
    let+ now = Crux.Time.now ~every:(Eta.Duration.ms 10)
    and+ due = Crux.Time.after (Eta.Duration.ms 10)
    and+ ticks = Crux.Time.interval (Eta.Duration.ms 10) in
    (Crux.Time.to_ms now, due, ticks)
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let initial =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (triple int bool int)) "initial shared sample"
    (0, false, 0) initial;
  Eta_test.Test_clock.advance_to clock 25;
  let caught_up =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (triple int bool int)) "coalesced due sample"
    (25, true, 2) caught_up;
  Alcotest.(check bool) "one due commit" true
    (run_ok runtime (Crux.Driver.poll driver) = None);
  Eta_test.Test_clock.advance_to clock 30;
  let next =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (triple int bool int)) "activation-aligned cadence"
    (30, true, 3) next

let test_driver_attachment_fence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 7)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  Alcotest.(check (option int)) "no commit yet" None
    (latest_committed_snapshot witness driver);
  (match run_ok runtime (Crux.Root.advance root) with
  | Error Crux.Root.Driver_attached -> ()
  | _ -> Alcotest.fail "direct advance crossed driver fence");
  let output =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check int) "delivery output" 7 output;
  Alcotest.(check (option int)) "published before delivery" (Some 7)
    (latest_committed_snapshot witness driver)

let test_pull_does_not_complete_delivery () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 11)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None -> Alcotest.fail "expected delivery"
  in
  Alcotest.(check (option int)) "pull sees commit" (Some 11)
    (latest_committed_snapshot witness driver);
  Alcotest.(check bool) "pull left delivery incomplete" true
    (run_ok runtime (Crux.Driver.poll driver) = None);
  Alcotest.(check bool) "delivery token still accepted" true
    (run_ok runtime (Crux.Driver.Delivery.delivered delivery)
    = Ok ())

let test_driver_await_wakes_at_graph_deadline () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.after (Eta.Duration.ms 10))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  ignore
    (deliver runtime witness
       (run_ok runtime (Crux.Driver.poll driver)));
  let waiting =
    Eta_test.Async.fork_run switch runtime (Crux.Driver.await driver)
  in
  let rec wait_for_sleeper attempts =
    if Eta_test.Test_clock.sleeper_count clock = 1 then ()
    else if attempts = 0 then ()
    else (
      Eio.Fiber.yield ();
      wait_for_sleeper (attempts - 1))
  in
  wait_for_sleeper 20;
  Alcotest.(check int) "one deadline sleeper" 1
    (Eta_test.Test_clock.sleeper_count clock);
  Eta_test.Test_clock.advance_to clock 10;
  let event =
    Eta_test.Async.await waiting |> Eta_test.Expect.expect_ok
  in
  let output = deliver runtime witness (Some event) in
  Alcotest.(check bool) "deadline became due" true output

let test_graph_time_runtime_mismatch () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let root, _witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.interval (Eta.Duration.ms 1))
  in
  let initial = run_ok runtime (Crux.Root.advance root) in
  let post_commit =
    match initial with
    | Ok (Crux.Root.Committed committed) -> committed.post_commit
    | _ -> Alcotest.fail "initial time commit failed"
  in
  ignore
    (run_ok runtime
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
              Invalid_argument "post-commit already started")));
  let other_clock = Eta_test.Test_clock.create () in
  let mismatched =
    Crux.Root.advance root
    |> Eta.Effect.with_clock
         (Eta_test.Test_clock.as_capability other_clock)
    |> run_ok runtime
  in
  match mismatched with
  | Ok (Crux.Root.Failed { failure; _ }) ->
      Alcotest.(check bool) "graph clock origin" true
        (failure.Crux.Failure.primary.origin = Crux.Failure.Graph_clock);
      Alcotest.(check bool) "clock sample trigger" true
        (failure.Crux.Failure.primary.trigger = Crux.Failure.Clock_sample)
  | _ -> Alcotest.fail "clock mismatch did not fail the root"

let test_due_advancement_preserves_queued_ingress () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      (Crux.both machine
         (Crux.Time.after (Eta.Duration.ms 10)))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let (model, endpoint), due =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (pair int bool)) "initial output" (0, false)
    (model, due);
  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint 1
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")));
  Eta_test.Test_clock.advance_to clock 10;
  let (model, _), due =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (pair int bool)) "clock due won priority"
    (0, true) (model, due);
  let (model, _), due =
    deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))
  in
  Alcotest.(check (pair int bool)) "queued action remained"
    (1, true) (model, due)

let test_clock_regression_is_structured_failure () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.after (Eta.Duration.ms 10))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  ignore
    (deliver runtime witness
       (run_ok runtime (Crux.Driver.poll driver)));
  Eta_test.Test_clock.advance_to clock 5;
  Alcotest.(check bool) "sampled movement stayed idle" true
    (run_ok runtime (Crux.Driver.poll driver) = None);
  Eta_test.Test_clock.set_time clock 3;
  match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Crash_detected failure) ->
      Alcotest.(check bool) "regression origin" true
        (failure.Crux.Failure.primary.origin = Crux.Failure.Graph_clock);
      Alcotest.(check bool) "regression trigger" true
        (failure.Crux.Failure.primary.trigger = Crux.Failure.Clock_sample)
  | _ -> Alcotest.fail "clock regression did not fail the root"

let test_graph_time_static_validation () =
  let rejects f =
    try
      ignore (f ());
      false
    with Invalid_argument _ -> true
  in
  Alcotest.(check bool) "now rejects zero" true
    (rejects (fun () -> Crux.Time.now ~every:Eta.Duration.zero));
  Alcotest.(check bool) "after rejects zero" true
    (rejects (fun () -> Crux.Time.after Eta.Duration.zero));
  Alcotest.(check bool) "interval rejects zero" true
    (rejects (fun () -> Crux.Time.interval Eta.Duration.zero))

let now_token runtime clock ~at_ms =
  Eta_test.Test_clock.advance_to clock at_ms;
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.now ~every:(Eta.Duration.ms 1))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  deliver runtime witness (run_ok runtime (Crux.Driver.poll driver))

let test_graph_time_dynamic_failures () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  (* GTC-19: every clock read compares against the last successful read.
     Mismatch, regression, internal overflow, and a past dynamic deadline
     each terminally fail the root. *)
  let mismatched_root, _mismatched_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.interval (Eta.Duration.ms 1))
  in
  ignore
    (match run_ok runtime (Crux.Root.advance mismatched_root) with
    | Ok (Crux.Root.Committed committed) ->
        ignore
          (run_ok runtime
             (Crux.Post_commit.start committed.post_commit
             |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
                    Invalid_argument "post-commit already started")))
    | _ -> Alcotest.fail "mismatch setup commit failed");
  let other_clock = Eta_test.Test_clock.create () in
  (match
     Crux.Root.advance mismatched_root
     |> Eta.Effect.with_clock
          (Eta_test.Test_clock.as_capability other_clock)
     |> run_ok runtime
   with
  | Ok (Crux.Root.Failed _) -> ()
  | _ -> Alcotest.fail "clock mismatch did not fail the root");
  let regressed_root, _regressed_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.after (Eta.Duration.ms 10))
  in
  ignore
    (match run_ok runtime (Crux.Root.advance regressed_root) with
    | Ok (Crux.Root.Committed committed) ->
        ignore
          (run_ok runtime
             (Crux.Post_commit.start committed.post_commit
             |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
                    Invalid_argument "post-commit already started")))
    | _ -> Alcotest.fail "regression setup commit failed");
  Eta_test.Test_clock.advance_to clock 5;
  (match run_ok runtime (Crux.Root.advance regressed_root) with
  | Ok Crux.Root.Idle -> ()
  | _ -> Alcotest.fail "forward movement did not stay idle");
  Eta_test.Test_clock.set_time clock 3;
  (match run_ok runtime (Crux.Root.advance regressed_root) with
  | Ok (Crux.Root.Failed _) -> ()
  | _ -> Alcotest.fail "clock regression did not fail the root");
  let overflow_root, overflow_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.interval (Eta.Duration.ms 10))
  in
  let overflow_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) overflow_root
  in
  Eta_test.Test_clock.set_time clock 0;
  ignore
    (deliver runtime overflow_witness
       (run_ok runtime (Crux.Driver.poll overflow_driver)));
  Eta_test.Test_clock.advance_to clock (max_int - 1);
  (match run_ok runtime (Crux.Driver.poll overflow_driver) with
  | Some (Crux.Driver.Crash_detected _) -> ()
  | _ -> Alcotest.fail "deadline overflow did not fail the root");
  Eta_test.Test_clock.set_time clock 0;
  let token = now_token runtime clock ~at_ms:10 in
  let target =
    match Crux.Time.add token (Eta.Duration.ms 10) with
    | Ok target -> target
    | Error _ -> Alcotest.fail "valid time addition failed"
  in
  Eta_test.Test_clock.advance_to clock 100;
  let past_root, _past_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.deadline target)
  in
  match run_ok runtime (Crux.Root.advance past_root) with
  | Ok (Crux.Root.Failed _) -> ()
  | _ -> Alcotest.fail "past dynamic deadline did not fail the root"

let test_graph_time_failure_attribution () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  (* GTC-20: mismatch and regression use Graph_clock with Clock_sample.
     Timer faults preserve the event trigger; due-time faults use
     Clock_due. *)
  let check_attribution label (failure : Crux.Failure.t) ~origin
      ~trigger =
    Alcotest.(check bool) (label ^ " origin") true
      (failure.Crux.Failure.primary.origin = origin);
    Alcotest.(check bool) (label ^ " trigger") true
      (failure.Crux.Failure.primary.trigger = trigger)
  in
  let mismatched_root, _mismatched_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.interval (Eta.Duration.ms 1))
  in
  ignore
    (match run_ok runtime (Crux.Root.advance mismatched_root) with
    | Ok (Crux.Root.Committed committed) ->
        ignore
          (run_ok runtime
             (Crux.Post_commit.start committed.post_commit
             |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
                    Invalid_argument "post-commit already started")))
    | _ -> Alcotest.fail "mismatch setup commit failed");
  let other_clock = Eta_test.Test_clock.create () in
  (match
     Crux.Root.advance mismatched_root
     |> Eta.Effect.with_clock
          (Eta_test.Test_clock.as_capability other_clock)
     |> run_ok runtime
   with
  | Ok (Crux.Root.Failed { failure; _ }) ->
      check_attribution "mismatch" failure
        ~origin:Crux.Failure.Graph_clock
        ~trigger:Crux.Failure.Clock_sample
  | _ -> Alcotest.fail "clock mismatch did not fail the root");
  let overflow_root, overflow_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.interval (Eta.Duration.ms 10))
  in
  let overflow_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) overflow_root
  in
  ignore
    (deliver runtime overflow_witness
       (run_ok runtime (Crux.Driver.poll overflow_driver)));
  Eta_test.Test_clock.advance_to clock (max_int - 1);
  (match run_ok runtime (Crux.Driver.poll overflow_driver) with
  | Some (Crux.Driver.Crash_detected failure) ->
      check_attribution "due overflow" failure
        ~origin:Crux.Failure.Transition
        ~trigger:Crux.Failure.Clock_due
  | _ -> Alcotest.fail "deadline overflow did not fail the root");
  Eta_test.Test_clock.set_time clock 0;
  let token = now_token runtime clock ~at_ms:10 in
  let target =
    match Crux.Time.add token (Eta.Duration.ms 10) with
    | Ok target -> target
    | Error _ -> Alcotest.fail "valid time addition failed"
  in
  Eta_test.Test_clock.advance_to clock 100;
  let past_root, _past_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.deadline target)
  in
  match run_ok runtime (Crux.Root.advance past_root) with
  | Ok (Crux.Root.Failed { failure; _ }) ->
      check_attribution "activation timer fault" failure
        ~origin:Crux.Failure.Transition
        ~trigger:Crux.Failure.Initial_start
  | _ -> Alcotest.fail "past dynamic deadline did not fail the root"

let test_graph_time_no_fallback () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  (* GTC-21: no clamping, no ignored timers, no clock switches, and no wall
     time. A past or foreign timestamp fails; arithmetic reports its typed
     error. *)
  let token = now_token runtime clock ~at_ms:10 in
  Alcotest.(check bool) "negative delta is a typed error" true
    (Crux.Time.add token (Eta.Duration.ms (-1))
     = Error `Past_deadline);
  let late_token = now_token runtime clock ~at_ms:(max_int - 1) in
  Alcotest.(check bool) "overflow is a typed error" true
    (Crux.Time.add late_token (Eta.Duration.ms 10)
     = Error `Deadline_overflow);
  let target =
    match Crux.Time.add token (Eta.Duration.ms 10) with
    | Ok target -> target
    | Error _ -> Alcotest.fail "valid time addition failed"
  in
  Eta_test.Test_clock.set_time clock 100;
  let past_root, _past_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.deadline target)
  in
  (match run_ok runtime (Crux.Root.advance past_root) with
  | Ok (Crux.Root.Failed _) -> ()
  | _ -> Alcotest.fail "past deadline was clamped instead of failing");
  let foreign_clock = Eta_test.Test_clock.create () in
  let foreign_root, foreign_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.now ~every:(Eta.Duration.ms 1))
  in
  let foreign_token =
    match
      Crux.Root.advance foreign_root
      |> Eta.Effect.with_clock
           (Eta_test.Test_clock.as_capability foreign_clock)
      |> run_ok runtime
    with
    | Ok (Crux.Root.Committed committed) ->
        output_of_commit foreign_witness committed.commit
    | _ -> Alcotest.fail "foreign now commit failed"
  in
  let foreign_target =
    match Crux.Time.add foreign_token (Eta.Duration.ms 10) with
    | Ok target -> target
    | Error _ -> Alcotest.fail "valid foreign addition failed"
  in
  let switched_root, _switched_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.deadline foreign_target)
  in
  match run_ok runtime (Crux.Root.advance switched_root) with
  | Ok (Crux.Root.Failed { failure; _ }) ->
      Alcotest.(check bool) "foreign timestamp rejected" true
        (failure.Crux.Failure.primary.origin
         = Crux.Failure.Graph_clock)
  | _ -> Alcotest.fail "foreign clock token was accepted"

let test_dynamic_deadline_uses_timestamp_provenance () =
  Eta_test.with_test_clock @@ fun _switch clock runtime ->
  let source_root, source_witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.now ~every:(Eta.Duration.ms 100))
  in
  let source_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity [])
      source_root
  in
  let now =
    deliver runtime source_witness
      (run_ok runtime (Crux.Driver.poll source_driver))
  in
  let target =
    match Crux.Time.add now (Eta.Duration.ms 10) with
    | Ok target -> target
    | Error _ -> Alcotest.fail "valid time addition failed"
  in
  let root, witness =
    Projection.root ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Time.deadline target)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  Alcotest.(check bool) "dynamic deadline starts false" false
    (deliver runtime witness (run_ok runtime (Crux.Driver.poll driver)));
  Eta_test.Test_clock.advance_to clock 10;
  Alcotest.(check bool) "dynamic deadline becomes true" true
    (deliver runtime witness (run_ok runtime (Crux.Driver.poll driver)))

let () =
  Alcotest.run "eta_crux time and driver"
    [
      ( "time-driver",
        [
          Alcotest.test_case "graph time shared sample and due coalescing"
            `Quick test_graph_time_shared_sample_and_due_coalescing;
          Alcotest.test_case "driver attachment fence and pull observation"
            `Quick test_driver_attachment_fence;
          Alcotest.test_case "pull does not complete delivery"
            `Quick test_pull_does_not_complete_delivery;
          Alcotest.test_case "driver await wakes at graph deadline"
            `Quick test_driver_await_wakes_at_graph_deadline;
          Alcotest.test_case "graph time runtime mismatch" `Quick
            test_graph_time_runtime_mismatch;
          Alcotest.test_case "due advancement preserves queued ingress"
            `Quick test_due_advancement_preserves_queued_ingress;
          Alcotest.test_case "clock regression is structured failure"
            `Quick test_clock_regression_is_structured_failure;
          Alcotest.test_case "graph time static validation" `Quick
            test_graph_time_static_validation;
          Alcotest.test_case "graph time dynamic failures" `Quick
            test_graph_time_dynamic_failures;
          Alcotest.test_case "graph time failure attribution" `Quick
            test_graph_time_failure_attribution;
          Alcotest.test_case "graph time no fallback" `Quick
            test_graph_time_no_fallback;
          Alcotest.test_case "dynamic deadline uses timestamp provenance"
            `Quick test_dynamic_deadline_uses_timestamp_provenance;
        ] );
    ]
