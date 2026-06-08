open Test_support

let tests =
  [
    ("die_produces_die",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Die _) -> ()
             | _ -> fail "die" "expected Die cause" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Effect.die (Failure "boom")))
       in
       p);
    ("catch_does_not_catch_defect",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Die _) -> ()
             | _ -> fail "catch defect" "expected Die cause" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.catch (fun _ -> Effect.pure 42)
                 (Effect.die (Failure "boom"))))
       in
       p);
    ("catch_cause_catches_typed_failure",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "catch_cause typed" 99 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.catch_cause
                 (fun cause ->
                   match cause with
                   | Cause.Fail `Boom -> Effect.pure 99
                   | _ -> Effect.fail `Other)
                 (Effect.fail `Boom)))
       in
       p);
    ("sandbox_roundtrip",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "sandbox roundtrip" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.bind
                 (fun result ->
                   match result with
                   | Ok v -> Effect.pure v
                   | Error _ -> Effect.fail `Never)
                 (Effect.sandbox (Effect.pure 42))))
       in
       p);
    ("sandbox_catches_defect",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok (Error (Cause.Die _)) -> ()
             | _ -> fail "sandbox defect" "expected Die in sandbox" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.sandbox (Effect.die (Failure "boom"))))
       in
       p);
    ("unsandbox_roundtrip",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "unsandbox roundtrip" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.unsandbox (Effect.sandbox (Effect.pure 42))))
       in
       p);
    ("unsandbox_propagates_typed_failure",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_fail_int "unsandbox typed" 7 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.unsandbox (Effect.sandbox (Effect.fail 7))))
       in
       p);
    ("tap_cause_runs_on_failure",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let seen = ref false in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_fail_int "tap_cause" 3 exit;
             check "tap_cause ran" !seen;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.tap_cause
                 (fun _ -> seen := true)
                 (Effect.fail 3)))
       in
       p);
    ("match_effect_success",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "match_effect success" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.match_effect
                 ~on_success:(fun v -> Effect.pure (v * 2))
                 ~on_failure:(fun _ -> Effect.pure 0)
                 (Effect.pure 21)))
       in
       p);
    ("match_effect_failure",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "match_effect failure" 99 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.match_effect
                 ~on_success:(fun _ -> Effect.pure 0)
                 ~on_failure:(fun _ -> Effect.pure 99)
                 (Effect.fail `Boom)))
       in
       p);
  ]
