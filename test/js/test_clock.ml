open Test_support

let tests =
  [
    ("virtual_clock",
     fun () ->
       let open Eta_js in
       let module Test_clock = Eta_js_test.Test_clock in
       let runtime = Runtime.create () in
       let clock = Test_clock.create () in
       let seen = ref [] in
       let record value =
         Effect.seq
           (Test_clock.sleep clock (Duration.ms value))
           (Effect.sync (fun () -> seen := !seen @ [ value ]))
       in
       ignore (Runtime.run_promise runtime (record 10));
       ignore (Runtime.run_promise runtime (record 10));
       ignore (Runtime.run_promise runtime (record 20));
       check_equal_int "Test_clock.sleepers initial" 3
         (Test_clock.sleeper_count clock);
       (match Runtime.run_now runtime (Test_clock.adjust clock (Duration.ms 10)) with
       | Some exit -> check_exit_ok_unit "Test_clock.adjust first" exit
       | None -> fail "Test_clock.adjust first" "expected sync exit" |> raise);
       check "Test_clock.same deadline order" (!seen = [ 10; 10 ]);
       check_equal_int "Test_clock.later sleeper remains" 1
         (Test_clock.sleeper_count clock);
       (match Runtime.run_now runtime (Test_clock.adjust clock (Duration.ms 5)) with
       | Some exit -> check_exit_ok_unit "Test_clock.adjust early" exit
       | None -> fail "Test_clock.adjust early" "expected sync exit" |> raise);
       check "Test_clock.later not early" (!seen = [ 10; 10 ]);
       (match Runtime.run_now runtime (Test_clock.set_time clock 20) with
       | Some exit -> check_exit_ok_unit "Test_clock.set_time" exit
       | None -> fail "Test_clock.set_time" "expected sync exit" |> raise);
       check "Test_clock.later wakes" (!seen = [ 10; 10; 20 ]);
       check_equal_int "Test_clock.sleepers drained" 0
         (Test_clock.sleeper_count clock);
       Js.Promise.resolve ());
  ]
