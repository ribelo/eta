module Suite =
  Eta_sql_driver_common_tests.Sql_driver_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-sql-driver-eio-shared" Suite.tests
