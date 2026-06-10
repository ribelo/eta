module Suite =
  Eta_ai_openai_common_tests.Openai_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-openai-eio-shared" Suite.tests
