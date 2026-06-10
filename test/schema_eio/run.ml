module Suite =
  Eta_schema_common_tests.Schema_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-schema-eio-shared" Suite.tests
