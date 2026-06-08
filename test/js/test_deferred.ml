open Test_support

let tests =
  [
    ("deferred_await_before_succeed",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let d = Deferred.make_unsafe () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Deferred.await before succeed" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Deferred.await d))
       in
       (match Runtime.run_now runtime (Deferred.succeed d 42) with
       | Some (Exit.Ok true) -> ()
       | _ -> fail "Deferred.succeed" "expected true" |> raise);
       p1);
    ("deferred_succeed_before_await",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let d = Deferred.make_unsafe () in
       (match Runtime.run_now runtime (Deferred.succeed d 99) with
       | Some (Exit.Ok true) -> ()
       | _ -> fail "Deferred.succeed first" "expected true" |> raise);
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Deferred.await after succeed" 99 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Deferred.await d))
       in
       p1);
    ("deferred_second_completion_false",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let d = Deferred.make_unsafe () in
       (match Runtime.run_now runtime (Deferred.succeed d 1) with
       | Some (Exit.Ok true) -> ()
       | _ -> fail "Deferred.first succeed" "expected true" |> raise);
       (match Runtime.run_now runtime (Deferred.succeed d 2) with
       | Some (Exit.Ok false) -> ()
       | _ -> fail "Deferred.second succeed" "expected false" |> raise);
       Js.Promise.resolve ());
    ("deferred_poll",
     fun () ->
       let open Eta_js in
       let d = Deferred.make_unsafe () in
       check "Deferred.poll pending" (Deferred.poll d = None);
       ignore (Deferred.succeed d 7);
       (match Deferred.poll d with
       | Some (Ok 7) -> ()
       | _ -> fail "Deferred.poll completed" "expected Some (Ok 7)" |> raise);
       Js.Promise.resolve ());
    ("deferred_fail_cause",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let d = Deferred.make_unsafe () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Boom) -> ()
             | _ -> fail "Deferred.fail_cause" "expected typed failure" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Deferred.await d))
       in
       ignore (Deferred.fail_cause d (Cause.fail `Boom));
       p1);
  ]
