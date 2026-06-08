open Supervision_research

let expect name condition =
  if condition then Printf.printf "%s: ok\n%!" name
  else failwith (name ^ ": failed")

let test_f_d_observe_child_failure () =
  match
    F_d_supervisor_scope.Effect.run ~env:()
      (F_d_supervisor_scope.observe_child_failure ())
  with
  | Ok [ F_d_supervisor_scope.Effect.Fail `Boom ] ->
      print_endline "F-D observe child failure: ok"
  | _ -> failwith "F-D observe child failure: wrong result"

let test_f_d_await_child_result () =
  match
    F_d_supervisor_scope.Effect.run ~env:()
      (F_d_supervisor_scope.await_child_result ())
  with
  | Ok 42 -> print_endline "F-D await child result: ok"
  | _ -> failwith "F-D await child result: wrong result"

let test_f_d_cancel_runs_finalizer_and_await_finishes () =
  let open F_d_supervisor_scope.Effect in
  let finalizer_ran = ref false in
  let program =
    supervise {
      run =
        fun (type s) sup ->
          let child_body =
            ensure ~finally:(fun () -> finalizer_ran := true) never
          in
          let** (child : (s, [> `Supervisor_failed of int ], unit) child) =
            start sup child_body
          in
          let** () = yield in
          let** () = cancel child in
          await child;
    }
  in
  match run ~env:() program with
  | Error Interrupt -> expect "F-D cancel finalizer" !finalizer_ran
  | _ -> failwith "F-D cancel should return Interrupt through await"

let test_f_d_threshold_failure () =
  match
    F_d_supervisor_scope.Effect.run ~env:()
      (F_d_supervisor_scope.threshold_failure ())
  with
  | Error (F_d_supervisor_scope.Effect.Fail (`Supervisor_failed 1)) ->
      print_endline "F-D threshold failure: ok"
  | _ -> failwith "F-D threshold failure: wrong result"

let test_f_d_resource_auto_failure_observable () =
  match
    F_d_supervisor_scope.Effect.run ~env:()
      (F_d_supervisor_scope.resource_auto_refresh_observable ())
  with
  | Ok (1, [ F_d_supervisor_scope.Effect.Fail `Refresh ]) ->
      print_endline "F-D Resource.auto-shaped failure sink: ok"
  | _ -> failwith "F-D Resource.auto-shaped failure sink: wrong result"

let test_f_d_nested_supervisors_do_not_unwind_outer () =
  let open F_d_supervisor_scope.Effect in
  let program =
    supervise {
      run =
        fun (type outer) outer_sup ->
          let inner =
            supervise {
              run =
                fun (type inner) inner_sup ->
                  let** (_child :
                          (inner, [> `Inner | `Supervisor_failed of int ], unit) child) =
                    start inner_sup (s_fail `Inner)
                  in
                  let** () = yield in
                  observe inner_sup;
            }
          in
          let** inner_failures = s_lift inner in
          let** outer_failures = observe outer_sup in
          s_pure (List.length inner_failures, List.length outer_failures);
    }
  in
  match run ~env:() program with
  | Ok (1, 0) -> print_endline "F-D nested supervisors: ok"
  | _ -> failwith "F-D nested supervisors: wrong result"

let test_f_e_strategies () =
  let open F_e_supervisor_strategies in
  let one_for_one_restarts =
    List.exists
      (function Supervisor.Restarted ("bad", 1) -> true | _ -> false)
      one_for_one_only_restarts_failed.events
  in
  let one_for_all_restarts =
    List.exists
      (function Supervisor.Restarted ("*", 1) -> true | _ -> false)
      one_for_all_restarts_everyone.events
  in
  expect "F-E one-for-one" one_for_one_restarts;
  expect "F-E one-for-all" one_for_all_restarts

let test_f_f_ambient () =
  match
    F_f_ambient_nursery.Nursery.run ~env:()
      (F_f_ambient_nursery.await_child ())
  with
  | Ok 5 -> print_endline "F-F ambient nursery: ok"
  | _ -> failwith "F-F ambient nursery: wrong result"

let test_f_g_detach_only () =
  let open F_g_detach_only in
  expect "F-G swallowed" (swallowed_without_callback = Ok ());
  expect "F-G callback" (side_channel_callback = 1)

let () =
  test_f_d_observe_child_failure ();
  test_f_d_await_child_result ();
  test_f_d_cancel_runs_finalizer_and_await_finishes ();
  test_f_d_threshold_failure ();
  test_f_d_resource_auto_failure_observable ();
  test_f_d_nested_supervisors_do_not_unwind_outer ();
  test_f_e_strategies ();
  test_f_f_ambient ();
  test_f_g_detach_only ();
  print_endline "supervision research smoke tests passed"
