module Suite = Eta_ppx_common_tests.Ppx_common_suites.Make (Eta_test_backend_eio.Backend)

let () = Alcotest.run "ppx-eta-eio" Suite.tests
