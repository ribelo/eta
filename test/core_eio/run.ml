module Suite =
  Eta_core_common_tests.Core_common_suites.Make (Eta_test_backend_eio.Backend)

let atomic_push cell value =
  let rec loop () =
    let values = Atomic.get cell in
    if not (Atomic.compare_and_set cell values (value :: values)) then loop ()
  in
  loop ()

let check_census registrations active expected =
  Alcotest.(check int) "fork registrations" expected (Atomic.get registrations);
  Alcotest.(check int) "active registered fibers after exit" 0 (Atomic.get active)

let test_all_registers_before_synchronous_failure () =
  let registrations = Atomic.make 0 in
  let active = Atomic.make 0 in
  let starts = Atomic.make [] in
  let child index =
    Eta.Effect.sync (fun () ->
        atomic_push starts (index, Atomic.get registrations))
    |> Eta.Effect.bind (fun () ->
           if index = 0 then Eta.Effect.fail "boom" else Eta.Effect.pure index)
  in
  let exit =
    Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
      (Eta.Effect.all (List.init 3 child))
  in
  check_census registrations active 3;
  Alcotest.(check (list (pair int int)))
    "only the first body starts, after every registration"
    [ (0, 3) ] (List.rev (Atomic.get starts));
  match exit with
  | Eta.Exit.Error (Eta.Cause.Fail "boom") -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Fail boom, got %a"
        (Eta.Cause.pp Format.pp_print_string)
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected synchronous first failure"

let test_all_settled_registers_before_synchronous_failure () =
  let registrations = Atomic.make 0 in
  let active = Atomic.make 0 in
  let starts = Atomic.make [] in
  let child index =
    Eta.Effect.sync (fun () ->
        atomic_push starts (index, Atomic.get registrations))
    |> Eta.Effect.bind (fun () ->
           if index = 0 then Eta.Effect.fail "boom" else Eta.Effect.pure index)
  in
  let exit =
    Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
      (Eta.Effect.all_settled (List.init 3 child))
  in
  check_census registrations active 3;
  Alcotest.(check (list (pair int int)))
    "every body starts after every registration"
    [ (0, 3); (1, 3); (2, 3) ]
    (List.rev (Atomic.get starts));
  match exit with
  | Eta.Exit.Ok
      [ Error (Eta.Cause.Fail "boom"); Ok 1; Ok 2 ] ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected settled outcomes"
  | Eta.Exit.Error cause ->
      Alcotest.failf "all_settled failed outer group: %a"
        (Eta.Cause.pp Format.pp_print_string)
        cause

let test_all_admission_does_not_preempt_noncooperative_body () =
  let registrations = Atomic.make 0 in
  let active = Atomic.make 0 in
  let events = Atomic.make [] in
  let first =
    Eta.Effect.sync (fun () ->
        atomic_push events ("first-start", Atomic.get registrations);
        atomic_push events ("first-complete", Atomic.get registrations);
        0)
  in
  let second =
    Eta.Effect.sync (fun () ->
        atomic_push events ("second-start", Atomic.get registrations);
        1)
  in
  let exit =
    Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
      (Eta.Effect.all [ first; second ])
  in
  check_census registrations active 2;
  Alcotest.(check (list (pair string int)))
    "finite no-yield body is not preempted after full registration"
    [ ("first-start", 2); ("first-complete", 2); ("second-start", 2) ]
    (List.rev (Atomic.get events));
  match exit with
  | Eta.Exit.Ok [ 0; 1 ] -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "unexpected all result"
  | Eta.Exit.Error cause ->
      Alcotest.failf "finite no-yield all failed: %a"
        (Eta.Cause.pp Format.pp_print_int)
        cause

let eio_admission_tests =
  ( "Effect Eio admission",
    [
      Alcotest.test_case
        "all registers every child before synchronous first failure" `Quick
        test_all_registers_before_synchronous_failure;
      Alcotest.test_case
        "all_settled registers every child before synchronous first failure"
        `Quick test_all_settled_registers_before_synchronous_failure;
      Alcotest.test_case "all full admission does not preempt a no-yield body"
        `Quick test_all_admission_does_not_preempt_noncooperative_body;
    ] )

let () = Alcotest.run "eta-core-eio" (Suite.tests @ [ eio_admission_tests ])
