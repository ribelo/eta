open Eta
open Test_eta_support

let test_supervisor_scope_cancels_unawaited_children_on_return () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
  let result =
    Eio.Fiber.first
      (fun () ->
        match Runtime.run rt program with
        | Exit.Ok () -> `Returned
        | Exit.Error cause -> `Failed cause)
      (fun () ->
        Eio.Time.sleep (Eio.Stdenv.clock stdenv) 0.1;
        `Timed_out)
  in
  (match result with
  | `Returned -> ()
  | `Timed_out -> Alcotest.fail "supervisor scope waited on unawaited child"
  | `Failed cause ->
      Alcotest.failf "unexpected supervisor failure: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause);
  Alcotest.(check bool) "child finalizer ran" true (Atomic.get released)
