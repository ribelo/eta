open Eta
open Test_eta_support

let test_uninterruptible_race_loser_without_checkpoints_returns () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  let domain_mgr = Eio.Stdenv.domain_mgr stdenv in
  let completed = ref false in
  let loser =
    Effect.sync (fun () ->
        let total =
          Eio.Domain_manager.run domain_mgr (fun () ->
              let acc = ref 0 in
              for i = 1 to 200_000 do
                acc := !acc + i
              done;
              !acc)
        in
        completed := total > 0;
        "slow")
    |> Effect.uninterruptible
  in
  let result = Runtime.run rt (Effect.race [ Effect.pure "fast"; loser ]) in
  check_exit_ok Alcotest.string "winner preserved" "fast" result;
  Alcotest.(check bool)
    "loser returned without cancellation checkpoint" true !completed
