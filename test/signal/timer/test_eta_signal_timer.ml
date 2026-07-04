module Timer = Eta_signal_timer

let pp_deadline_error ppf = function
  | `Past_deadline -> Format.pp_print_string ppf "Past_deadline"
  | `Deadline_overflow -> Format.pp_print_string ppf "Deadline_overflow"

let deadline_error =
  Alcotest.testable pp_deadline_error (fun left right -> left = right)

let test_capped_arithmetic () =
  Alcotest.(check int) "add ignores negative" 10 (Timer.add_ms_capped 10 (-2));
  Alcotest.(check int) "add caps" max_int (Timer.add_ms_capped max_int 1);
  Alcotest.(check int) "mul zero" 0 (Timer.mul_ms_capped 10 0);
  Alcotest.(check int) "mul caps" max_int (Timer.mul_ms_capped max_int 2);
  Alcotest.(check int) "int add caps" max_int (Timer.add_int_capped max_int 1)

let test_due_arithmetic () =
  Alcotest.(check int) "not due" 0
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:49);
  Alcotest.(check int) "exactly due" 1
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:50);
  Alcotest.(check int) "missed multiple" 4
    (Timer.missed_cadences ~interval_ms:10 ~next_due_ms:50 ~now_ms:85);
  Alcotest.(check int) "advance" 90 (Timer.advance_due 50 10 4)

let test_deadline_arithmetic () =
  Alcotest.(check (result int deadline_error)) "positive" (Ok 15)
    (Timer.add_relative_deadline 10 5);
  Alcotest.(check (result int deadline_error)) "past" (Error `Past_deadline)
    (Timer.add_relative_deadline 10 0);
  Alcotest.(check (result int deadline_error)) "overflow"
    (Error `Deadline_overflow)
    (Timer.add_relative_deadline max_int 1)

let test_catch_up_policy () =
  Alcotest.(check int) "every count" 3
    (Timer.catch_up_update_count Catch_up_every_cadence 3);
  Alcotest.(check int) "once count" 1
    (Timer.catch_up_update_count Catch_up_once_per_wake 3);
  Alcotest.(check int) "coalesced count" 1
    (Timer.catch_up_update_count Catch_up_coalesced 3);
  Alcotest.(check int) "every missed" 1
    (Timer.catch_up_update_missed Catch_up_every_cadence 3);
  Alcotest.(check int) "coalesced missed" 3
    (Timer.catch_up_update_missed Catch_up_coalesced 3)

let () =
  Alcotest.run "eta_signal_timer"
    [
      ( "timer",
        [
          Alcotest.test_case "capped arithmetic" `Quick test_capped_arithmetic;
          Alcotest.test_case "due arithmetic" `Quick test_due_arithmetic;
          Alcotest.test_case "deadline arithmetic" `Quick
            test_deadline_arithmetic;
          Alcotest.test_case "catch up policy" `Quick test_catch_up_policy;
        ] );
    ]
