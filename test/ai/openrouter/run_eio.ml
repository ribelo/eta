module Suite =
  Eta_ai_openrouter_common_tests.Openrouter_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-openrouter-eio-shared" Suite.tests
