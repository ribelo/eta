module Suite =
  Eta_redacted_common_tests.Redacted_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-redacted-eio-shared" Suite.tests
