module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  module Shared = Eta_promise_shared_tests.Promise_shared.Make (struct
    let run eff ~on_result =
      B.with_runtime @@ fun _context runtime ->
      on_result (B.run runtime eff)

    let complete ~done_ check =
      check ();
      done_ ()

    let fail message = Alcotest.fail message
  end)

  let test_case (name, test) =
    Alcotest.test_case name `Quick @@ fun () ->
    let completed = ref false in
    test (fun () -> completed := true);
    Alcotest.(check bool) "test completed" true !completed

  let tests = [ ("Promise", List.map test_case Shared.tests) ]
end
