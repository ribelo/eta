module Suite =
  Eta_core_common_tests.Core_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-core-eio" Suite.tests
