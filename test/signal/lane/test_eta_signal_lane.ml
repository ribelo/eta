module Lane = Eta_signal_lane

let hooks =
  Lane.hooks ~note_waiter_enqueued:(fun () -> ())
    ~note_waiter_compaction:(fun () -> ())

let run_effect eff =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  Eta.Runtime.run runtime eff

let expect_effect_ok label eff =
  match run_effect eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected Ok" label

let test_cancelled_compaction_policy () =
  Alcotest.(check bool) "empty queue" false
    (Lane.should_compact_cancelled ~retained_cancelled:1 ~queue_length:0);
  Alcotest.(check bool) "no retained cancellation" false
    (Lane.should_compact_cancelled ~retained_cancelled:0 ~queue_length:4);
  Alcotest.(check bool) "below half" false
    (Lane.should_compact_cancelled ~retained_cancelled:1 ~queue_length:4);
  Alcotest.(check bool) "half compacted" true
    (Lane.should_compact_cancelled ~retained_cancelled:2 ~queue_length:4);
  Alcotest.(check bool) "odd half rounded up" true
    (Lane.should_compact_cancelled ~retained_cancelled:2 ~queue_length:3)

let test_reentry_policy () =
  Alcotest.(check bool) "depth permits reentry" true
    (Lane.can_reenter ~lane_depth:1 ~owner_fiber_id:None ~current_fiber_id:10);
  Alcotest.(check bool) "same owner permits reentry" true
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:(Some 10)
       ~current_fiber_id:10);
  Alcotest.(check bool) "different owner waits" false
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:(Some 11)
       ~current_fiber_id:10);
  Alcotest.(check bool) "unowned lane enters normally" false
    (Lane.can_reenter ~lane_depth:0 ~owner_fiber_id:None ~current_fiber_id:10)

let test_access_token_guards_leave () =
  let lane = Lane.create () in
  let effect =
    Eta.Effect.Expert.make ~leaf_name:"eta_signal_lane.test" @@ fun context ->
    try
      let contract = Eta.Effect.Expert.contract context in
      let first = Lane.enter ~hooks contract lane in
      Lane.leave lane first;
      Alcotest.check_raises "stale token"
        (Invalid_argument
           "Eta_signal lane invariant failed: lane access token is stale")
        (fun () -> Lane.leave lane first);
      let second = Lane.enter ~hooks contract lane in
      Alcotest.check_raises "inactive token"
        (Invalid_argument
           "Eta_signal lane invariant failed: lane access token is not active")
        (fun () -> Lane.leave lane first);
      Lane.leave lane second;
      Eta.Exit.Ok ()
    with exn -> Eta.Effect.Expert.exit_of_exn context exn
  in
  expect_effect_ok "lane access token" effect

let () =
  Alcotest.run "eta_signal_lane"
    [
      ( "lane",
        [
          Alcotest.test_case "cancelled compaction policy" `Quick
            test_cancelled_compaction_policy;
          Alcotest.test_case "reentry policy" `Quick test_reentry_policy;
          Alcotest.test_case "access token guards leave" `Quick
            test_access_token_guards_leave;
        ] );
    ]
