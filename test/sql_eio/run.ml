module Suite =
  Eta_sql_common_tests.Sql_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-sql-eio-shared" Suite.tests
