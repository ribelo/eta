open Eta
open Test_eta_support

let test_supervisor_scope_cancels_unawaited_children_on_return () =
  with_test_clock @@ fun _sw _clock rt ->
  let child_started, child_started_resolver = Eio.Promise.create () in
  let released = Atomic.make false in
  let child =
    Effect.acquire_release
      ~acquire:
        (Effect.sync (fun () ->
             Eio.Promise.resolve child_started_resolver ();
             ()))
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set released true))
    |> Effect.bind (fun () -> Effect.sync Eio.Fiber.await_cancel)
  in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () =
            lift (Effect.sync (fun () -> Eio.Promise.await child_started))
          in
          pure ();
    }
  in
  (match Runtime.run rt program with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Alcotest.failf "unexpected supervisor failure: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause);
  Alcotest.(check bool) "child finalizer ran" true (Atomic.get released)
