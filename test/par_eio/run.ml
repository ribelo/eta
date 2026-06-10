module Suite =
  Eta_par_common_tests.Par_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-par-eio-shared" Suite.tests
