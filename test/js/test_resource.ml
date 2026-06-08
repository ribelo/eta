open Test_support

let tests =
  [
    ("resource_sync",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let value = ref 0 in
       let fail_next = ref false in
       let load =
         Effect.bind
           (fun () ->
             if !fail_next then Effect.fail `Load_failed
             else
               Effect.sync (fun () ->
                   incr value;
                   !value))
           Effect.unit
       in
       let resource =
         match Runtime.run_now runtime (Resource.manual load) with
         | Some (Exit.Ok resource) -> resource
         | _ -> fail "Resource.manual" "expected resource" |> raise
       in
       (match Runtime.run_now runtime (Resource.get resource) with
       | Some exit -> check_exit_ok_int "Resource.get initial" 1 exit
       | None -> fail "Resource.get initial" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Resource.refresh resource) with
       | Some exit -> check_exit_ok_unit "Resource.refresh success" exit
       | None -> fail "Resource.refresh success" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Resource.get resource) with
       | Some exit -> check_exit_ok_int "Resource.get refreshed" 2 exit
       | None -> fail "Resource.get refreshed" "expected sync exit" |> raise);
       fail_next := true;
       (match Runtime.run_now runtime (Resource.refresh resource) with
       | Some (Exit.Error (Cause.Fail `Load_failed)) -> ()
       | _ -> fail "Resource.refresh failure" "expected typed failure" |> raise);
       (match Runtime.run_now runtime (Resource.get resource) with
       | Some exit -> check_exit_ok_int "Resource.keeps cached value" 2 exit
       | None -> fail "Resource.keeps cached value" "expected sync exit" |> raise);
       (match Runtime.run_now runtime (Resource.failures resource) with
       | Some (Exit.Ok []) -> ()
       | _ -> fail "Resource.manual failures" "expected empty failures" |> raise);
       Js.Promise.resolve ());
    ("resource_auto",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let calls = ref 0 in
       let errors = ref 0 in
       let load =
         Effect.bind
           (fun () ->
             incr calls;
             if !calls = 2 then Effect.fail `Refresh_failed
             else Effect.pure !calls)
           Effect.unit
       in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             match exit with
             | Exit.Ok resource ->
                 Js.Promise.then_
                   (fun () ->
                     ignore
                       (Js.Promise.then_
                          (fun get_exit ->
                            check_exit_ok_int "Resource.auto keeps cached value" 1
                              get_exit;
                            Js.Promise.resolve ())
                          (Runtime.run_promise runtime (Resource.get resource)));
                     ignore
                       (Js.Promise.then_
                          (fun failures_exit ->
                            (match failures_exit with
                            | Exit.Ok [ Cause.Fail `Refresh_failed ] -> ()
                            | _ ->
                                fail "Resource.auto failures"
                                  "expected refresh failure"
                                |> raise);
                            check_equal_int "Resource.auto on_error" 1 !errors;
                            Js.Promise.resolve ())
                          (Runtime.run_promise runtime
                             (Resource.failures resource)));
                     Js.Promise.resolve ())
                   (Runtime.drain_promise runtime)
             | Exit.Error _ -> fail "Resource.auto" "expected resource" |> raise)
           (Runtime.run_promise runtime
              (Resource.auto
                 ~on_error:(fun `Refresh_failed -> incr errors)
                 ~load ~schedule:(Schedule.recurs 1) ()))
       in
       p1);
  ]
