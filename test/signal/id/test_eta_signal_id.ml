module Id = Eta_signal_id

let test_labels () =
  Alcotest.(check string) "signal" "s4" (Id.signal_label (Id.signal 4));
  Alcotest.(check string) "dead signal" "dead_s4"
    (Id.dead_signal_label (Id.signal 4));
  Alcotest.(check string) "scope" "sc5" (Id.scope_label (Id.scope 5));
  Alcotest.(check string) "var" "v6" (Id.var_label (Id.var 6));
  Alcotest.(check string) "observer" "o7"
    (Id.observer_label (Id.observer 7))

let test_int_roundtrip () =
  Alcotest.(check int) "signal" 1 (Id.signal_int (Id.signal 1));
  Alcotest.(check int) "scope" 2 (Id.scope_int (Id.scope 2));
  Alcotest.(check int) "var" 3 (Id.var_int (Id.var 3));
  Alcotest.(check int) "observer" 4 (Id.observer_int (Id.observer 4))

let test_compare_observer () =
  Alcotest.(check int) "less" (-1)
    (Id.compare_observer (Id.observer 1) (Id.observer 2));
  Alcotest.(check int) "equal" 0
    (Id.compare_observer (Id.observer 2) (Id.observer 2));
  Alcotest.(check int) "greater" 1
    (Id.compare_observer (Id.observer 3) (Id.observer 2))

let () =
  Alcotest.run "eta_signal_id"
    [
      ( "id",
        [
          Alcotest.test_case "labels" `Quick test_labels;
          Alcotest.test_case "int roundtrip" `Quick test_int_roundtrip;
          Alcotest.test_case "compare observer" `Quick test_compare_observer;
        ] );
    ]
