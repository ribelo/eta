open Test_support

let tests =
  [
    ("Duration.to_ms",
     fun () ->
       let open Eta_js.Duration in
       check_equal_int "Duration.to_ms" 1_500
         (to_ms (add (seconds 1) (ms 500)));
       Js.Promise.resolve ());
    ("Exit.to_result",
     fun () ->
       let open Eta_js in
       let ok = Exit.to_result (Exit.ok 42) in
       let error = Exit.to_result (Exit.error (Cause.fail "missing")) in
       check "Exit.to_result ok" (ok = Some (Ok 42));
       check "Exit.to_result fail" (error = Some (Error "missing"));
       Js.Promise.resolve ());
    ("Cause.map",
     fun () ->
       let open Eta_js in
       match Cause.map String.length (Cause.fail "typed") with
       | Cause.Fail len ->
           check_equal_int "Cause.map" 5 len;
           Js.Promise.resolve ()
       | _ -> fail "Cause.map" "expected mapped typed failure" |> raise);
    ("Schedule.next_delay",
     fun () ->
       let open Eta_js in
       let schedule = Schedule.spaced (Duration.ms 25) in
       match Schedule.next_delay schedule ~step:0 with
       | Some delay ->
           check_equal_int "Schedule.next_delay" 25 (Duration.to_ms delay);
           Js.Promise.resolve ()
       | None -> fail "Schedule.next_delay" "expected first delay" |> raise);
  ]
