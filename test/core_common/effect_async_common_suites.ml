module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  module Shared =
    Eta_effect_async_shared_tests.Effect_async_shared.Make (struct
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

  let test_cross_domain_callback_vs_callback_settles_once () =
    B.with_runtime @@ fun _context runtime ->
    for trial = 1 to 32 do
      let domains = ref [] in
      let spawn resume value =
        (Domain.spawn
           [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
          (fun () -> resume (Eta.Exit.Ok value))
      in
      let eff =
        Eta.Effect.async ~register:(fun resume ->
            domains := [ spawn resume trial; spawn resume (-trial) ];
            None)
      in
      let value =
        match B.run runtime eff with
        | Eta.Exit.Ok value -> value
        | Eta.Exit.Error cause ->
            Alcotest.failf "cross-domain async failed: %a"
              (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<async>"))
              cause
      in
      List.iter Domain.join !domains;
      Alcotest.(check int) "one cross-domain callback won" trial (abs value)
    done

  let tests =
    [
      ( "Effect async",
        List.map test_case Shared.tests
        @ [
            Alcotest.test_case
              "async cross-domain callback-vs-callback settles once" `Quick
              test_cross_domain_callback_vs_callback_settles_once;
          ] );
    ]
end
