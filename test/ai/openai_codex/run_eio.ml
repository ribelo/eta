module Suite =
  Eta_ai_openai_codex_common_tests.Openai_codex_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-openai-codex-eio" Suite.tests
