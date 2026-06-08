open Test_support

let tests =
  [
    ("uninterruptible_defer_race",
     fun () ->
       let open Eta_js in
       let module Test_clock = Eta_js_test.Test_clock in
       let clock = Test_clock.create () in
       let runtime = Test_clock.runtime clock in
       let slow_completed = ref false in
       let slow =
         Effect.uninterruptible
           (Effect.seq
              (Test_clock.sleep clock (Duration.ms 10))
              (Effect.sync (fun () -> slow_completed := true)))
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "uninterruptible race winner" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.race [ slow; Effect.pure () ]))
       in
       let p2 =
         Js.Promise.then_
           (fun () ->
             (match Runtime.run_now runtime (Test_clock.adjust clock (Duration.ms 10)) with
             | Some exit -> check_exit_ok_unit "uninterruptible adjust" exit
             | None -> fail "uninterruptible adjust" "expected sync exit" |> raise);
             check "uninterruptible slow completed" !slow_completed;
             Js.Promise.resolve ())
           p
       in
       p2);
    ("uninterruptible_preserves_result",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "uninterruptible result" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.uninterruptible (Effect.pure 42)))
       in
       p);
    ("uninterruptible_catch_inside",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "uninterruptible catch" 99 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.uninterruptible
                 (Effect.catch
                    (fun _ -> Effect.pure 99)
                    (Effect.fail `Boom))))
       in
       p);
  ]
