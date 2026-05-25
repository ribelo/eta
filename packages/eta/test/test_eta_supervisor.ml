open Eta
open Test
open Test_eta_support

let test_supervisor_observes_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          failures sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Ok [ Cause.Fail `Boom ] -> ()
  | _ -> Alcotest.fail "expected observed child failure"

let test_supervisor_await_rethrows_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Fail `Boom) -> ()
  | _ -> Alcotest.fail "expected await to rethrow child failure"

let test_supervisor_cancel_runs_finalizer () =
  with_test_clock @@ fun _sw clock rt ->
  let finalizer_ran = ref false in
  let child =
    Effect.acquire_release
      ~acquire:(Effect.named "supervisor.acquire" (Effect.sync (fun () -> ())))
      ~release:(fun () ->
        Effect.named "supervisor.release" (Effect.sync (fun () -> finalizer_ran := true)))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
  in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () =
            lift
              (Effect.named "supervisor.wait_for_child" (Effect.sync (fun () ->
                   wait_for_sleepers clock 1)))
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) ->
      Alcotest.(check bool) "finalizer ran" true !finalizer_ran
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_cancel_before_await_does_not_deadlock () =
  with_test_clock @@ fun _sw _clock rt ->
  let child = Effect.delay (Duration.ms 1_000) Effect.unit in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_scope_cancels_unawaited_children_on_return () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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

let test_supervisor_threshold_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped ~max_failures:1 {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child :
                  (s, [> `Boom | `Supervisor_failed of int ], int)
                  Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          check sup;
    }
  in
  match Runtime.run rt program with
| Exit.Error (Cause.Fail (`Supervisor_failed 1)) -> ()
| _ -> Alcotest.fail "expected supervisor threshold failure"

let test_supervisor_records_multiple_failures () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_left : (s, [> `Left | `Right ], unit) Supervisor.child) =
            start sup (fail `Left)
          in
          let* (_right : (s, [> `Left | `Right ], unit) Supervisor.child) =
            start sup (fail `Right)
          in
          let* () = yield in
          failures sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Ok failures ->
      let rendered =
        failures
        |> List.map (function
             | Cause.Fail `Left -> "left"
             | Cause.Fail `Right -> "right"
             | _ -> "other")
        |> List.sort String.compare
      in
      Alcotest.(check (list string)) "failures" [ "left"; "right" ] rendered
  | Exit.Error _ -> Alcotest.fail "expected supervisor failures snapshot"

let test_supervisor_nested_scopes_compose () =
  with_runtime @@ fun rt ->
  let inner =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Inner ], unit) Supervisor.child) =
            start sup (fail `Inner)
          in
          let* () = yield in
          failures sup;
    }
  in
  let outer =
    Supervisor.scoped {
      run =
        fun (_ : (_, _) Supervisor.t) ->
          let open Supervisor.Scope in
          let* inner_failures = lift inner in
          pure (List.length inner_failures);
    }
  in
  Alcotest.(check int) "inner failure observed" 1 (run_ok rt outer)


