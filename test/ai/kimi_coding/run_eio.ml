module Suite =
  Eta_ai_kimi_coding_common_tests.Kimi_coding_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-kimi-coding-eio" Suite.tests
