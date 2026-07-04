module Debug = Eta_signal_debug

let pp_counter_error formatter = function
  | `Counter_overflow name ->
      Format.fprintf formatter "Counter_overflow %S" name

let counter_error =
  Alcotest.testable pp_counter_error (fun left right -> left = right)

let test_stats_counter () =
  Alcotest.(check (result int counter_error)) "normal value" (Ok 12)
    (Debug.stats_counter ~name:"counter" 12);
  Alcotest.(check (result int counter_error)) "saturated value"
    (Error (`Counter_overflow "counter"))
    (Debug.stats_counter ~name:"counter" max_int)

let test_bool_field () =
  Alcotest.(check string) "true field" "valid=true"
    (Debug.bool_field "valid" true);
  Alcotest.(check string) "false field" "dirty=false"
    (Debug.bool_field "dirty" false)

let () =
  Alcotest.run "eta_signal_debug"
    [
      ( "debug",
        [
          Alcotest.test_case "stats counter" `Quick test_stats_counter;
          Alcotest.test_case "bool field" `Quick test_bool_field;
        ] );
    ]
