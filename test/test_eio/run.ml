module Suite =
  Eta_test_common_tests.Test_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-test-eio-shared" Suite.tests
