module Suite =
  Eta_ai_openai_compat_common_tests.Openai_compat_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-openai-compat-eio-shared" Suite.tests
