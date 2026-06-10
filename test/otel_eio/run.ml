module Suite =
  Eta_otel_common_tests.Otel_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-otel-eio-shared" Suite.tests
