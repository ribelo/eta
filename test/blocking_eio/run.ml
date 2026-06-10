module Suite =
  Eta_blocking_common_tests.Blocking_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-blocking-eio-shared" Suite.tests
