module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let fail_test message = failwith message
let suite_completed = ref false

let () =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.meth_call process "on"
    [|
      Unsafe.inject (Js.string "beforeExit");
      Unsafe.inject
        (Js.wrap_callback (fun _code ->
             if not !suite_completed then (
               set_exit_code 1;
               log "eta_js_jsoo failed: test chain did not reach completion")));
    |]
  |> ignore;
  Unsafe.meth_call process "on"
    [|
      Unsafe.inject (Js.string "unhandledRejection");
      Unsafe.inject
        (Js.wrap_callback (fun _reason _promise ->
             set_exit_code 1;
             log "eta_js_jsoo failed: unhandled host promise rejection"));
    |]
  |> ignore
let pp_err fmt _ = Format.pp_print_string fmt "<err>"
let pp_cause cause = Format.asprintf "%a" (Eta_js.Cause.pp pp_err) cause

let finish done_ f value =
  try
    f value;
    done_ ()
  with exn ->
    set_exit_code 1;
    log ("eta_js_jsoo failed: " ^ Printexc.to_string exn)

let run eff ~on_result =
  let runtime = Eta_js.Runtime.create () in
  Eta_js.Runtime.run runtime eff ~on_result

let expect_ok_int name expected = function
  | Eta_js.Exit.Ok actual when actual = expected -> ()
  | Eta_js.Exit.Ok actual ->
      fail_test
        (Printf.sprintf "%s: expected Ok %d, got Ok %d" name expected actual)
  | Eta_js.Exit.Error cause ->
      fail_test
        (Printf.sprintf "%s: expected Ok %d, got %s" name expected
           (pp_cause cause))

let expect_ok_pair name expected = function
  | Eta_js.Exit.Ok actual when actual = expected -> ()
  | Eta_js.Exit.Ok _ -> fail_test (name ^ ": unexpected Ok pair")
  | Eta_js.Exit.Error cause ->
      fail_test
        (Printf.sprintf "%s: expected Ok pair, got %s" name (pp_cause cause))

let expect_fail name pred = function
  | Eta_js.Exit.Error (Eta_js.Cause.Fail err) when pred err -> ()
  | Eta_js.Exit.Error cause ->
      fail_test
        (Printf.sprintf "%s: expected typed failure, got %s" name
           (pp_cause cause))
  | Eta_js.Exit.Ok _ -> fail_test (name ^ ": expected typed failure, got Ok")

let test_runtime_delay done_ =
  run
    (Eta_js.Effect.delay (Eta_js.Duration.ms 1) (Eta_js.Effect.pure 42))
    ~on_result:(finish done_ (expect_ok_int "runtime delay" 42))

let test_pure_bind_catch done_ =
  let eff =
    Eta_js.Effect.fail `Bad
    |> Eta_js.Effect.bind_error (function `Bad -> Eta_js.Effect.pure 40)
    |> Eta_js.Effect.bind (fun value -> Eta_js.Effect.pure (value + 2))
  in
  run eff ~on_result:(finish done_ (expect_ok_int "pure/bind/catch" 42))

let test_map_error done_ =
  let eff =
    Eta_js.Effect.map_error
      (function `Old -> `New)
      (Eta_js.Effect.fail `Old)
  in
  run eff ~on_result:(finish done_ (expect_fail "map_error" (( = ) `New)))

let test_sync_defect done_ =
  run (Eta_js.Effect.sync (fun () -> raise (Failure "boom")))
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Error (Eta_js.Cause.Die _) -> ()
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "sync defect: expected Die, got %s"
                 (pp_cause cause))
        | Eta_js.Exit.Ok _ -> fail_test "sync defect: expected Die, got Ok"))

let test_timeout_releases_resource done_ =
  let released = ref false in
  let acquire = Eta_js.Effect.unit in
  let release () = Eta_js.Effect.sync (fun () -> released := true) in
  let body =
    Eta_js.Effect.with_scope
      (Eta_js.Effect.acquire_release ~acquire ~release
       |> Eta_js.Effect.bind (fun () ->
              Eta_js.Effect.delay (Eta_js.Duration.seconds 1)
                Eta_js.Effect.unit))
  in
  run
    (Eta_js.Effect.timeout_as (Eta_js.Duration.ms 5) ~on_timeout:`Timeout
       body)
    ~on_result:
      (finish done_ (fun result ->
           expect_fail "timeout releases resource" (( = ) `Timeout) result;
           if not !released then
             fail_test "timeout releases resource: release not run"))

let test_par_all_race done_ =
  let eff =
    Eta_js.Effect.par (Eta_js.Effect.pure 1) (Eta_js.Effect.pure 2)
    |> Eta_js.Effect.bind (fun (left, right) ->
           Eta_js.Effect.all
             [ Eta_js.Effect.pure (left + right); Eta_js.Effect.pure 4 ]
           |> Eta_js.Effect.bind (fun values ->
                  Eta_js.Effect.race
                    [
                      Eta_js.Effect.delay (Eta_js.Duration.ms 20)
                        (Eta_js.Effect.pure 100);
                      Eta_js.Effect.delay (Eta_js.Duration.ms 1)
                        (Eta_js.Effect.pure 5);
                    ]
                  |> Eta_js.Effect.map (fun winner ->
                         List.fold_left ( + ) winner values)))
  in
  run eff ~on_result:(finish done_ (expect_ok_int "par/all/race" 12))

let test_all_settled done_ =
  let eff =
    Eta_js.Effect.all_settled
      [ Eta_js.Effect.pure 1; Eta_js.Effect.fail `Nope ]
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Ok [ Ok 1; Error (Eta_js.Cause.Fail `Nope) ] -> ()
        | Eta_js.Exit.Ok _ -> fail_test "all_settled: unexpected result list"
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "all_settled: expected Ok list, got %s"
                 (pp_cause cause))))

let test_acquire_release_failure done_ =
  let released = ref false in
  let eff =
    Eta_js.Effect.with_scope
      (Eta_js.Effect.acquire_release
         ~acquire:(Eta_js.Effect.pure 7)
         ~release:(fun _ -> Eta_js.Effect.sync (fun () -> released := true))
       |> Eta_js.Effect.bind (fun _ -> Eta_js.Effect.fail `Boom))
  in
  run eff
    ~on_result:
      (finish done_ (fun result ->
           expect_fail "acquire_release failure" (( = ) `Boom) result;
           if not !released then
             fail_test "acquire_release failure: release not run"))

let test_release_failure_after_success done_ =
  let eff =
    Eta_js.Effect.with_scope
      (Eta_js.Effect.acquire_release
         ~acquire:(Eta_js.Effect.pure ())
         ~release:(fun () -> Eta_js.Effect.fail `Cleanup))
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Error
            (Eta_js.Cause.Finalizer (Eta_js.Cause.Finalizer.Fail _)) ->
            ()
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "release failure: expected Finalizer, got %s"
                 (pp_cause cause))
        | Eta_js.Exit.Ok _ -> fail_test "release failure: expected Finalizer"))

let test_suppressed_release_failure done_ =
  let eff =
    Eta_js.Effect.with_scope
      (Eta_js.Effect.acquire_release
         ~acquire:(Eta_js.Effect.pure ())
         ~release:(fun () -> Eta_js.Effect.fail `Cleanup)
       |> Eta_js.Effect.bind (fun () -> Eta_js.Effect.fail `Primary))
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Error
            (Eta_js.Cause.Suppressed
              {
                primary = Eta_js.Cause.Fail `Primary;
                finalizer = Eta_js.Cause.Finalizer.Fail _;
              }) ->
            ()
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf
                 "suppressed release failure: expected Suppressed, got %s"
                 (pp_cause cause))
        | Eta_js.Exit.Ok _ ->
            fail_test "suppressed release failure: expected failure"))

let test_retry_schedule done_ =
  let attempts = ref 0 in
  let attempt =
    Eta_js.Effect.sync (fun () -> incr attempts)
    |> Eta_js.Effect.bind (fun () ->
           if !attempts < 3 then Eta_js.Effect.fail `Retry
           else Eta_js.Effect.pure !attempts)
  in
  run
    (Eta_js.Effect.retry
       ~schedule:(Eta_js.Schedule.recurs 3)
       ~while_:(function `Retry -> true)
       attempt)
    ~on_result:(finish done_ (expect_ok_int "retry schedule" 3))

let test_repeat_schedule done_ =
  let ticks = ref 0 in
  let tick = Eta_js.Effect.sync (fun () -> incr ticks) in
  let eff =
    Eta_js.Effect.repeat ~schedule:(Eta_js.Schedule.recurs 2) tick
    |> Eta_js.Effect.bind (fun (_repeat_count : int) ->
           Eta_js.Effect.sync (fun () -> !ticks))
  in
  run eff ~on_result:(finish done_ (expect_ok_int "repeat schedule" 3))

let test_queue_facade done_ =
  let queue = Eta_js.Queue.unbounded () in
  let eff =
    Eta_js.Queue.send queue 11
    |> Eta_js.Effect.bind (fun () -> Eta_js.Queue.take queue)
  in
  run eff ~on_result:(finish done_ (expect_ok_int "queue facade" 11))

let test_channel_facade done_ =
  let channel = Eta_js.Channel.create ~capacity:1 () in
  let eff =
    Eta_js.Effect.par
      (Eta_js.Channel.send channel 7)
      (Eta_js.Channel.recv channel)
    |> Eta_js.Effect.map snd
  in
  run eff ~on_result:(finish done_ (expect_ok_int "channel facade" 7))

let test_semaphore_facade done_ =
  let semaphore = Eta_js.Semaphore.make ~permits:1 in
  let inside = ref (-1) in
  let eff =
    Eta_js.Semaphore.with_permits semaphore 1 (fun () ->
        Eta_js.Effect.sync (fun () ->
            inside := Eta_js.Semaphore.available semaphore))
    |> Eta_js.Effect.bind (fun () ->
           Eta_js.Effect.sync (fun () ->
               (!inside, Eta_js.Semaphore.available semaphore)))
  in
  run eff ~on_result:(finish done_ (expect_ok_pair "semaphore facade" (0, 1)))

let test_pubsub_facade done_ =
  let hub = Eta_js.Pubsub.create ~overflow:Eta_js.Pubsub.Unbounded () in
  let eff =
    Eta_js.Pubsub.subscribe hub (fun sub ->
        Eta_js.Effect.par
          (Eta_js.Pubsub.publish hub 5)
          (Eta_js.Pubsub.recv sub)
        |> Eta_js.Effect.map snd)
  in
  run eff ~on_result:(finish done_ (expect_ok_int "pubsub facade" 5))

let test_supervisor_observes_failure done_ =
  let eff =
    Eta_js.Supervisor.scoped
      {
        run =
          (fun (type s) sup ->
            let open Eta_js.Supervisor.Scope in
            let* (_child : (s, [> `Boom ], int) Eta_js.Supervisor.child) =
              start sup (fail `Boom)
            in
            let* () = yield in
            failures sup);
      }
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Ok [ Eta_js.Cause.Fail `Boom ] -> ()
        | Eta_js.Exit.Ok _ -> fail_test "supervisor: unexpected failure list"
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "supervisor: expected observed failure, got %s"
                 (pp_cause cause))))

let promise_constructor () = Unsafe.get Unsafe.global "Promise"

let resolved_promise value =
  Unsafe.meth_call (promise_constructor ()) "resolve"
    [| Unsafe.inject value |]

let rejected_promise reason =
  Unsafe.meth_call (promise_constructor ()) "reject"
    [| Unsafe.inject reason |]

let deferred_promise () =
  let resolve = ref (fun _ -> ()) in
  let reject = ref (fun _ -> ()) in
  let promise =
    Unsafe.new_obj (promise_constructor ())
      [|
        Unsafe.inject
          (Js.wrap_callback (fun on_resolve on_reject ->
               resolve :=
                 fun value ->
                   ignore
                     (Unsafe.fun_call on_resolve [| Unsafe.inject value |]);
               reject :=
                 fun reason ->
                   ignore
                     (Unsafe.fun_call on_reject [| Unsafe.inject reason |])));
      |]
  in
  (promise, (fun value -> !resolve value), fun reason -> !reject reason)

let test_from_js_promise_pending_resolves_after_registration done_ =
  let promise, js_resolve, _js_reject = deferred_promise () in
  let eff =
    Eta_js.Effect.par
      (Eta_js.from_js_promise ~on_reject:(fun _ -> `Rejected) promise)
      (Eta_js.Effect.delay (Eta_js.Duration.ms 1)
         (Eta_js.Effect.sync (fun () -> js_resolve 42)))
    |> Eta_js.Effect.map fst
  in
  run eff
    ~on_result:(finish done_ (expect_ok_int "from_js_promise resolve" 42))

let test_from_js_promise_already_settled done_ =
  let promise = resolved_promise 7 in
  run
    (Eta_js.from_js_promise ~on_reject:(fun _ -> `Rejected) promise)
    ~on_result:
      (finish done_ (expect_ok_int "from_js_promise already settled" 7))

let test_from_js_promise_reject_maps_typed_failure done_ =
  run
    (Eta_js.Effect.sync (fun () ->
         rejected_promise
           (Unsafe.new_obj (Unsafe.get Unsafe.global "Error")
              [| Unsafe.inject (Js.string "boom") |]))
     |> Eta_js.Effect.bind (fun promise ->
            Eta_js.from_js_promise
              ~on_reject:(fun reason ->
                `Message (Js.to_string (Unsafe.get reason "message")))
              promise))
    ~on_result:
      (finish done_
         (expect_fail "from_js_promise reject"
            (( = ) (`Message "boom"))))

let test_from_js_promise_non_error_rejection_fidelity done_ =
  run
    (Eta_js.Effect.sync (fun () -> rejected_promise 42)
     |> Eta_js.Effect.bind (fun promise ->
            Eta_js.from_js_promise
              ~on_reject:(fun reason ->
                `Code (Js.float_of_number (Unsafe.coerce reason)))
              promise))
    ~on_result:
      (finish done_
         (expect_fail "from_js_promise reject 42" (( = ) (`Code 42.0))))

let test_from_js_promise_raising_mapper_dies done_ =
  let eff =
    Eta_js.Effect.sync (fun () -> rejected_promise (Js.string "boom"))
    |> Eta_js.Effect.bind (fun promise ->
           Eta_js.from_js_promise
             ~on_reject:(fun _ -> failwith "mapper failed")
             promise)
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Error cause when Eta_js.Cause.defects cause <> [] -> ()
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "from_js_promise raising mapper: got %s"
                 (pp_cause cause))
        | Eta_js.Exit.Ok _ ->
            fail_test "from_js_promise raising mapper: expected Die"))

let test_from_js_promise_first_settlement_wins done_ =
  let promise, js_resolve, js_reject = deferred_promise () in
  let eff =
    Eta_js.Effect.par
      (Eta_js.from_js_promise ~on_reject:(fun _ -> `Rejected) promise)
      (Eta_js.Effect.delay (Eta_js.Duration.ms 1)
         (Eta_js.Effect.sync (fun () ->
              js_resolve 11;
              js_reject (Js.string "late");
              js_resolve 12)))
    |> Eta_js.Effect.map fst
  in
  run eff
    ~on_result:
      (finish done_ (expect_ok_int "from_js_promise first settlement" 11))

let test_from_js_promise_interrupt_detaches done_ =
  let promise, js_resolve, _js_reject = deferred_promise () in
  let cancel_count = ref 0 in
  let awaited =
    Eta_js.Effect.timeout_as (Eta_js.Duration.ms 5) ~on_timeout:`Timeout
      (Eta_js.from_js_promise
         ~on_cancel:(fun () -> incr cancel_count)
         ~on_reject:(fun _ -> `Rejected)
         promise)
  in
  let eff =
    Eta_js.Effect.bind_error
      (function
        | `Timeout ->
            (* The host promise settles after the waiter detached: the late
               settlement must be dropped silently. *)
            Eta_js.Effect.sync (fun () -> js_resolve 7)
            |> Eta_js.Effect.bind (fun () ->
                   Eta_js.Effect.delay (Eta_js.Duration.ms 10)
                     (Eta_js.Effect.pure `Recovered))
        | `Rejected -> Eta_js.Effect.fail `Unexpected)
      awaited
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Ok `Recovered ->
            if !cancel_count <> 1 then
              fail_test
                (Printf.sprintf
                   "from_js_promise interrupt: on_cancel ran %d times"
                   !cancel_count)
        | Eta_js.Exit.Ok _ ->
            fail_test "from_js_promise interrupt: unexpected success"
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "from_js_promise interrupt: got %s"
                 (pp_cause cause))))

let test_from_js_promise_late_rejection_skips_mapper done_ =
  let promise, _js_resolve, js_reject = deferred_promise () in
  let mapper_calls = ref 0 in
  let awaited =
    Eta_js.Effect.timeout_as (Eta_js.Duration.ms 5) ~on_timeout:`Timeout
      (Eta_js.from_js_promise
         ~on_reject:(fun _ ->
           incr mapper_calls;
           `Rejected)
         promise)
  in
  let eff =
    Eta_js.Effect.bind_error
      (function
        | `Timeout ->
            (* Rejection after detach must not surface as an unhandled host
               rejection: the handlers stay attached. *)
            Eta_js.Effect.sync (fun () -> js_reject (Js.string "late"))
            |> Eta_js.Effect.bind (fun () ->
                   Eta_js.Effect.delay (Eta_js.Duration.ms 10)
                     (Eta_js.Effect.sync (fun () ->
                          if !mapper_calls <> 0 then
                            fail_test
                              "from_js_promise detach reject: mapper ran";
                          `Recovered)))
        | `Rejected -> Eta_js.Effect.fail `Unexpected)
      awaited
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta_js.Exit.Ok `Recovered -> ()
        | Eta_js.Exit.Ok _ ->
            fail_test "from_js_promise detach reject: unexpected success"
        | Eta_js.Exit.Error cause ->
            fail_test
              (Printf.sprintf "from_js_promise detach reject: got %s"
                 (pp_cause cause))))

let test_from_js_promise_non_thenable_dies done_ =
  let forged_without_then = Unsafe.obj [||] in
  let forged_with_int_then =
    Unsafe.obj [| ("then", Unsafe.inject 1) |]
  in
  let await_forged forged =
    Eta_js.from_js_promise ~on_reject:(fun _ -> `Rejected) forged
  in
  let expect_die name = function
    | Eta_js.Exit.Error cause when Eta_js.Cause.defects cause <> [] -> ()
    | Eta_js.Exit.Error cause ->
        fail_test
          (Printf.sprintf "%s: expected Die, got %s" name (pp_cause cause))
    | Eta_js.Exit.Ok _ -> fail_test (name ^ ": expected Die, got Ok")
  in
  run (await_forged forged_without_then)
    ~on_result:
      (finish
         (fun () ->
           run (await_forged forged_with_int_then)
             ~on_result:
               (finish done_ (expect_die "from_js_promise forged then")))
         (expect_die "from_js_promise missing then"))

let tests =
  [
    ("eta_js runtime delay", test_runtime_delay);
    ("eta_js pure/bind/catch", test_pure_bind_catch);
    ("eta_js map_error", test_map_error);
    ("eta_js sync defect", test_sync_defect);
    ("eta_js timeout releases resource", test_timeout_releases_resource);
    ("eta_js par/all/race", test_par_all_race);
    ("eta_js all_settled", test_all_settled);
    ("eta_js acquire_release failure", test_acquire_release_failure);
    ("eta_js release failure after success", test_release_failure_after_success);
    ("eta_js suppressed release failure", test_suppressed_release_failure);
    ("eta_js retry schedule", test_retry_schedule);
    ("eta_js repeat schedule", test_repeat_schedule);
    ("eta_js queue facade", test_queue_facade);
    ("eta_js channel facade", test_channel_facade);
    ("eta_js semaphore facade", test_semaphore_facade);
    ("eta_js pubsub facade", test_pubsub_facade);
    ("eta_js supervisor observes failure", test_supervisor_observes_failure);
    ( "eta_js from_js_promise pending resolves after registration",
      test_from_js_promise_pending_resolves_after_registration );
    ( "eta_js from_js_promise already settled",
      test_from_js_promise_already_settled );
    ( "eta_js from_js_promise reject maps typed failure",
      test_from_js_promise_reject_maps_typed_failure );
    ( "eta_js from_js_promise non-error rejection fidelity",
      test_from_js_promise_non_error_rejection_fidelity );
    ( "eta_js from_js_promise raising mapper dies",
      test_from_js_promise_raising_mapper_dies );
    ( "eta_js from_js_promise first settlement wins",
      test_from_js_promise_first_settlement_wins );
    ( "eta_js from_js_promise interrupt detaches",
      test_from_js_promise_interrupt_detaches );
    ( "eta_js from_js_promise late rejection skips mapper",
      test_from_js_promise_late_rejection_skips_mapper );
    ( "eta_js from_js_promise non-thenable dies",
      test_from_js_promise_non_thenable_dies );
  ]

let rec run_tests = function
  | [] ->
      suite_completed := true;
      log "eta_js_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_js_jsoo failed: " ^ Printexc.to_string exn)
