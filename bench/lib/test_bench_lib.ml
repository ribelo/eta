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

(* ^benchlib-4knd: normalize a per-run measurement by the operation count. *)
let test_benchlib_4knd_per_op_normalization () =
  Alcotest.(check (float 1e-9)) "ops 1" 250. (Bench_lib.per_op ~ops:1 250.);
  Alcotest.(check (float 1e-9)) "ops 1000" 0.25 (Bench_lib.per_op ~ops:1000 250.);
  Alcotest.check_raises "ops 0"
    (Invalid_argument "Bench_lib.per_op: ops must be positive") (fun () ->
      ignore (Bench_lib.per_op ~ops:0 1.));
  Alcotest.check_raises "workload ops 0"
    (Invalid_argument "Bench_lib.workload: ops must be positive") (fun () ->
      ignore (Bench_lib.workload ~ops:0 "x" (fun () -> ())))

(* ^benchlib-p73c: report the median, which a lone outlying sample cannot move. *)
let test_benchlib_p73c_median_resists_outlier () =
  Alcotest.(check (float 1e-9)) "empty" 0. (Bench_lib.median []);
  Alcotest.(check (float 1e-9)) "single" 5. (Bench_lib.median [ 5. ]);
  Alcotest.(check (float 1e-9)) "odd count" 3. (Bench_lib.median [ 3.; 1.; 900. ]);
  Alcotest.(check (float 1e-9)) "even count" 3.
    (Bench_lib.median [ 4.; 2.; 900.; 1. ]);
  Alcotest.(check (float 1e-9)) "unsorted input" 2.
    (Bench_lib.median [ 900.; 2.; 1. ]);
  (* The same outlier moves the mean by two orders of magnitude. *)
  Alcotest.(check bool) "mean is moved" true (Bench_lib.mean [ 3.; 1.; 900. ] > 300.)

let () =
  Alcotest.run "bench_lib"
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
      ( "benchlib-4knd",
        [
          Alcotest.test_case "per-operation normalization" `Quick
            test_benchlib_4knd_per_op_normalization;
        ] );
      ( "benchlib-p73c",
        [
          Alcotest.test_case "median resists a lone outlier" `Quick
            test_benchlib_p73c_median_resists_outlier;
        ] );
    ]
