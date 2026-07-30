(* Direct coverage for docs/requirements/eta-maintainability/benchmark-support.md *)

let count_calls n =
  let calls = ref 0 in
  Bench_lib.repeat n (fun () -> incr calls);
  !calls

(* ^benchlib-s9u1: invoke a unit callback exactly the requested positive count. *)
let test_benchlib_s9u1_positive_count () =
  Alcotest.(check int) "repeat 1" 1 (count_calls 1);
  Alcotest.(check int) "repeat 3" 3 (count_calls 3);
  Alcotest.(check int) "repeat 10" 10 (count_calls 10)

(* ^benchlib-cg02: zero or negative counts must not invoke the callback. *)
let test_benchlib_cg02_non_positive_skips_callback () =
  Alcotest.(check int) "repeat 0" 0 (count_calls 0);
  Alcotest.(check int) "repeat -1" 0 (count_calls (-1));
  Alcotest.(check int) "repeat -100" 0 (count_calls (-100))

let () =
  Alcotest.run "bench_lib_repeat"
    [
      ( "benchlib-s9u1",
        [
          Alcotest.test_case "positive callback count" `Quick
            test_benchlib_s9u1_positive_count;
        ] );
      ( "benchlib-cg02",
        [
          Alcotest.test_case "zero and negative skip callback" `Quick
            test_benchlib_cg02_non_positive_skips_callback;
        ] );
    ]
