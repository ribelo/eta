module Suite =
  Eta_ai_moonshot_common_tests.Moonshot_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-ai-moonshot-eio" Suite.tests
