open Test_support

let tests =
  [
    ("supervisor_async",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let observes_failure =
         Supervisor.scoped
           {
             run =
               (fun (type s) supervisor ->
                 let open Supervisor.Scope in
                 let* (_child : (s, [> `Boom ], int) Supervisor.child) =
                   start supervisor (fail `Boom)
                 in
                 let* () = yield in
                 failures supervisor);
           }
       in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok [ Cause.Fail `Boom ] -> ()
             | _ -> fail "Supervisor.failures" "expected observed child failure"
               |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime observes_failure)
       in
       let runtime = Runtime.create () in
       let await_failure =
         Supervisor.scoped
           {
             run =
               (fun (type s) supervisor ->
                 let open Supervisor.Scope in
                 let* (child : (s, [> `Boom ], int) Supervisor.child) =
                   start supervisor (fail `Boom)
                 in
                 await child);
           }
       in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Boom) -> ()
             | _ -> fail "Supervisor.await" "expected child failure" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime await_failure)
       in
       let runtime = Runtime.create () in
       let finalizer_ran = ref false in
       let child =
         Effect.acquire_use_release
           ~acquire:(Effect.sync (fun () -> ()))
           ~release:(fun () ->
             Effect.sync (fun () -> finalizer_ran := true))
           (fun () -> Effect.delay (Duration.ms 10) Effect.unit)
       in
       let cancel_child =
         Supervisor.scoped
           {
             run =
               (fun (type s) supervisor ->
                 let open Supervisor.Scope in
                 let* (child : (s, [> `Boom ], unit) Supervisor.child) =
                   start supervisor (lift child)
                 in
                 let* () = yield in
                 let* () = cancel child in
                 await child);
           }
       in
       let p3 =
         Js.Promise.then_
           (fun exit ->
             check "Supervisor.cancel finalizer ran" !finalizer_ran;
             check_exit_interrupt "Supervisor.cancel await interrupt" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime cancel_child)
       in
       let runtime = Runtime.create () in
       let threshold =
         Supervisor.scoped ~max_failures:1
           {
             run =
               (fun (type s) supervisor ->
                 let open Supervisor.Scope in
                 let* (_child :
                         ( s,
                           [> `Boom | `Supervisor_failed of int ],
                           int )
                         Supervisor.child) =
                   start supervisor (fail `Boom)
                 in
                 let* () = yield in
                 check supervisor);
           }
       in
       let p4 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail (`Supervisor_failed 1)) -> ()
             | _ -> fail "Supervisor.check" "expected threshold failure" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime threshold)
       in
       let runtime = Runtime.create () in
       let background_finalizer = ref false in
       let background =
         Effect.acquire_use_release
           ~acquire:(Effect.sync (fun () -> ()))
           ~release:(fun () ->
             Effect.sync (fun () -> background_finalizer := true))
           (fun () -> Effect.delay (Duration.ms 10) Effect.unit)
       in
       let p5 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Effect.with_background result" 77 exit;
             check "Effect.with_background cancels child" !background_finalizer;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.with_background background (fun () ->
                   Effect.seq Effect.yield_now (Effect.pure 77))))
       in
       let named_rejected =
         try
           ignore
             (Effect.with_background ~name:"background" Effect.unit (fun () ->
                  Effect.unit));
           false
         with Invalid_argument _ -> true
       in
       check "Effect.with_background named rejected" named_rejected;
       Js.Promise.all [| p1; p2; p3; p4; p5 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
  ]
