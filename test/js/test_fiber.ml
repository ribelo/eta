open Test_support

let tests =
  [
    ("fiber_fork_join",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Fiber.fork join" 42 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.bind
                 (fun handle -> Fiber.join handle)
                 (Effect.fork (Effect.pure 42))))
       in
       p);
    ("fiber_await_typed_failure",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok (Error (Cause.Fail `Boom)) -> ()
             | _ -> fail "Fiber.await typed failure" "expected Error Cause.Fail"
               |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.bind
                 (fun handle -> Fiber.await handle)
                 (Effect.fork (Effect.fail `Boom))))
       in
       p);
    ("fiber_interrupt",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let loser_cancelled = ref false in
       let losing =
         Effect.Expert.async_leaf (fun _context ~resume:_ ~on_cancel ->
             on_cancel (fun () -> loser_cancelled := true))
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok (Error (Cause.Interrupt _)) -> ()
             | _ -> fail "Fiber.interrupt" "expected interrupt" |> raise);
             check "Fiber.interrupt cancels loser" !loser_cancelled;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.bind
                 (fun handle ->
                   Effect.seq (Fiber.interrupt handle) (Fiber.await handle))
                 (Effect.fork losing)))
       in
       p);
    ("fiber_poll",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let handle_ref = ref None in
       let body =
         Effect.bind
           (fun handle ->
             handle_ref := Some handle;
             Effect.pure ())
           (Effect.fork (Effect.delay (Duration.ms 1) (Effect.pure 99)))
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok () -> ()
             | _ -> fail "Fiber.poll setup" "expected ok" |> raise);
             (match !handle_ref with
             | Some handle ->
                 check "Fiber.poll before completion" (Fiber.poll handle = None)
             | None -> fail "Fiber.poll" "missing handle" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime body)
       in
       p);
    ("fiber_daemon",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let daemon_ran = ref false in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok () -> ()
             | _ -> fail "Fiber.fork_daemon" "expected ok" |> raise);
             Js.Promise.then_
               (fun () ->
                 check "Fiber.fork_daemon ran" !daemon_ran;
                 Js.Promise.resolve ())
               (Runtime.drain_promise runtime))
           (Runtime.run_promise runtime
              (Effect.fork_daemon
                 (Effect.delay Duration.zero
                    (Effect.sync (fun () -> daemon_ran := true)))))
       in
       p);
    ("fiber_scope",
     fun () ->
       let open Eta_js in
       let scheduler = Scheduler.create () in
       let root = Runtime_fiber.create_root ~scheduler in
       let key = Runtime_local.create () in
       Runtime_fiber.local_set root key "parent";
       let child = Runtime_fiber.create_child root in
       check "Fiber child count" (Runtime_fiber.child_count root = 1);
       check "Scope child count" (Scope.child_count (Runtime_fiber.scope root) = 1);
       check "Fiber local inherited" (Runtime_fiber.local_get child key = Some "parent");
       Runtime_fiber.local_set child key "child";
       check "Fiber local child update isolated"
         (Runtime_fiber.local_get root key = Some "parent");
       let observed = ref false in
       Runtime_fiber.observe child (fun _ -> observed := true);
       Runtime_fiber.finish child (Runtime_fiber.Exit (Exit.ok ()));
       check "Fiber observer scheduled" (not !observed);
       Scheduler.drain_ready scheduler;
       check "Fiber observer ran" !observed;
       check "Fiber child removed from parent" (Runtime_fiber.child_count root = 0);
       check "Fiber child removed from scope"
         (Scope.child_count (Runtime_fiber.scope root) = 0);
       let double_finish_failed =
         try
           Runtime_fiber.finish child (Runtime_fiber.Exit (Exit.ok ()));
           false
         with Invalid_argument _ -> true
       in
       check "Fiber finish rejects double finish" double_finish_failed;

       let root = Runtime_fiber.create_root ~scheduler in
       let child = Runtime_fiber.create_child root in
       let closed = ref false in
       Scope.close (Runtime_fiber.scope root) ~scheduler (fun () -> closed := true);
       check "Scope close cancels child"
         (Option.is_some (Runtime_fiber.cancel_cause child));
       Scheduler.drain_ready scheduler;
       check "Scope close waits for child" (not !closed);
       Runtime_fiber.finish child (Runtime_fiber.Exit (Exit.ok ()));
       Scheduler.drain_ready scheduler;
       check "Scope close resumes after child done" !closed;
       Js.Promise.resolve ());
  ]
