module Suite =
  Eta_http_common_tests.Http_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-http-eio-shared" Suite.tests
