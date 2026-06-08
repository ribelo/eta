open Test_support

let tests =
  [
    ("semaphore_sync",
     fun () ->
       let open Eta_js in
       let rejected =
         try
           ignore (Semaphore.make ~permits:0);
           false
         with Invalid_argument _ -> true
       in
       check "Semaphore.make rejects zero" rejected;
       let runtime = Runtime.create () in
       let semaphore = Semaphore.make ~permits:2 in
       check "Semaphore.try_acquire" (Semaphore.try_acquire semaphore 1);
       check_equal_int "Semaphore.available after acquire" 1
         (Semaphore.available semaphore);
       Semaphore.release semaphore 1;
       check_equal_int "Semaphore.available after release" 2
         (Semaphore.available semaphore);
       (match
          Runtime.run_now runtime
            (Semaphore.with_permits semaphore 2 (fun () -> Effect.pure 42))
        with
       | Some exit -> check_exit_ok_int "Semaphore.with_permits success" 42 exit
       | None -> fail "Semaphore.with_permits success" "expected sync exit" |> raise);
       check_equal_int "Semaphore.with_permits releases success" 2
         (Semaphore.available semaphore);
       (match
          Runtime.run_now runtime
            (Semaphore.with_permits semaphore 2 (fun () -> Effect.fail 7))
        with
       | Some exit -> check_exit_fail_int "Semaphore.with_permits failure" 7 exit
       | None -> fail "Semaphore.with_permits failure" "expected sync exit" |> raise);
       check_equal_int "Semaphore.with_permits releases failure" 2
         (Semaphore.available semaphore);
       Js.Promise.resolve ());
    ("semaphore_acquire_waits",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let semaphore = Semaphore.make ~permits:1 in
       check "Semaphore initial acquire for wait test"
         (Semaphore.try_acquire semaphore 1);
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "Semaphore.acquire waits" exit;
             check_equal_int "Semaphore.acquire consumes released permit" 0
               (Semaphore.available semaphore);
             Semaphore.release semaphore 1;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Semaphore.acquire semaphore 1))
       in
       check_equal_int "Semaphore.waiting before release" 1
         (Semaphore.waiting semaphore);
       Semaphore.release semaphore 1;
       p1);
    ("semaphore_acquire_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let semaphore = Semaphore.make ~permits:1 in
       check "Semaphore initial acquire for cancel test"
         (Semaphore.try_acquire semaphore 1);
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Semaphore.acquire cancellation" "expected timeout" |> raise);
             check_equal_int "Semaphore.waiting after cancel" 0
               (Semaphore.waiting semaphore);
             check_equal_int "Semaphore.cancelled_waiters" 1
               (Semaphore.cancelled_waiters semaphore);
             Semaphore.release semaphore 1;
             check_equal_int "Semaphore.available after cancel release" 1
               (Semaphore.available semaphore);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero (Semaphore.acquire semaphore 1)))
       in
       p1);
  ]
