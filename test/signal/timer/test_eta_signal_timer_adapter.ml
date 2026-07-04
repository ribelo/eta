open Eta

module Adapter = Eta_signal_timer_adapter
module Timer_policy = Eta_signal_timer_policy

let pp_hidden ppf _ = Format.pp_print_string ppf "<timer-adapter-error>"

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f runtime

let record events event = events := !events @ [ event ]

let test_cancellable_stop_skips_loop () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  run_ok runtime
    (Adapter.run_cancellable
       ~install_cancel:(fun ~cancel:_ ->
         Effect.sync (fun () ->
             record events "install_cancel";
             `Stop))
       ~loop:(Effect.sync (fun () -> record events "loop")));
  Alcotest.(check (list string))
    "events" [ "install_cancel" ] !events

let test_loop_orders_due_advance_and_update () =
  with_runtime @@ fun runtime ->
  let events = ref [] in
  let updates = ref 0 in
  let callbacks =
    {
      Adapter.read_next_due =
        (fun ~generation ~fallback ->
          Effect.sync (fun () ->
              record events
                ("read:" ^ string_of_int generation ^ ":"
               ^ string_of_int fallback);
              Some fallback));
      advance_next_due =
        (fun ~generation ~expected ~next_due_ms ->
          Effect.sync (fun () ->
              record events
                ("advance:" ^ string_of_int generation ^ ":"
               ^ string_of_int expected ^ ":" ^ string_of_int next_due_ms);
              `Advanced));
      after_update_state =
        (fun ~generation ->
          Effect.sync (fun () ->
              record events ("state:" ^ string_of_int generation);
              if !updates = 0 then `Continue else `Stop));
      finish_saturated =
        (fun ~generation ->
          Effect.sync (fun () ->
              record events ("finish:" ^ string_of_int generation)));
      construct_update =
        (fun ~generation ~missed ->
          record events
            ("construct:" ^ string_of_int generation ^ ":"
           ^ string_of_int missed);
          Effect.sync (fun () ->
              incr updates;
              record events "run"));
      after_due_read_before_commit =
        (fun () -> Effect.sync (fun () -> record events "due_hook"));
      after_update_constructed_before_run =
        (fun () -> Effect.sync (fun () -> record events "after_construct"));
    }
  in
  run_ok runtime
    (Adapter.run_loop callbacks ~generation:7 ~interval_ms:10 ~next_due_ms:0
       ~catch_up_policy:Timer_policy.Catch_up_coalesced);
  Alcotest.(check (list string))
    "events"
    [
      "read:7:0";
      "read:7:0";
      "due_hook";
      "advance:7:0:10";
      "state:7";
      "construct:7:1";
      "after_construct";
      "run";
      "state:7";
    ]
    !events

let () =
  Alcotest.run "eta_signal_timer_adapter"
    [
      ( "timer_adapter",
        [
          Alcotest.test_case "cancellable stop skips loop" `Quick
            test_cancellable_stop_skips_loop;
          Alcotest.test_case "loop callback order" `Quick
            test_loop_orders_due_advance_and_update;
        ] );
    ]
