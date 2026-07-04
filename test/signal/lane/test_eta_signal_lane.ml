module Lane = Eta_signal_lane

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

let () =
  Alcotest.run "eta_signal_lane"
    [
      ( "lane",
        [
          Alcotest.test_case "cancelled compaction policy" `Quick
            test_cancelled_compaction_policy;
          Alcotest.test_case "reentry policy" `Quick test_reentry_policy;
        ] );
    ]
