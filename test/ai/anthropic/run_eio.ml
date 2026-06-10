module Suite =
  Eta_ai_anthropic_common_tests.Anthropic_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-anthropic-eio-shared" Suite.tests
