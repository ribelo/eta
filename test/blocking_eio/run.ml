module Backend = struct
  include Eta_test_backend_eio.Backend

  let with_runtime f =
    run_eio @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let rt =
      Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
    in
    f sw rt
end

module Suite =
  Eta_blocking_common_tests.Blocking_common_suites.Make (Backend)

let () = Alcotest.run "eta-blocking-eio-shared" Suite.tests
