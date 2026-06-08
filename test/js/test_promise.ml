open Test_support

let tests =
  [
    ("promise_async",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Promise.await_promise resolve" 88 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Promise.await_promise (fun () -> Js.Promise.resolve 88)))
       in
       let runtime = Runtime.create () in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Die _) -> ()
             | _ -> fail "Promise.await_promise reject" "expected defect"
               |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Promise.await_promise (fun () ->
                   Js.Promise.reject (Failure "promise rejected"))))
       in
       let runtime = Runtime.create () in
       let p3 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Rejected) -> ()
             | _ -> fail "Promise.await_abortable typed" "expected typed failure"
               |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Promise.await_abortable (fun _signal ->
                   Js.Promise.resolve (Error `Rejected))))
       in
       let runtime = Runtime.create () in
       let cancel_count = ref 0 in
       let p4 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Promise.await_promise cancellation" "expected timeout"
               |> raise);
             check_equal_int "Promise.await_promise on_cancel once" 1
               !cancel_count;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero
                 (Promise.await_promise
                    ~on_cancel:(fun () -> incr cancel_count)
                    (fun () ->
                      Js.Promise.make (fun ~resolve:_ ~reject:_ -> ())))))
       in
       let runtime = Runtime.create () in
       let signal = ref None in
       let p5 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ ->
                 fail "Promise.await_abortable cancellation" "expected timeout"
                 |> raise);
             (match !signal with
             | Some signal ->
                 check "Promise.await_abortable aborts signal"
                   (Js_interop.aborted signal)
             | None ->
                 fail "Promise.await_abortable cancellation" "missing signal"
                 |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero
                 (Promise.await_abortable (fun abort_signal ->
                      signal := Some abort_signal;
                      Js.Promise.make (fun ~resolve:_ ~reject:_ -> ())))))
       in
       Js.Promise.all [| p1; p2; p3; p4; p5 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
  ]
