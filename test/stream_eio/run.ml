module Suite =
  Eta_stream_common_tests.Stream_common_suites.Make
    (Eta_test_backend_eio.Backend)

let () = Alcotest.run "eta-stream-eio-shared" Suite.tests
