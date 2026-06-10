module Suite =
  Eta_ai_common_tests.Ai_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-eio-shared" Suite.tests
