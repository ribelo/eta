module Suite =
  Eta_schema_test_common_tests.Schema_test_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-schema-test-eio-shared" Suite.tests
