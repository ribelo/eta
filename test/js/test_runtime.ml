open Test_support

let test_scheduler () =
  let open Eta_js in
  check "Js_interop.date_now" (Js_interop.date_now () >= 0.0);
  let scheduler = Scheduler.create ~max_ops_before_yield:3 () in
  let seen = ref [] in
  let record value () = seen := value :: !seen in
  Scheduler.enqueue scheduler ~priority:1 (record 3);
  Scheduler.enqueue scheduler ~priority:0 (record 1);
  Scheduler.enqueue scheduler ~priority:0 (record 2);
  check_equal_int "Scheduler.ready_count" 3 (Scheduler.ready_count scheduler);
  Scheduler.drain_ready scheduler;
  check "Scheduler priority fifo" (!seen = [ 3; 2; 1 ]);
  check "Scheduler.should_yield false"
    (not (Scheduler.should_yield scheduler ~op_count:2));
  check "Scheduler.should_yield true"
    (Scheduler.should_yield scheduler ~op_count:3);
  Js.Promise.resolve ()

let test_runtime_promise () =
  let open Eta_js in
  let scheduler = Scheduler.create () in
  let promise, resolver = Runtime_promise.create () in
  let seen = ref [] in
  Runtime_promise.await promise ~scheduler (fun value -> seen := value :: !seen);
  Runtime_promise.resolve resolver 10;
  Scheduler.drain_ready scheduler;
  check "Runtime_promise await before resolve" (!seen = [ 10 ]);
  let promise, resolver = Runtime_promise.create () in
  Runtime_promise.resolve resolver 20;
  Runtime_promise.await promise ~scheduler (fun value -> seen := value :: !seen);
  Scheduler.drain_ready scheduler;
  check "Runtime_promise resolve before await" (!seen = [ 20; 10 ]);
  check "Runtime_promise peek" (Runtime_promise.peek promise = Some 20);
  let double_resolve_failed =
    try
      Runtime_promise.resolve resolver 30;
      false
    with Invalid_argument _ -> true
  in
  check "Runtime_promise double resolve" double_resolve_failed;
  Js.Promise.resolve ()

let test_runtime_stream () =
  let open Eta_js in
  let scheduler = Scheduler.create () in
  let stream = Runtime_stream.create 2 in
  Runtime_stream.add stream ~scheduler 1;
  Runtime_stream.add stream ~scheduler 2;
  check "Runtime_stream length" (Runtime_stream.length stream = 2);
  check "Runtime_stream take_nonblocking 1"
    (Runtime_stream.take_nonblocking stream = Some 1);
  let seen = ref [] in
  Runtime_stream.take stream ~scheduler (fun value -> seen := value :: !seen);
  Scheduler.drain_ready scheduler;
  check "Runtime_stream take buffered" (!seen = [ 2 ]);
  Runtime_stream.take stream ~scheduler (fun value -> seen := value :: !seen);
  check "Runtime_stream taker_count" (Runtime_stream.taker_count stream = 1);
  Runtime_stream.add stream ~scheduler 3;
  Scheduler.drain_ready scheduler;
  check "Runtime_stream take before add" (!seen = [ 3; 2 ]);
  Runtime_stream.add stream ~scheduler 4;
  Runtime_stream.add stream ~scheduler 5;
  let overflow_failed =
    try
      Runtime_stream.add stream ~scheduler 6;
      false
    with Invalid_argument _ -> true
  in
  check "Runtime_stream overflow" overflow_failed;
  Js.Promise.resolve ()

let test_runtime_local () =
  let open Eta_js in
  let key = Runtime_local.create () in
  let table = Runtime_local.create_table () in
  check "Runtime_local initially empty" (Runtime_local.get table key = None);
  Runtime_local.set table key 1;
  check "Runtime_local set" (Runtime_local.get table key = Some 1);
  Runtime_local.with_binding table key 2 (fun () ->
      check "Runtime_local with_binding" (Runtime_local.get table key = Some 2));
  check "Runtime_local restore" (Runtime_local.get table key = Some 1);
  let copied = Runtime_local.copy_table table in
  Runtime_local.set copied key 3;
  check "Runtime_local copy independent original"
    (Runtime_local.get table key = Some 1);
  check "Runtime_local copy independent copy"
    (Runtime_local.get copied key = Some 3);
  Js.Promise.resolve ()

let test_mutable_ref () =
  let open Eta_js in
  let cell = Mutable_ref.make 1 in
  check_equal_int "Mutable_ref.get" 1 (Mutable_ref.get cell);
  Mutable_ref.set cell 2;
  check_equal_int "Mutable_ref.set" 2 (Mutable_ref.get cell);
  check "Mutable_ref.compare_and_set success"
    (Mutable_ref.compare_and_set cell 2 3);
  check_equal_int "Mutable_ref.compare_and_set value" 3
    (Mutable_ref.get cell);
  check "Mutable_ref.compare_and_set failure"
    (not (Mutable_ref.compare_and_set cell 2 4));
  check_equal_int "Mutable_ref.get_and_set" 3
    (Mutable_ref.get_and_set cell 5);
  Mutable_ref.incr cell;
  Mutable_ref.decr cell;
  check_equal_int "Mutable_ref.incr decr" 5
    (Mutable_ref.update_and_get cell (( + ) 0));
  Js.Promise.resolve ()

let test_effect_runtime_sync () =
  let open Eta_js in
  let runtime = Runtime.create () in
  let mapped = Effect.map (fun value -> value + 1) (Effect.pure 41) in
  (match Runtime.run_now runtime mapped with
  | Some exit -> check_exit_ok_int "Runtime.run_now pure" 42 exit
  | None -> fail "Runtime.run_now pure" "expected sync exit" |> raise);
  let caught =
    Effect.catch
      (fun err -> Effect.pure (String.length err))
      (Effect.fail "typed")
  in
  (match Runtime.run_now runtime caught with
  | Some exit -> check_exit_ok_int "Effect.catch typed fail" 5 exit
  | None -> fail "Effect.catch typed fail" "expected sync exit" |> raise);
  let mapped_error = Effect.map_error String.length (Effect.fail "abc") in
  (match Runtime.run_now runtime mapped_error with
  | Some exit -> check_exit_fail_int "Effect.map_error" 3 exit
  | None -> fail "Effect.map_error" "expected sync exit" |> raise);
  let defect =
    Runtime.run_now runtime (Effect.sync (fun () -> failwith "boom"))
  in
  (match defect with
  | Some (Exit.Error (Cause.Die _)) -> ()
  | _ -> fail "Effect.sync defect" "expected Die cause" |> raise);
  (match Runtime.run_now runtime Effect.check with
  | Some (Exit.Ok ()) -> ()
  | _ -> fail "Effect.check uncancelled" "expected ok" |> raise);
  let cleanup_ran = ref false in
  (match
     Runtime.run_now runtime
       (Effect.finally
          (Effect.sync (fun () -> cleanup_ran := true))
          (Effect.pure 11))
   with
  | Some exit -> check_exit_ok_int "Effect.finally success" 11 exit
  | None -> fail "Effect.finally success" "expected sync exit" |> raise);
  check "Effect.finally cleanup ran" !cleanup_ran;
  (match
     Runtime.run_now runtime
       (Effect.finally Effect.unit (Effect.fail 12))
   with
  | Some exit -> check_exit_fail_int "Effect.finally preserves primary fail" 12 exit
  | None -> fail "Effect.finally preserves primary fail" "expected sync exit" |> raise);
  (match
     Runtime.run_now runtime
       (Effect.finally (Effect.fail "cleanup") (Effect.pure 13))
   with
  | Some exit -> check_exit_finalizer "Effect.finally cleanup fail" exit
  | None -> fail "Effect.finally cleanup fail" "expected sync exit" |> raise);
  (match
     Runtime.run_now runtime
       (Effect.finally (Effect.fail "cleanup") (Effect.fail 14))
   with
  | Some exit -> check_exit_suppressed_fail_int "Effect.finally suppressed" 14 exit
  | None -> fail "Effect.finally suppressed" "expected sync exit" |> raise);
  let order = ref [] in
  let use_release =
    Effect.acquire_use_release
      ~acquire:(Effect.sync (fun () ->
          order := "acquire" :: !order;
          "resource"))
      ~release:(fun resource ->
        Effect.sync (fun () -> order := ("release " ^ resource) :: !order))
      (fun resource ->
        Effect.sync (fun () ->
            order := ("body " ^ resource) :: !order;
            15))
  in
  (match Runtime.run_now runtime use_release with
  | Some exit -> check_exit_ok_int "Effect.acquire_use_release" 15 exit
  | None -> fail "Effect.acquire_use_release" "expected sync exit" |> raise);
  check "Effect.acquire_use_release order"
    (!order = [ "release resource"; "body resource"; "acquire" ]);
  let defect_attempts = ref 0 in
  (match
     Runtime.run_now runtime
       (Effect.retry Schedule.forever (fun _ -> true)
          (Effect.sync (fun () ->
               incr defect_attempts;
               failwith "retry defect")))
   with
  | Some (Exit.Error (Cause.Die _)) -> ()
  | _ -> fail "Effect.retry defect" "expected Die cause" |> raise);
  check_equal_int "Effect.retry does not retry defects" 1 !defect_attempts;
  (match Runtime.run_now runtime (deep_bind 100_000) with
  | Some exit -> check_exit_ok_int "Runtime.run_now deep bind" 100_000 exit
  | None -> fail "Runtime.run_now deep bind" "expected sync exit" |> raise);
  let async_eff =
    Effect.Expert.async_leaf (fun _context ~resume:_ ~on_cancel:_ -> ())
  in
  check "Runtime.run_now async returns none"
    (Runtime.run_now runtime async_eff = None);
  check "Runtime.run_now delay returns none"
    ( Runtime.run_now runtime
        (Effect.delay Duration.zero (Effect.pure 1))
    = None );
  Js.Promise.resolve ()

let test_effect_runtime_async () =
  let open Eta_js in
  let runtime = Runtime.create () in
  let p1 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Runtime.run_promise pure" 42 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime (Effect.pure 42))
  in
  let async_eff =
    Effect.Expert.async_leaf (fun _context ~resume ~on_cancel:_ ->
        resume (Exit.ok 7))
  in
  let p2 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.async_leaf immediate" 7 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime async_eff)
  in
  let double_resume_failed = ref false in
  let double_resume =
    Effect.Expert.async_leaf (fun _context ~resume ~on_cancel:_ ->
        resume (Exit.ok ());
        try resume (Exit.ok ())
        with Invalid_argument _ -> double_resume_failed := true)
  in
  let p3 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok () -> ()
        | Exit.Error _ -> fail "Effect.async_leaf double resume" "expected ok" |> raise);
        check "Effect.async_leaf double resume rejected" !double_resume_failed;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime double_resume)
  in
  let p4 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.delay zero resumes async" 9 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.delay Duration.zero (Effect.pure 9)))
  in
  let p5 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Runtime.run_promise deep bind" 100_000 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime (deep_bind 100_000))
  in
  let scheduler = Scheduler.create () in
  let runtime = Runtime.create ~scheduler () in
  let seen = ref [] in
  Scheduler.enqueue scheduler (fun () -> seen := "ready" :: !seen);
  let p6 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok () -> ()
        | Exit.Error _ -> fail "Effect.yield_now ordering" "expected ok" |> raise);
        check "Effect.yield_now runs behind ready work"
          (!seen = [ "effect"; "ready" ]);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.seq Effect.yield_now
            (Effect.sync (fun () -> seen := "effect" :: !seen))))
  in
  let runtime = Runtime.create () in
  let cancel_self =
    Effect.Expert.async_leaf (fun context ~resume ~on_cancel:_ ->
        Runtime_fiber.cancel context.fiber Cause.interrupt;
        resume (Exit.ok ()))
  in
  let p7 =
    Js.Promise.then_
      (fun exit ->
        check_exit_interrupt "Effect.check cancelled" exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime (Effect.seq cancel_self Effect.check))
  in
  let runtime = Runtime.create () in
  let cancel_hooks = ref 0 in
  let cancellable_leaf =
    Effect.Expert.async_leaf (fun context ~resume:_ ~on_cancel ->
        on_cancel (fun () -> incr cancel_hooks);
        Scheduler.enqueue context.scheduler (fun () ->
            Runtime_fiber.cancel context.fiber Cause.interrupt;
            Runtime_fiber.cancel context.fiber Cause.interrupt))
  in
  let p8 =
    Js.Promise.then_
      (fun exit ->
        check_exit_interrupt "Effect.async_leaf cancelled" exit;
        check_equal_int "Effect.async_leaf cancel hook once" 1 !cancel_hooks;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime cancellable_leaf)
  in
  let runtime = Runtime.create () in
  let cleanup_ran = ref false in
  let p9 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.finally async cleanup" 16 exit;
        check "Effect.finally async cleanup ran" !cleanup_ran;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.finally
            (Effect.delay Duration.zero
               (Effect.sync (fun () -> cleanup_ran := true)))
            (Effect.pure 16)))
  in
  let runtime = Runtime.create () in
  let attempts = ref 0 in
  let retry_eff =
    Effect.retry (Schedule.recurs 2) (fun _ -> true)
      (Effect.bind
         (fun attempt ->
           if attempt < 3 then Effect.fail attempt else Effect.pure attempt)
         (Effect.sync (fun () ->
              incr attempts;
              !attempts)))
  in
  let p10 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.retry succeeds" 3 exit;
        check_equal_int "Effect.retry attempts" 3 !attempts;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime retry_eff)
  in
  let runtime = Runtime.create () in
  let attempts = ref 0 in
  let retry_exhausted =
    Effect.retry (Schedule.recurs 1) (fun _ -> true)
      (Effect.bind
         (fun attempt -> Effect.fail attempt)
         (Effect.sync (fun () ->
              incr attempts;
              !attempts)))
  in
  let p11 =
    Js.Promise.then_
      (fun exit ->
        check_exit_fail_int "Effect.retry exhausted" 2 exit;
        check_equal_int "Effect.retry exhausted attempts" 2 !attempts;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime retry_exhausted)
  in
  let runtime = Runtime.create () in
  let repeats = ref 0 in
  let p12 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok () -> ()
        | Exit.Error _ -> fail "Effect.repeat" "expected ok" |> raise);
        check_equal_int "Effect.repeat count" 3 !repeats;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.repeat (Schedule.recurs 2)
            (Effect.sync (fun () -> incr repeats))))
  in
  let runtime = Runtime.create () in
  let loser_cancelled = ref false in
  let losing =
    Effect.Expert.async_leaf (fun _context ~resume:_ ~on_cancel ->
        on_cancel (fun () -> loser_cancelled := true))
  in
  let p13 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.race winner" 21 exit;
        check "Effect.race cancels loser" !loser_cancelled;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.race [ losing; Effect.pure 21 ]))
  in
  let runtime = Runtime.create () in
  let p14 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Error (Cause.Concurrent [ Cause.Fail 1; Cause.Fail 2 ]) -> ()
        | _ -> fail "Effect.race all failures" "expected concurrent failures" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.race [ Effect.fail 1; Effect.fail 2 ]))
  in
  let runtime = Runtime.create () in
  let p15 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok [ 1; 2; 3 ] -> ()
        | _ -> fail "Effect.all" "expected ordered values" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.all
            [
              Effect.delay Duration.zero (Effect.pure 1);
              Effect.pure 2;
              Effect.pure 3;
            ]))
  in
  let runtime = Runtime.create () in
  let p16 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok (1, 2) -> ()
        | _ -> fail "Effect.par" "expected pair" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.par
            (Effect.delay Duration.zero (Effect.pure 1))
            (Effect.pure 2)))
  in
  let runtime = Runtime.create () in
  let p17 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok [ Ok 1; Error (Cause.Fail 2); Ok 3 ] -> ()
        | _ -> fail "Effect.all_settled" "expected settled values" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.all_settled
            [ Effect.pure 1; Effect.fail 2; Effect.pure 3 ]))
  in
  let runtime = Runtime.create () in
  let p18 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok [ 2; 4; 6 ] -> ()
        | _ -> fail "Effect.for_each_par" "expected mapped values" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.for_each_par [ 1; 2; 3 ] (fun value ->
              Effect.pure (value * 2))))
  in
  let bounded_rejected =
    try
      ignore (Effect.for_each_par_bounded ~max:0 [ 1 ] Effect.pure);
      false
    with Invalid_argument _ -> true
  in
  check "Effect.for_each_par_bounded rejects max <= 0" bounded_rejected;
  let runtime = Runtime.create () in
  let active = ref 0 in
  let max_seen = ref 0 in
  let bounded value =
    Effect.seq
      (Effect.sync (fun () ->
          incr active;
          max_seen := max !max_seen !active))
      (Effect.delay Duration.zero
         (Effect.sync (fun () ->
              decr active;
              value)))
  in
  let p19 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok [ 1; 2; 3; 4 ] -> ()
        | _ -> fail "Effect.for_each_par_bounded" "expected ordered values" |> raise);
        check "Effect.for_each_par_bounded max respected" (!max_seen <= 2);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3; 4 ] bounded))
  in
  let runtime = Runtime.create () in
  let p20 =
    Js.Promise.then_
      (fun exit ->
        check_exit_ok_int "Effect.timeout_as body wins" 31 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.timeout_as (Duration.ms 10) ~on_timeout:99
            (Effect.pure 31)))
  in
  let runtime = Runtime.create () in
  let p21 =
    Js.Promise.then_
      (fun exit ->
        check_exit_fail_int "Effect.timeout_as body failure wins" 32 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.timeout_as (Duration.ms 10) ~on_timeout:99
            (Effect.fail 32)))
  in
  let runtime = Runtime.create () in
  let p22 =
    Js.Promise.then_
      (fun exit ->
        check_exit_fail_int "Effect.timeout_as timeout wins" 99 exit;
        Js.Promise.resolve ())
      (Runtime.run_promise runtime
         (Effect.timeout_as Duration.zero ~on_timeout:99
            (Effect.delay (Duration.ms 10) (Effect.pure 33))))
  in
  let runtime = Runtime.create () in
  let daemon_ran = ref false in
  let p23 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok () -> ()
        | Exit.Error _ -> fail "Effect.daemon" "expected daemon start ok" |> raise);
        Js.Promise.then_
          (fun () ->
            check "Runtime.drain_promise waits for daemon" !daemon_ran;
            Js.Promise.resolve ())
          (Runtime.drain_promise runtime))
      (Runtime.run_promise runtime
         (Effect.daemon
            (Effect.delay Duration.zero
               (Effect.sync (fun () -> daemon_ran := true)))))
  in
  Js.Promise.all [| p1; p2; p3; p4; p5; p6; p7; p8; p9; p10; p11; p12; p13;
                     p14; p15; p16; p17; p18; p19; p20; p21; p22; p23 |]
  |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ())

let tests =
  [
    ("scheduler", test_scheduler);
    ("runtime_promise", test_runtime_promise);
    ("runtime_stream", test_runtime_stream);
    ("runtime_local", test_runtime_local);
    ("mutable_ref", test_mutable_ref);
    ("effect_runtime_sync", test_effect_runtime_sync);
    ("effect_runtime_async", test_effect_runtime_async);
  ]
