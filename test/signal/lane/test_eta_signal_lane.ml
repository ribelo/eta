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

let () =
  Alcotest.run "eta_signal_lane"
    [
      ( "lane",
        [
          Alcotest.test_case "cancelled compaction policy" `Quick
            test_cancelled_compaction_policy;
        ] );
    ]
