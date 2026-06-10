module Suite =
  Eta_runtime_common_tests.Runtime_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-runtime-eio" Suite.tests
