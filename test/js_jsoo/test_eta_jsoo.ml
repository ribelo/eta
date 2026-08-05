module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe
module Runtime_contract = Eta.Runtime_contract

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let fail message = failwith message
let pp_err fmt _ = Format.pp_print_string fmt "<err>"
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
               log "eta_jsoo failed: test chain did not reach completion")));
    |]
  |> ignore

let finish done_ f value =
  try
    f value;
    done_ ()
  with exn ->
    set_exit_code 1;
    log ("eta_jsoo failed: " ^ Printexc.to_string exn)

let run eff ~on_result =
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime eff ~on_result

let expect_ok_int expected = function
  | Eta.Exit.Ok actual when actual = expected -> ()
  | Eta.Exit.Ok actual ->
      fail (Printf.sprintf "expected Ok %d, got Ok %d" expected actual)
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected Ok %d, got %a" expected
           (Eta.Cause.pp pp_err) cause)

let expect_ok_pair expected = function
  | Eta.Exit.Ok actual when actual = expected -> ()
  | Eta.Exit.Ok _ -> fail "expected different pair"
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected Ok pair, got %a"
           (Eta.Cause.pp pp_err) cause)

let expect_ok_fresh_values = function
  | Eta.Exit.Ok ([ 1; 2; 3 ], "worker-4") -> ()
  | Eta.Exit.Ok _ -> fail "unexpected fresh sequence or fresh_named value"
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected fresh values, got %a"
           (Eta.Cause.pp pp_err) cause)

let expect_fail pred = function
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected typed failure, got %a"
           (Eta.Cause.pp pp_err) cause)
  | Eta.Exit.Ok _ -> fail "expected typed failure, got Ok"

let rec finalizer_has_typed_failure = function
  | Eta.Cause.Finalizer.Fail _ -> true
  | Eta.Cause.Finalizer.Die _ | Eta.Cause.Finalizer.Interrupt _ -> false
  | Eta.Cause.Finalizer.Sequential causes
  | Eta.Cause.Finalizer.Concurrent causes ->
      List.exists finalizer_has_typed_failure causes
  | Eta.Cause.Finalizer.Finalizer cause -> finalizer_has_typed_failure cause
  | Eta.Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_typed_failure primary
      || finalizer_has_typed_failure finalizer

let test_background_typed_failure_cancels_use done_ =
  let finalizers = ref 0 in
  let background =
    Eta.Effect.yield
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Background_failed)
  in
  let use =
    Eta.Effect.finally
      (Eta.Effect.yield
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.sync (fun () -> incr finalizers)))
      Eta.Effect.never
  in
  run (Eta.Effect.with_background background (fun () -> use))
    ~on_result:
      (finish done_ (fun exit ->
           expect_fail (( = ) `Background_failed) exit;
           if !finalizers <> 1 then fail "body finalizer did not run once"))

let test_background_loser_publishes_after_cancellation done_ =
  let runtime = Eta_jsoo.Runtime.create () in
  let finalizer_started = Eta.Promise.create () in
  let release_finalizer = Eta.Promise.create () in
  let result_resolved = ref false in
  let finalizer_finished = ref false in
  let background =
    Eta.Effect.yield
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Background_failed)
  in
  let use =
    Eta.Effect.finally
      (Eta.Promise.resolve finalizer_started (Eta.Exit.Ok ())
      |> Eta.Effect.discard
      |> Eta.Effect.bind (fun () -> Eta.Promise.await release_finalizer)
      |> Eta.Effect.map (fun () -> finalizer_finished := true))
      Eta.Effect.never
  in
  Eta_jsoo.Runtime.run runtime
    (Eta.Effect.with_background background (fun () -> use))
    ~on_result:
      (fun exit ->
        result_resolved := true;
        finish done_
          (fun exit ->
            expect_fail (( = ) `Background_failed) exit;
            if not !finalizer_finished then
              fail "loser finalizer was not completed before assembly")
          exit);
  let controller =
    Eta.Promise.await finalizer_started
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () ->
               if !result_resolved then
                 fail "result resolved while loser finalizer was held"))
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.discard
             (Eta.Promise.resolve release_finalizer (Eta.Exit.Ok ())))
  in
  Eta_jsoo.Runtime.run runtime controller ~on_result:(function
    | Eta.Exit.Ok () -> ()
    | Eta.Exit.Error cause ->
        set_exit_code 1;
        log
          (Format.asprintf "eta_jsoo failed: F3 controller: %a"
             (Eta.Cause.pp pp_err) cause))

let test_background_defect_cancels_use done_ =
  let finalizers = ref 0 in
  let defect = Failure "background defect" in
  let background =
    Eta.Effect.yield
    |> Eta.Effect.bind (fun () -> Eta.Effect.sync (fun () -> raise defect))
  in
  let use =
    Eta.Effect.finally (Eta.Effect.sync (fun () -> incr finalizers))
      Eta.Effect.never
  in
  run (Eta.Effect.with_background background (fun () -> use))
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Die die)
          when die.exn == defect && !finalizers = 1 ->
            ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "unexpected background defect cause: %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok _ -> fail "background defect was hidden"))

let test_background_body_exits_cancel_child done_ =
  let success_finalizers = ref 0 in
  let failure_finalizers = ref 0 in
  let case finalizers body =
    Eta.Effect.with_background
      (Eta.Effect.finally (Eta.Effect.sync (fun () -> incr finalizers))
         Eta.Effect.never)
      (fun () -> body)
    |> Eta.Effect.to_exit
  in
  let open Eta.Syntax in
  let program =
    let* success = case success_finalizers (Eta.Effect.pure "ok") in
    let+ failure = case failure_finalizers (Eta.Effect.fail `Use_failed) in
    (success, failure)
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok
            ( Eta.Exit.Ok "ok",
              Eta.Exit.Error (Eta.Cause.Fail `Use_failed) )
          when !success_finalizers = 1 && !failure_finalizers = 1 ->
            ()
        | Eta.Exit.Ok _ -> fail "unexpected body-first exits or finalizer counts"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "body-first test failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_background_body_interruption_matches_par done_ =
  let ready = Eta.Promise.create () in
  let finalizers = ref 0 in
  let background =
    Eta.Effect.finally (Eta.Effect.sync (fun () -> incr finalizers))
      (Eta.Promise.resolve ready (Eta.Exit.Ok ())
      |> Eta.Effect.discard
      |> Eta.Effect.bind (fun () -> Eta.Effect.never))
  in
  let scoped =
    Eta.Effect.with_background background (fun () -> Eta.Effect.never)
  in
  let controller =
    Eta.Promise.await ready
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Stop)
  in
  run (Eta.Effect.discard (Eta.Effect.par scoped controller))
    ~on_result:
      (finish done_ (fun exit ->
           expect_fail (( = ) `Stop) exit;
           if !finalizers <> 1 then
             fail "interrupted background did not finalize once"))

let test_supervised_background_does_not_cancel_use done_ =
  let body_completed = ref false in
  let background =
    Eta.Effect.yield
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Background_failed)
  in
  let use =
    Eta.Effect.yield
    |> Eta.Effect.bind (fun () -> Eta.Effect.yield)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () -> body_completed := true))
  in
  run (Eta.Effect.with_supervised_background background (fun () -> use))
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Finalizer _) when !body_completed -> ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "unexpected supervised cause: %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok () -> fail "supervised child failure was hidden"))

let test_background_same_release_has_one_winner done_ =
  let go = Eta.Promise.create () in
  let ready = ref 0 in
  let first = ref None in
  let body_finalizers = ref 0 in
  let background_finalizers = ref 0 in
  let arrive tag =
    Eta.Effect.sync (fun () -> incr ready; !ready)
    |> Eta.Effect.bind (fun count ->
           if count = 2 then
             Eta.Effect.discard (Eta.Promise.resolve go (Eta.Exit.Ok ()))
           else Eta.Effect.unit)
    |> Eta.Effect.bind (fun () -> Eta.Promise.await go)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () ->
               if Option.is_none !first then first := Some tag))
  in
  let background =
    Eta.Effect.finally
      (Eta.Effect.sync (fun () -> incr background_finalizers))
      (arrive `Background
      |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Background_failed))
  in
  let use =
    Eta.Effect.finally (Eta.Effect.sync (fun () -> incr body_finalizers))
      (arrive `Body)
  in
  run (Eta.Effect.with_background background (fun () -> use))
    ~on_result:
      (finish done_ (fun exit ->
           (match (!first, exit) with
           | Some `Background,
             Eta.Exit.Error (Eta.Cause.Fail `Background_failed) ->
               ()
           | Some `Body, Eta.Exit.Ok () -> ()
           | Some `Body, Eta.Exit.Error (Eta.Cause.Finalizer finalizer)
             when finalizer_has_typed_failure finalizer ->
               ()
           | _ -> fail "same-release result disagreed with first publication");
           if !body_finalizers <> 1 || !background_finalizers <> 1 then
             fail "same-release branch finalized more or less than once"))

let test_delay done_ =
  run (Eta.Effect.delay (Eta.Duration.ms 1) (Eta.Effect.pure 42))
    ~on_result:(finish done_ (expect_ok_int 42))

let test_fresh_uses_runtime_local_mutable_counter done_ =
  let open Eta.Syntax in
  let program =
    let* first = Eta.Effect.fresh () in
    let* second = Eta.Effect.fresh () in
    let* third = Eta.Effect.fresh () in
    let+ named = Eta.Effect.fresh_named "worker" in
    ([ first; second; third ], named)
  in
  run program ~on_result:(finish done_ expect_ok_fresh_values)

let test_timeout_releases_resource done_ =
  let released = ref false in
  let acquire = Eta.Effect.unit in
  let release () = Eta.Effect.sync (fun () -> released := true) in
  let body =
    Eta.Effect.with_scope
      (Eta.Effect.acquire_release ~acquire ~release
       |> Eta.Effect.bind (fun () ->
              Eta.Effect.delay (Eta.Duration.seconds 1) Eta.Effect.unit))
  in
  run (Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout body)
    ~on_result:
      (finish done_ (fun result ->
           expect_fail (( = ) `Timeout) result;
           if not !released then fail "resource was not released"))

let signal promise =
  Eta.Promise.resolve promise (Eta.Exit.Ok ()) |> Eta.Effect.discard

let test_acquire_all_par_success_transfer_order done_ =
  let b_done = Eta.Promise.create () in
  let trail = ref [] in
  let acquire = function
    | `A ->
        Eta.Promise.await b_done
        |> Eta.Effect.bind (fun () ->
               Eta.Effect.sync (fun () ->
                   trail := "acquire:a" :: !trail;
                   "a"))
    | `B ->
        Eta.Effect.sync (fun () -> trail := "acquire:b" :: !trail)
        |> Eta.Effect.bind (fun () -> signal b_done)
        |> Eta.Effect.map (fun () -> "b")
  in
  let release resource =
    Eta.Effect.sync (fun () -> trail := ("release:" ^ resource) :: !trail)
  in
  let program =
    Eta.Effect.with_scope
      (Eta.Effect.acquire_all_par ~acquire ~release [ `A; `B ]
      |> Eta.Effect.bind (fun resources ->
             Eta.Effect.sync (fun () ->
                 if List.exists (String.starts_with ~prefix:"release:") !trail
                 then fail "resource released before owner body";
                 trail := "body" :: !trail;
                 resources)))
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok [ "a"; "b" ] ->
            let expected =
              [ "acquire:b"; "acquire:a"; "body"; "release:a"; "release:b" ]
            in
            if List.rev !trail <> expected then
              fail "acquire_all_par jsoo transfer order diverged"
        | Eta.Exit.Ok _ -> fail "acquire_all_par jsoo result order diverged"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "acquire_all_par jsoo success failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_acquire_all_par_sibling_failure_rollback done_ =
  let a_done = Eta.Promise.create () in
  let b_done = Eta.Promise.create () in
  let in_flight_started = Eta.Promise.create () in
  let releases = ref [] in
  let acquire = function
    | `A -> signal a_done |> Eta.Effect.map (fun () -> "a")
    | `B ->
        Eta.Promise.await a_done
        |> Eta.Effect.bind (fun () -> signal b_done)
        |> Eta.Effect.map (fun () -> "b")
    | `Fail ->
        Eta.Promise.await b_done
        |> Eta.Effect.bind (fun () -> Eta.Promise.await in_flight_started)
        |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Acquire)
    | `In_flight ->
        signal in_flight_started
        |> Eta.Effect.bind (fun () -> Eta.Effect.never)
  in
  let release resource =
    Eta.Effect.sync (fun () -> releases := resource :: !releases)
  in
  run
    (Eta.Effect.with_scope
       (Eta.Effect.acquire_all_par ~acquire ~release
          [ `A; `B; `Fail; `In_flight ]))
    ~on_result:
      (finish done_ (fun exit ->
           expect_fail (( = ) `Acquire) exit;
           if List.rev !releases <> [ "b"; "a" ] then
             fail "acquire_all_par jsoo sibling rollback diverged"))

let cancel_from_parent_when started batch =
  Eta.Spi.Expert.make @@ fun context ->
  let contract = Eta.Spi.Expert.contract context in
  let #(cancel_ready, cancel_ready_resolver) =
      contract.Runtime_contract.create_promise ()
  in
  let #(result, result_resolver) =
      contract.Runtime_contract.create_promise () in
  contract.Runtime_contract.run_scope
    ~name:"acquire_all_par parent interruption"
    (fun sw ->
      contract.Runtime_contract.fork sw (fun () ->
          let exit =
            try
              contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
              contract.Runtime_contract.resolve_promise cancel_ready_resolver
                cancel_context;
              Eta.Spi.Expert.eval context batch
            with exn -> Eta.Spi.Expert.exit_of_exn context exn
          in
          contract.Runtime_contract.resolve_promise result_resolver exit);
      let cancel_context =
        contract.Runtime_contract.await_promise cancel_ready
      in
      while not !started do
        contract.Runtime_contract.yield ()
      done;
      contract.Runtime_contract.cancel cancel_context
        (Failure "cancel acquire_all_par from parent");
      contract.Runtime_contract.await_promise result)

let test_acquire_all_par_parent_interruption done_ =
  let a_done = Eta.Promise.create () in
  let b_done = Eta.Promise.create () in
  let in_flight_started = ref false in
  let releases = ref [] in
  let acquire = function
    | `A -> signal a_done |> Eta.Effect.map (fun () -> "a")
    | `B ->
        Eta.Promise.await a_done
        |> Eta.Effect.bind (fun () -> signal b_done)
        |> Eta.Effect.map (fun () -> "b")
    | `In_flight ->
        Eta.Promise.await b_done
        |> Eta.Effect.bind (fun () ->
               Eta.Effect.sync (fun () -> in_flight_started := true))
        |> Eta.Effect.bind (fun () -> Eta.Effect.never)
  in
  let release resource =
    Eta.Effect.sync (fun () -> releases := resource :: !releases)
  in
  let batch =
    Eta.Effect.with_scope
      (Eta.Effect.acquire_all_par ~acquire ~release [ `A; `B; `In_flight ])
  in
  run (cancel_from_parent_when in_flight_started batch)
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
            if List.rev !releases <> [ "b"; "a" ] then
              fail "acquire_all_par jsoo parent rollback diverged"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "expected jsoo parent interruption, got %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok _ -> fail "jsoo parent interruption returned Ok"))

let test_await_cancellation_removes_promise_subscription done_ =
  let cancel_called = ref false in
  let subscriptions_seen_by_cancel_hook = ref (-1) in
  let never, _resolver = Eta_jsoo.Private.create_promise () in
  let body =
    Eta.Effect.sync (fun () ->
        Eta_jsoo.Private.await
          ~on_cancel:(fun () ->
            cancel_called := true;
            subscriptions_seen_by_cancel_hook :=
              Eta_jsoo.Private.pending_subscriptions never)
          never)
  in
  run (Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout body)
    ~on_result:
      (finish done_ (fun result ->
           expect_fail (( = ) `Timeout) result;
           if not !cancel_called then fail "cancel hook was not called";
           if !subscriptions_seen_by_cancel_hook <> 0 then
             fail "cancel hook ran before promise unsubscription";
           if Eta_jsoo.Private.pending_subscriptions never <> 0 then
             fail "canceled await remained subscribed to its promise"))

let test_throwing_await_cancel_hook_does_not_strand_fiber done_ =
  let never, _resolver = Eta_jsoo.Private.create_promise () in
  let body =
    Eta.Effect.sync (fun () ->
        Eta_jsoo.Private.await
          ~on_cancel:(fun () -> failwith "await cancel hook failed")
          never)
  in
  run (Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout body)
    ~on_result:
      (finish done_ (fun result ->
           if Eta_jsoo.Private.pending_subscriptions never <> 0 then
             fail "throwing cancel hook retained its promise subscription";
           match result with
           | Eta.Exit.Error cause when Eta.Cause.defects cause <> [] -> ()
           | Eta.Exit.Error cause ->
               fail
                 (Format.asprintf "expected cancel hook defect, got %a"
                    (Eta.Cause.pp pp_err) cause)
           | Eta.Exit.Ok _ -> fail "expected cancel hook defect, got Ok"))

let test_runtime_locals_cross_fork done_ =
  let local = Runtime_contract.create_local () in
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let result =
      contract.Runtime_contract.local_with_binding local 42 (fun () ->
          contract.Runtime_contract.run_scope @@ fun sw ->
          let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
          contract.Runtime_contract.fork sw (fun () ->
              contract.Runtime_contract.resolve_promise resolver
                (contract.Runtime_contract.local_get local));
          contract.Runtime_contract.await_promise promise)
    in
    match result with
    | Some value -> Eta.Exit.Ok value
    | None -> Eta.Exit.Error (Eta.Cause.Fail `Missing_local)
  in
  run eff ~on_result:(finish done_ (expect_ok_int 42))

let test_runtime_local_inheritance_kinds done_ =
  let inherited = Runtime_contract.create_local () in
  let fiber_local =
    Runtime_contract.create_local ~inheritance:Fiber_local ()
  in
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let observe () =
      ( contract.Runtime_contract.local_get inherited,
        contract.Runtime_contract.local_get fiber_local )
    in
    let result =
      contract.Runtime_contract.local_with_binding inherited 42 @@ fun () ->
      contract.Runtime_contract.local_with_binding fiber_local 99 @@ fun () ->
      let child =
        contract.Runtime_contract.run_scope @@ fun sw ->
        let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
        contract.Runtime_contract.fork sw (fun () ->
            contract.Runtime_contract.resolve_promise resolver (observe ()));
        contract.Runtime_contract.await_promise promise
      in
      let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
      contract.Runtime_contract.fork_daemon
        contract.Runtime_contract.root_scope (fun () ->
          contract.Runtime_contract.resolve_promise resolver (observe ());
          `Stop_daemon);
      let daemon = contract.Runtime_contract.await_promise promise in
      (child, daemon)
    in
    Eta.Exit.Ok result
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok ((Some 42, None), (Some 42, None)) -> ()
        | Eta.Exit.Ok _ -> fail "runtime local inheritance kinds diverged"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "local inheritance program failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_runtime_stream_fifo done_ =
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let stream = contract.Runtime_contract.create_stream 1 in
    let values =
      contract.Runtime_contract.run_scope @@ fun sw ->
      contract.Runtime_contract.fork sw (fun () ->
          contract.Runtime_contract.stream_add stream 1;
          contract.Runtime_contract.stream_add stream 2);
      let first = contract.Runtime_contract.stream_take stream in
      let second = contract.Runtime_contract.stream_take stream in
      (first, second)
    in
    Eta.Exit.Ok values
  in
  run eff ~on_result:(finish done_ (expect_ok_pair (1, 2)))

let test_runtime_resolve_wakes_live_waiter done_ =
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
    let #(waiter_started, waiter_started_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let #(waiter_result, waiter_result_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let result =
      contract.Runtime_contract.run_scope
        ~name:"live resolver conformance"
        (fun child_scope ->
          contract.Runtime_contract.fork child_scope (fun () ->
              contract.Runtime_contract.resolve_promise waiter_started_resolver
                ();
              let value = contract.Runtime_contract.await_promise promise in
              contract.Runtime_contract.resolve_promise waiter_result_resolver
                value);
          contract.Runtime_contract.await_promise waiter_started;
          contract.Runtime_contract.yield ();
          contract.Runtime_contract.resolve_promise resolver 17;
          contract.Runtime_contract.await_promise waiter_result)
    in
    Eta.Exit.Ok result
  in
  run eff ~on_result:(finish done_ (expect_ok_int 17))

let test_runtime_resolve_after_waiter_cancellation done_ =
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
    let #(started, started_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let #(cancelled, cancelled_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    contract.Runtime_contract.run_scope
      ~name:"resolver cancellation conformance"
      (fun child_scope ->
        contract.Runtime_contract.fork child_scope (fun () ->
            contract.Runtime_contract.cancel_sub @@ fun cancel_ctx ->
            contract.Runtime_contract.resolve_promise started_resolver
              cancel_ctx;
            try
              ignore
                (contract.Runtime_contract.await_promise promise : int)
            with exn -> (
              match contract.Runtime_contract.cancellation_reason exn with
              | Some _ ->
                  contract.Runtime_contract.resolve_promise
                    cancelled_resolver ()
              | None -> raise exn));
        let cancel_ctx =
          contract.Runtime_contract.await_promise started
        in
        contract.Runtime_contract.cancel cancel_ctx
          (Failure "cancel promise waiter");
        contract.Runtime_contract.await_promise cancelled;
        contract.Runtime_contract.resolve_promise resolver 42);
    Eta.Exit.Ok ()
  in
  run eff
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok () -> ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf
                 "expected resolve after waiter cancellation to succeed, got %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_runtime_canceled_waiter_does_not_strand_live_waiter done_ =
  let eff =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let #(promise, resolver) =
      contract.Runtime_contract.create_promise () in
    let #(canceled_started, canceled_started_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let #(canceled_done, canceled_done_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let #(live_started, live_started_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let #(live_result, live_result_resolver) =
      contract.Runtime_contract.create_promise ()
    in
    let result =
      contract.Runtime_contract.run_scope
        ~name:"mixed waiter resolver conformance"
        (fun child_scope ->
          contract.Runtime_contract.fork child_scope (fun () ->
              contract.Runtime_contract.cancel_sub @@ fun cancel_ctx ->
              contract.Runtime_contract.resolve_promise
                canceled_started_resolver cancel_ctx;
              try ignore (contract.Runtime_contract.await_promise promise : int)
              with exn -> (
                match contract.Runtime_contract.cancellation_reason exn with
                | Some _ ->
                    contract.Runtime_contract.resolve_promise
                      canceled_done_resolver ()
                | None -> raise exn));
          let cancel_ctx =
            contract.Runtime_contract.await_promise canceled_started
          in
          contract.Runtime_contract.cancel cancel_ctx
            (Failure "cancel one promise waiter");
          contract.Runtime_contract.await_promise canceled_done;
          contract.Runtime_contract.fork child_scope (fun () ->
              contract.Runtime_contract.resolve_promise live_started_resolver
                ();
              let value = contract.Runtime_contract.await_promise promise in
              contract.Runtime_contract.resolve_promise live_result_resolver
                value);
          contract.Runtime_contract.await_promise live_started;
          contract.Runtime_contract.yield ();
          contract.Runtime_contract.resolve_promise resolver 23;
          contract.Runtime_contract.await_promise live_result)
    in
    Eta.Exit.Ok result
  in
  run eff ~on_result:(finish done_ (expect_ok_int 23))

let test_daemon_drain done_ =
  let completed = ref false in
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime
    (Eta.Spi.daemon (Eta.Effect.sync (fun () -> completed := true)))
    ~on_result:
      (finish
         (fun () ->
           Eta_jsoo.Runtime.drain runtime
             ~on_result:
               (finish done_ (fun () ->
                    if not !completed then fail "daemon did not complete")))
         (function
           | Eta.Exit.Ok () -> ()
           | Eta.Exit.Error cause ->
               fail
                 (Format.asprintf "daemon start failed: %a"
                    (Eta.Cause.pp pp_err) cause)))

let test_scoped_clock_and_logger_parity done_ =
  let clock value : Eta.Capabilities.clock =
    object
      method now_ms () = value
      method sleep _duration = ()
    end
  in
  let logger = Eta_observability.Logger.in_memory () in
  let open Eta.Syntax in
  let program =
    let* before = Eta.Effect.now_ms in
    let* inner = Eta.Effect.with_clock (clock 22) Eta.Effect.now_ms in
    let* after = Eta.Effect.now_ms in
    let+ () =
      Eta_observability.with_logger (Eta_observability.Logger.as_capability logger)
        (Eta_observability.log "jsoo")
    in
    (before, inner, after)
  in
  run (Eta.Effect.with_clock (clock 11) program)
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok (11, 22, 11) -> (
            match Eta_observability.Logger.dump logger with
            | [ record ] when record.Eta_observability.Logger.body = "jsoo" -> ()
            | records ->
                fail
                  (Printf.sprintf "expected one jsoo override log, got %d"
                     (List.length records)))
        | Eta.Exit.Ok _ -> fail "scoped clock nesting did not restore outer"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "scoped clock/logger failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_intercept_log_parity done_ =
  let logger = Eta_observability.Logger.in_memory () in
  let calls = ref [] in
  let outer (record : Eta.Capabilities.log_record) =
    calls := !calls @ [ "outer:" ^ record.body ];
    Eta_observability.Replace { record with body = "scrubbed:" ^ record.body }
  in
  let inner (record : Eta.Capabilities.log_record) =
    calls := !calls @ [ "inner:" ^ record.body ];
    if String.equal record.body "scrubbed:drop" then Eta_observability.Drop
    else Eta_observability.Keep
  in
  let program =
    Eta.Effect.concat [ Eta_observability.log "keep"; Eta_observability.log "drop" ]
    |> Eta_observability.intercept_log inner
    |> Eta_observability.intercept_log outer
    |> Eta_observability.with_logger (Eta_observability.Logger.as_capability logger)
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok () -> (
            let expected_calls =
              [
                "outer:keep";
                "inner:scrubbed:keep";
                "outer:drop";
                "inner:scrubbed:drop";
              ]
            in
            if !calls <> expected_calls then
              fail "jsoo intercept order differed";
            match Eta_observability.Logger.dump logger with
            | [ record ] when record.Eta_observability.Logger.body = "scrubbed:keep" -> ()
            | records ->
                fail
                  (Printf.sprintf "expected one intercepted jsoo log, got %d"
                     (List.length records)))
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "jsoo intercept failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let test_expert_clock_observes_scoped_override done_ =
  let clock value : Eta.Capabilities.clock =
    object
      method now_ms () = value
      method sleep _duration = ()
    end
  in
  let runtime = Eta_jsoo.Runtime.create ~now_ms:(fun () -> 11) () in
  let expert_now =
    Eta.Spi.Expert.make @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    Eta.Exit.Ok (contract.Eta.Runtime_contract.now_ms ())
  in
  let open Eta.Syntax in
  let program =
    let* inside = Eta.Effect.with_clock (clock 22) expert_now in
    let+ outside = expert_now in
    (inside, outside)
  in
  Eta_jsoo.Runtime.run runtime program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok (22, 11) -> ()
        | Eta.Exit.Ok _ -> fail "expert contract ignored scoped/base clock"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "expert scoped clock failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

module Async_shared =
  Eta_effect_async_shared_tests.Effect_async_shared.Make (struct
    let run = run
    let complete ~done_ check = finish done_ (fun () -> check ()) ()
    let fail = fail
  end)

module Interruptible_shared =
  Eta_effect_interruptible_shared_tests.Effect_interruptible_shared.Make (struct
    let run = run
    let complete ~done_ check = finish done_ (fun () -> check ()) ()
    let fail = fail
  end)

module Promise_shared =
  Eta_promise_shared_tests.Promise_shared.Make (struct
    let run = run
    let complete ~done_ check = finish done_ (fun () -> check ()) ()
    let fail = fail
  end)

let raising_release_pp _fmt (_ : [ `Release ]) = failwith "renderer exploded"

let test_raising_release_error_pp_becomes_die done_ =
  let program : (unit, [ `Release ]) Eta.Effect.t =
    Eta.Effect.with_scope
      (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
         ~release:(fun () -> Eta.Effect.fail `Release))
    |> Eta_observability.with_error_pp raising_release_pp
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Die die)
          when String.equal (Printexc.to_string die.exn)
                 "Failure(\"renderer exploded\")" ->
            ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "expected release renderer defect, got %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok () -> fail "expected release renderer defect"))

let test_raising_finally_error_pp_becomes_die done_ =
  let program : (unit, [ `Release ]) Eta.Effect.t =
    Eta.Effect.finally (Eta.Effect.fail `Release) Eta.Effect.unit
    |> Eta_observability.with_error_pp raising_release_pp
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Die die)
          when String.equal (Printexc.to_string die.exn)
                 "Failure(\"renderer exploded\")" ->
            ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "expected finally renderer defect, got %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok () -> fail "expected finally renderer defect"))

(* Stack-safety regression corpus (DX-E35): bounded jsoo twin of the native
   tests in test/eta/test_eta_effect_core.ml, pinning the same measured
   contract: these compositions complete at depth 1M under the documented
   default configuration — js_of_ocaml --effects=cps, which eta_jsoo.mli
   itself requires. The whole interpreter [eval] is CPS-transformed because
   its branches and callbacks are effect-capable, so its recursion rides
   jsoo's trampoline (caml_exact_trampoline_cps_call / caml_stack_check_depth
   in the generated JS) instead of the JS call stack. The guarantee is
   configuration-dependent, not intrinsic: a non-CPS jsoo build or a future
   bounded-stack substrate reopens the question. *)

let test_stack_safety_dynamic_bind done_ =
  let depth = 1_000_000 in
  let rec next remaining value =
    if remaining = 0 then Eta.Effect.pure value
    else
      Eta.Effect.bind
        (fun value -> next (remaining - 1) (value + 1))
        (Eta.Effect.pure value)
  in
  run (next depth 0) ~on_result:(finish done_ (expect_ok_int depth))

let test_stack_safety_static_map done_ =
  let depth = 1_000_000 in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Eta.Effect.map (fun value -> value + 1) acc)
  in
  run (build depth (Eta.Effect.pure 0))
    ~on_result:(finish done_ (expect_ok_int depth))

let test_stack_safety_concat done_ =
  let depth = 1_000_000 in
  let executed = ref 0 in
  let rec build remaining acc =
    if remaining = 0 then acc
    else
      build (remaining - 1)
        (Eta.Effect.sync (fun () -> incr executed) :: acc)
  in
  run (Eta.Effect.concat (build depth []))
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok () ->
            if !executed <> depth then
              fail
                (Printf.sprintf "expected %d concat executions, got %d" depth
                   !executed)
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "deep concat failed: %a" (Eta.Cause.pp pp_err)
                 cause)))

let test_stack_safety_bind_error done_ =
  let depth = 1_000_000 in
  let handled = ref 0 in
  let recover (_ : string) =
    incr handled;
    Eta.Effect.fail "boom"
  in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Eta.Effect.bind_error recover acc)
  in
  run (build depth (Eta.Effect.fail "boom"))
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Fail "boom") ->
            if !handled <> depth then
              fail
                (Printf.sprintf "expected %d recovery runs, got %d" depth
                   !handled)
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "unexpected cause: %a" (Eta.Cause.pp pp_err)
                 cause)
        | Eta.Exit.Ok _ -> fail "recovery chain lost the typed failure"))

let test_stack_safety_deep_cause_trees done_ =
  finish done_
    (fun () ->
      let depth = 1_000_000 in
      let check combine =
        let cause = ref (Eta.Cause.fail 0) in
        for value = 1 to depth do
          cause := combine [ !cause; Eta.Cause.fail value ]
        done;
        let rec check_leaf index = function
          | [] ->
              if index <> depth + 1 then
                fail
                  (Printf.sprintf "expected %d leaves, got %d" (depth + 1)
                     index)
          | leaf :: rest ->
              if leaf <> index then
                fail
                  (Printf.sprintf "leaf at index %d: expected %d, got %d"
                     index index leaf);
              check_leaf (index + 1) rest
        in
        check_leaf 0 (Eta.Cause.failures !cause)
      in
      check Eta.Cause.sequential;
      check Eta.Cause.concurrent)
    ()

let tests =
  [
    ("stack safety: 1M dynamic binds", test_stack_safety_dynamic_bind);
    ("stack safety: 1M static map nesting", test_stack_safety_static_map);
    ("stack safety: 1M concat", test_stack_safety_concat);
    ("stack safety: 1M bind_error recovery", test_stack_safety_bind_error);
    ("stack safety: 1M deep cause trees", test_stack_safety_deep_cause_trees);
    ("delay", test_delay);
    ("fresh runtime-local counter", test_fresh_uses_runtime_local_mutable_counter);
    ("timeout releases resource", test_timeout_releases_resource);
    ( "acquire_all_par success transfer order",
      test_acquire_all_par_success_transfer_order );
    ( "acquire_all_par sibling failure rollback",
      test_acquire_all_par_sibling_failure_rollback );
    ( "acquire_all_par parent interruption",
      test_acquire_all_par_parent_interruption );
    ( "raising release error_pp becomes die at conversion",
      test_raising_release_error_pp_becomes_die );
    ( "raising finally error_pp becomes die at conversion",
      test_raising_finally_error_pp_becomes_die );
    ( "await cancellation removes promise subscription",
      test_await_cancellation_removes_promise_subscription );
    ( "throwing await cancel hook does not strand fiber",
      test_throwing_await_cancel_hook_does_not_strand_fiber );
    ("runtime locals cross fork", test_runtime_locals_cross_fork);
    ( "runtime local inheritance kinds",
      test_runtime_local_inheritance_kinds );
    ("runtime stream fifo", test_runtime_stream_fifo);
    ("runtime resolve wakes live waiter", test_runtime_resolve_wakes_live_waiter);
    ( "runtime resolve after waiter cancellation",
      test_runtime_resolve_after_waiter_cancellation );
    ( "runtime canceled waiter does not strand live waiter",
      test_runtime_canceled_waiter_does_not_strand_live_waiter );
    ("daemon drain", test_daemon_drain);
    ("scoped clock and logger parity", test_scoped_clock_and_logger_parity);
    ("intercept_log parity", test_intercept_log_parity);
    ( "expert clock observes scoped override",
      test_expert_clock_observes_scoped_override );
    ( "with_background typed failure cancels use",
      test_background_typed_failure_cancels_use );
    ( "with_background loser publishes after cancellation before assembly",
      test_background_loser_publishes_after_cancellation );
    ( "with_background defect cancels use",
      test_background_defect_cancels_use );
    ( "with_background body exits cancel child",
      test_background_body_exits_cancel_child );
    ( "with_background body interruption matches par",
      test_background_body_interruption_matches_par );
    ( "with_supervised_background does not cancel use",
      test_supervised_background_does_not_cancel_use );
    ( "with_background same-release exits choose one winner",
      test_background_same_release_has_one_winner );
    ( "runtime local binding contract",
      fun done_ ->
        let local = Runtime_contract.create_local () in
        let eff =
          Eta.Spi.Expert.make @@ fun context ->
          let contract = Eta.Spi.Expert.contract context in
          let require label expected =
            if contract.Runtime_contract.local_get local <> expected then
              failwith label
          in
          require "initially absent" None;
          contract.Runtime_contract.local_with_binding local 1 (fun () ->
              require "outer installed" (Some 1);
              contract.Runtime_contract.local_with_binding local 2 (fun () ->
                  require "inner installed" (Some 2));
              require "outer restored after inner" (Some 1));
          require "absent after normal return" None;
          let raised = Failure "binding exception" in
          (try
             contract.Runtime_contract.local_with_binding local 3 (fun () ->
                 raise raised)
           with exn when exn == raised -> ());
          require "absent after exception" None;
          let cancelled = Failure "binding cancellation" in
          contract.Runtime_contract.cancel_sub (fun cancel_context ->
              try
                contract.Runtime_contract.local_with_binding local 4 @@ fun () ->
                contract.Runtime_contract.cancel cancel_context cancelled;
                contract.Runtime_contract.check ();
                failwith "expected cancellation"
              with exn ->
                match contract.Runtime_contract.cancellation_reason exn with
                | Some reason when reason == cancelled -> ()
                | _ -> raise exn);
          require "absent after cancellation" None;
          let child, parent =
            contract.Runtime_contract.local_with_binding local 5 (fun () ->
                let child =
                  contract.Runtime_contract.run_scope @@ fun sw ->
                  let #(started, started_resolver) =
      contract.Runtime_contract.create_promise ()
                  in
                  let #(observe, observe_resolver) =
      contract.Runtime_contract.create_promise ()
                  in
                  let #(bound, bound_resolver) =
      contract.Runtime_contract.create_promise ()
                  in
                  let #(release, release_resolver) =
      contract.Runtime_contract.create_promise ()
                  in
                  let #(result, result_resolver) =
      contract.Runtime_contract.create_promise ()
                  in
                  contract.Runtime_contract.fork sw (fun () ->
                      contract.Runtime_contract.resolve_promise started_resolver
                        ();
                      contract.Runtime_contract.await_promise observe;
                      let before = contract.Runtime_contract.local_get local in
                      let inner =
                        contract.Runtime_contract.local_with_binding local 6
                          (fun () ->
                            contract.Runtime_contract.resolve_promise
                              bound_resolver ();
                            contract.Runtime_contract.await_promise release;
                            contract.Runtime_contract.local_get local)
                      in
                      let after = contract.Runtime_contract.local_get local in
                      contract.Runtime_contract.resolve_promise result_resolver
                        (before, inner, after));
                  contract.Runtime_contract.await_promise started;
                  let parent_during_child_binding =
                    contract.Runtime_contract.local_with_binding local 7
                      (fun () ->
                        contract.Runtime_contract.resolve_promise observe_resolver
                          ();
                        contract.Runtime_contract.await_promise bound;
                        let observed =
                          contract.Runtime_contract.local_get local
                        in
                        contract.Runtime_contract.resolve_promise release_resolver
                          ();
                        observed)
                  in
                  ( contract.Runtime_contract.await_promise result,
                    parent_during_child_binding )
                in
                (child, contract.Runtime_contract.local_get local))
          in
          let child_observations, parent_during_child_binding = child in
          if child_observations <> (Some 5, Some 6, Some 5) then
            failwith "child fork snapshot or LIFO restoration diverged";
          if parent_during_child_binding <> Some 7 then
            failwith "child binding leaked into parent";
          if parent <> Some 5 then failwith "child binding joined into parent";
          require "absent after fork scope" None;
          Eta.Exit.Ok ()
        in
        run eff
          ~on_result:
            (finish done_ (function
              | Eta.Exit.Ok () -> ()
              | Eta.Exit.Error cause ->
                  fail
                    (Format.asprintf "local binding contract failed: %a"
                       (Eta.Cause.pp pp_err) cause))) );
  ]
  @ Async_shared.tests
  @ Interruptible_shared.tests
  @ Promise_shared.tests

let resolve_ok promise value =
  Eta.Promise.resolve promise (Eta.Exit.Ok value) |> Eta.Effect.discard

(* supcan-stst supcan-f3ww supcan-3sp7 supcan-kptd supcan-0uj5 supcan-yncg
   supcan-vb4t *)
let test_supervisor_request_cancel_returns_before_settlement done_ =
  let runtime = Eta_jsoo.Runtime.create () in
  let ready = Eta.Promise.create () in
  let cleanup_started = Eta.Promise.create () in
  let release_cleanup = Eta.Promise.create () in
  let allow_fence = Eta.Promise.create () in
  let request_returned = Eta.Promise.create () in
  let cleanup_started_flag = ref false in
  let result_resolved = ref false in
  let cleanup_finished = ref false in
  let child =
    Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
      ~release:(fun () ->
        Eta.Effect.sync (fun () -> cleanup_started_flag := true)
        |> Eta.Effect.bind (fun () -> resolve_ok cleanup_started ())
        |> Eta.Effect.bind (fun () -> Eta.Promise.await release_cleanup)
        |> Eta.Effect.map (fun () -> cleanup_finished := true))
    |> Eta.Effect.bind (fun () ->
           resolve_ok ready ()
           |> Eta.Effect.bind (fun () -> Eta.Effect.never))
  in
  let program =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let* () = lift (Eta.Promise.await ready) in
          let* () = request_cancel child in
          let* () = lift (resolve_ok request_returned ()) in
          let* () = lift (Eta.Promise.await allow_fence) in
          cancel child;
    }
  in
  Eta_jsoo.Runtime.run runtime program
    ~on_result:(fun exit ->
      result_resolved := true;
      finish done_
        (fun exit ->
          match exit with
          | Eta.Exit.Ok () when !cleanup_finished -> ()
          | Eta.Exit.Ok () -> fail "request cancellation skipped cleanup"
          | Eta.Exit.Error cause ->
              fail
                (Format.asprintf "request cancellation failed: %a"
                   (Eta.Cause.pp pp_err) cause))
        exit);
  let controller =
    Eta.Promise.await request_returned
    |> Eta.Effect.bind (fun () -> Eta.Effect.yield)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () ->
               (!cleanup_started_flag, not !result_resolved)))
    |> Eta.Effect.bind (fun observation ->
           resolve_ok allow_fence ()
           |> Eta.Effect.bind (fun () -> resolve_ok release_cleanup ())
           |> Eta.Effect.bind (fun () ->
                  Eta.Effect.sync (fun () ->
                      match observation with
                      | true, true -> ()
                      | false, _ ->
                          fail "request_cancel did not start cleanup before fence"
                      | _, false ->
                          fail "request_cancel waited for held cleanup")))
  in
  Eta_jsoo.Runtime.run runtime controller ~on_result:(function
    | Eta.Exit.Ok () -> ()
    | Eta.Exit.Error cause ->
        set_exit_code 1;
        log
          (Format.asprintf "eta_jsoo request controller failed: %a"
             (Eta.Cause.pp pp_err) cause))

(* supcan-stst supcan-zqzf supcan-glb2 *)
let test_supervisor_request_cancel_latches_before_child_start done_ =
  let runtime = Eta_jsoo.Runtime.create () in
  let start_gate = Eta.Promise.create () in
  let request_returned = Eta.Promise.create () in
  let body_started = ref false in
  let result_resolved = ref false in
  let child =
    Eta.Promise.await start_gate
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () -> body_started := true))
  in
  let program =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let* () = request_cancel child in
          let* () = lift (resolve_ok request_returned ()) in
          await child;
    }
  in
  Eta_jsoo.Runtime.run runtime program
    ~on_result:(fun exit ->
      result_resolved := true;
      finish done_ (function
        | Eta.Exit.Error (Eta.Cause.Interrupt None) when not !body_started -> ()
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "pre-start request failed: %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok () -> fail "latched request did not interrupt child")
        exit);
  let rec wait_for_result remaining =
    if !result_resolved || !body_started || remaining = 0 then Eta.Effect.unit
    else
      Eta.Effect.yield
      |> Eta.Effect.bind (fun () -> wait_for_result (remaining - 1))
  in
  let controller =
    Eta.Promise.await request_returned
    |> Eta.Effect.bind (fun () -> wait_for_result 20)
    |> Eta.Effect.bind (fun () ->
           let latched = !result_resolved && not !body_started in
           (if latched then Eta.Effect.unit else resolve_ok start_gate ())
           |> Eta.Effect.bind (fun () ->
                  Eta.Effect.sync (fun () ->
                      if not latched then
                        fail "pre-start request did not settle the child")))
  in
  Eta_jsoo.Runtime.run runtime controller ~on_result:(function
    | Eta.Exit.Ok () -> ()
    | Eta.Exit.Error cause ->
        set_exit_code 1;
        log
          (Format.asprintf "eta_jsoo pre-start controller failed: %a"
             (Eta.Cause.pp pp_err) cause))

exception Request_cancel_defect

(* supcan-3os1 supcan-glb2 supcan-tg7n *)
let test_supervisor_request_cancel_preserves_terminal_winners done_ =
  let error_pp fmt = function
    | `Boom -> Format.pp_print_string fmt "Boom"
    | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed"
    | `Failure_not_observed ->
        Format.pp_print_string fmt "Failure_not_observed"
  in
  let late_failure child =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let rec wait_for_failure attempts =
            let* observed = failures supervisor in
            if observed <> [] then pure ()
            else if attempts = 0 then fail `Failure_not_observed
            else
              let* () = yield in
              wait_for_failure (attempts - 1)
          in
          let* () = wait_for_failure 20 in
          let* () = request_cancel child in
          await child;
    }
    |> Eta_observability.with_error_pp error_pp
  in
  let completion =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (pure 42) in
          let* _ = await child in
          let* () = request_cancel child in
          await child;
    }
  in
  let typed_failure = late_failure (Eta.Effect.fail `Boom) in
  let defect =
    late_failure
      (Eta.Effect.sync (fun () -> raise Request_cancel_defect))
  in
  let finalizer_failure =
    late_failure
      (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
         ~release:(fun () -> Eta.Effect.fail `Cleanup_failed))
  in
  let program =
    Eta.Effect.to_exit completion
    |> Eta.Effect.bind (fun completion ->
           Eta.Effect.to_exit typed_failure
           |> Eta.Effect.bind (fun typed_failure ->
                  Eta.Effect.to_exit defect
                  |> Eta.Effect.bind (fun defect ->
                         Eta.Effect.to_exit finalizer_failure
                         |> Eta.Effect.map (fun finalizer_failure ->
                                ( completion,
                                  typed_failure,
                                  defect,
                                  finalizer_failure )))))
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok
            ( Eta.Exit.Ok 42,
              Eta.Exit.Error (Eta.Cause.Fail `Boom),
              Eta.Exit.Error (Eta.Cause.Die { exn; _ }),
              Eta.Exit.Error
                (Eta.Cause.Finalizer
                  (Eta.Cause.Finalizer.Fail
                    { error = _; rendered = "Cleanup_failed" })) )
          when exn == Request_cancel_defect ->
            ()
        | Eta.Exit.Ok _ -> fail "late request changed a terminal winner"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "terminal-winner test failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

(* supcan-3sp7 supcan-dyvd supcan-nnq7 *)
let test_supervisor_cancel_after_request_preserves_settlement_diagnostics done_ =
  let late_cancel child =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let rec wait_for_failure attempts =
            let* observed = failures supervisor in
            if observed <> [] then pure ()
            else if attempts = 0 then fail `Failure_not_observed
            else
              let* () = yield in
              wait_for_failure (attempts - 1)
          in
          let* () = wait_for_failure 20 in
          let* () = request_cancel child in
          cancel child;
    }
  in
  let requested_cleanup ~fails finalizer_count =
    let ready = Eta.Promise.create () in
    let release () =
      Eta.Effect.sync (fun () -> incr finalizer_count)
      |> Eta.Effect.bind (fun () ->
             if fails then Eta.Effect.fail `Cleanup_failed
             else Eta.Effect.unit)
    in
    let child =
      Eta.Effect.acquire_release ~acquire:Eta.Effect.unit ~release
      |> Eta.Effect.bind (fun () ->
             resolve_ok ready ()
             |> Eta.Effect.bind (fun () -> Eta.Effect.never))
    in
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let* () = lift (Eta.Promise.await ready) in
          let* () = request_cancel child in
          cancel child;
    }
    |> Eta_observability.with_error_pp (fun fmt -> function
         | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed")
  in
  let clean_finalizers = ref 0 in
  let failed_finalizers = ref 0 in
  let clean = requested_cleanup ~fails:false clean_finalizers in
  let cleanup_failure = requested_cleanup ~fails:true failed_finalizers in
  let typed_failure = late_cancel (Eta.Effect.fail `Boom) in
  let defect =
    late_cancel (Eta.Effect.sync (fun () -> raise Request_cancel_defect))
  in
  let program =
    Eta.Effect.to_exit clean
    |> Eta.Effect.bind (fun clean ->
           Eta.Effect.to_exit cleanup_failure
           |> Eta.Effect.bind (fun cleanup_failure ->
                  Eta.Effect.to_exit typed_failure
                  |> Eta.Effect.bind (fun typed_failure ->
                         Eta.Effect.to_exit defect
                         |> Eta.Effect.map (fun defect ->
                                ( clean,
                                  cleanup_failure,
                                  typed_failure,
                                  defect,
                                  !clean_finalizers,
                                  !failed_finalizers )))))
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok
            ( Eta.Exit.Ok (),
              Eta.Exit.Error
                (Eta.Cause.Suppressed
                  {
                    primary = Eta.Cause.Interrupt None;
                    finalizer =
                      Eta.Cause.Finalizer.Fail
                        { error = _; rendered = "Cleanup_failed" };
                  }),
              Eta.Exit.Error (Eta.Cause.Fail `Boom),
              Eta.Exit.Error (Eta.Cause.Die { exn; _ }),
              1,
              1 )
          when exn == Request_cancel_defect ->
            ()
        | Eta.Exit.Ok _ -> fail "request/cancel changed settlement diagnostics"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "request/cancel matrix failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

(* supcan-eg0p *)
let test_supervisor_await_after_request_reports_interruption done_ =
  let late_await child =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift child) in
          let rec wait_for_failure attempts =
            let* observed = failures supervisor in
            if observed <> [] then pure ()
            else if attempts = 0 then fail `Failure_not_observed
            else
              let* () = yield in
              wait_for_failure (attempts - 1)
          in
          let* () = wait_for_failure 20 in
          let* () = request_cancel child in
          await child;
    }
    |> Eta_observability.with_error_pp (fun fmt -> function
         | `Boom -> Format.pp_print_string fmt "Boom"
         | `Cleanup_failed -> Format.pp_print_string fmt "Cleanup_failed"
         | `Failure_not_observed ->
             Format.pp_print_string fmt "Failure_not_observed")
  in
  let completion =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (pure 42) in
          let* _ = await child in
          let* () = request_cancel child in
          await child;
    }
  in
  let typed_failure = late_await (Eta.Effect.fail `Boom) in
  let defect =
    late_await (Eta.Effect.sync (fun () -> raise Request_cancel_defect))
  in
  let finalizer_failure =
    late_await
      (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
         ~release:(fun () -> Eta.Effect.fail `Cleanup_failed))
  in
  let ready = Eta.Promise.create () in
  let interruption_child =
    resolve_ok ready ()
    |> Eta.Effect.bind (fun () -> Eta.Effect.never)
  in
  let interruption =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* child = start supervisor (lift interruption_child) in
          let* () = lift (Eta.Promise.await ready) in
          let* () = request_cancel child in
          await child;
    }
  in
  let program =
    Eta.Effect.to_exit completion
    |> Eta.Effect.bind (fun completion ->
           Eta.Effect.to_exit typed_failure
           |> Eta.Effect.bind (fun typed_failure ->
                  Eta.Effect.to_exit defect
                  |> Eta.Effect.bind (fun defect ->
                         Eta.Effect.to_exit finalizer_failure
                         |> Eta.Effect.bind (fun finalizer_failure ->
                                Eta.Effect.to_exit interruption
                                |> Eta.Effect.map (fun interruption ->
                                       ( completion,
                                         typed_failure,
                                         defect,
                                         finalizer_failure,
                                         interruption ))))))
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok
            ( Eta.Exit.Ok 42,
              Eta.Exit.Error (Eta.Cause.Fail `Boom),
              Eta.Exit.Error (Eta.Cause.Die { exn; _ }),
              Eta.Exit.Error
                (Eta.Cause.Finalizer
                  (Eta.Cause.Finalizer.Fail
                    { error = _; rendered = "Cleanup_failed" })),
              Eta.Exit.Error (Eta.Cause.Interrupt None) )
          when exn == Request_cancel_defect ->
            ()
        | Eta.Exit.Ok _ -> fail "await after request changed an ordinary outcome"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "await-after-request matrix failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

(* supcan-6zw9 supcan-urkv supcan-vb4t *)
let test_supervisor_request_cancel_calls_follow_scope_program_order done_ =
  let events = ref [] in
  let mark name = Eta.Effect.sync (fun () -> events := name :: !events) in
  let first_ready = Eta.Promise.create () in
  let second_ready = Eta.Promise.create () in
  let first_cleanup_started = Eta.Promise.create () in
  let second_cleanup_started = Eta.Promise.create () in
  let release_first_cleanup = Eta.Promise.create () in
  let release_second_cleanup = Eta.Promise.create () in
  let second_cleanup_finished = Eta.Promise.create () in
  let replacement_release = Eta.Promise.create () in
  let replacement_started = Eta.Promise.create () in
  let child label ready cleanup_started release_cleanup cleanup_finished =
    Eta.Effect.acquire_release
      ~acquire:Eta.Effect.unit
      ~release:(fun () ->
        mark (label ^ ":cleanup-start")
        |> Eta.Effect.bind (fun () -> resolve_ok cleanup_started ())
        |> Eta.Effect.bind (fun () -> Eta.Promise.await release_cleanup)
        |> Eta.Effect.bind (fun () -> mark (label ^ ":cleanup-end"))
        |> Eta.Effect.bind cleanup_finished)
    |> Eta.Effect.bind (fun () ->
           mark (label ^ ":ready")
           |> Eta.Effect.bind (fun () -> resolve_ok ready ())
           |> Eta.Effect.bind (fun () -> Eta.Effect.never))
  in
  let first =
    child "first" first_ready first_cleanup_started release_first_cleanup
      (fun () -> Eta.Effect.unit)
  in
  let second =
    child "second" second_ready second_cleanup_started release_second_cleanup
      (fun () -> resolve_ok second_cleanup_finished ())
  in
  let replacement =
    Eta.Promise.await replacement_release
    |> Eta.Effect.bind (fun () -> mark "replacement:start")
    |> Eta.Effect.bind (fun () -> resolve_ok replacement_started ())
  in
  let program =
    Eta.Supervisor.scoped {
      run =
        fun supervisor ->
          let open Eta.Supervisor.Scope in
          let* first_child = start supervisor (lift first) in
          let* second_child = start supervisor (lift second) in
          let* replacement_child = start supervisor (lift replacement) in
          let* () = lift (Eta.Promise.await first_ready) in
          let* () = lift (Eta.Promise.await second_ready) in
          let* () = lift (mark "request:first-call") in
          let* () = request_cancel first_child in
          let* () = lift (mark "request:first-return") in
          let* () = lift (mark "request:second-call") in
          let* () = request_cancel second_child in
          let* () = lift (mark "request:second-return") in
          let* () = lift (resolve_ok replacement_release ()) in
          let* () = lift (Eta.Promise.await replacement_started) in
          let* () = lift (Eta.Promise.await first_cleanup_started) in
          let* () = lift (Eta.Promise.await second_cleanup_started) in
          let* () = lift (resolve_ok release_second_cleanup ()) in
          let* () = lift (Eta.Promise.await second_cleanup_finished) in
          let* () = lift (resolve_ok release_first_cleanup ()) in
          let* () = cancel first_child in
          let* () = cancel second_child in
          let* () = await replacement_child in
          pure (List.rev !events);
    }
  in
  run program
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "request ordering failed: %a"
                 (Eta.Cause.pp pp_err) cause)
        | Eta.Exit.Ok events ->
            let expected_events =
              [
                "first:ready";
                "second:ready";
                "request:first-call";
                "request:first-return";
                "request:second-call";
                "request:second-return";
                "first:cleanup-start";
                "second:cleanup-start";
                "replacement:start";
                "second:cleanup-end";
                "first:cleanup-end";
              ]
            in
            if List.length events <> List.length expected_events then
              fail "request ordering emitted the wrong event count";
            List.iter
              (fun expected ->
                if
                  List.length (List.filter (String.equal expected) events) <> 1
                then fail ("request ordering duplicated or lost " ^ expected))
              expected_events;
            let request_events =
              List.filter (String.starts_with ~prefix:"request:") events
            in
            if
              request_events
              <> [
                   "request:first-call";
                   "request:first-return";
                   "request:second-call";
                   "request:second-return";
                 ]
            then fail "request call and return events were not exact";
            let position name =
              match List.find_index (String.equal name) events with
              | Some index -> index
              | None -> fail ("missing supervisor event " ^ name)
            in
            let before left right =
              if position left >= position right then
                fail (left ^ " did not occur before " ^ right)
            in
            before "request:first-call" "request:first-return";
            before "request:first-return" "request:second-call";
            before "request:second-call" "request:second-return";
            before "request:second-return" "replacement:start";
            before "replacement:start" "second:cleanup-end";
            before "second:cleanup-end" "first:cleanup-end"))

let request_cancel_tests =
  [
    ( "request_cancel returns before settlement",
      test_supervisor_request_cancel_returns_before_settlement );
    ( "request_cancel latches before child start",
      test_supervisor_request_cancel_latches_before_child_start );
    ( "request_cancel preserves terminal winners",
      test_supervisor_request_cancel_preserves_terminal_winners );
    ( "cancel after request_cancel preserves settlement diagnostics",
      test_supervisor_cancel_after_request_preserves_settlement_diagnostics );
    ( "await after request_cancel reports interruption",
      test_supervisor_await_after_request_reports_interruption );
    ( "request_cancel calls follow scope program order",
      test_supervisor_request_cancel_calls_follow_scope_program_order );
  ]

let cancellation_matches contract expected exn =
  match contract.Runtime_contract.cancellation_reason exn with
  | Some actual -> actual == expected
  | None -> exn == expected

let rec contract_wait_until contract attempts predicate =
  if predicate () then true
  else if attempts = 0 then false
  else (
    contract.Runtime_contract.yield ();
    contract_wait_until contract (attempts - 1) predicate)

let runtime_cancel_request_probe =
  Eta.Spi.Expert.make @@ fun context ->
  let contract = Eta.Spi.Expert.contract context in
  let reason = Failure "runtime cancel probe" in
  let cleanup_started = ref false in
  let cleanup_finished = ref false in
  let finalizer_count = ref 0 in
  let reason_observed = ref false in
  try
    let #(cancel_ready, publish_cancel) =
      contract.Runtime_contract.create_promise ()
    in
    let #(release_cleanup, release) =
      contract.Runtime_contract.create_promise ()
    in
    let returned_before_settlement, cleanup_was_pending =
      contract.Runtime_contract.run_scope @@ fun sw ->
      contract.Runtime_contract.fork sw (fun () ->
          try
            contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
            contract.Runtime_contract.resolve_promise publish_cancel
              cancel_context;
            Fun.protect
              ~finally:(fun () ->
                try
                  contract.Runtime_contract.protect @@ fun () ->
                  cleanup_started := true;
                  incr finalizer_count;
                  contract.Runtime_contract.await_promise release_cleanup;
                  cleanup_finished := true
                with exn ->
                  if not (cancellation_matches contract reason exn) then
                    raise exn)
              (fun () -> contract.Runtime_contract.await_cancel ())
          with exn ->
            if cancellation_matches contract reason exn then
              reason_observed := true
            else raise exn);
      let cancel_context =
        contract.Runtime_contract.await_promise cancel_ready
      in
      contract.Runtime_contract.cancel cancel_context reason;
      let returned_before_settlement = not !cleanup_finished in
      let cleanup_started_before_fallback =
        contract_wait_until contract 200 (fun () -> !cleanup_started)
      in
      if not cleanup_started_before_fallback then (
        contract.Runtime_contract.resolve_promise release ();
        fail "Runtime_contract.cancel did not record cancellation");
      let cleanup_was_pending = not !cleanup_finished in
      contract.Runtime_contract.resolve_promise release ();
      (returned_before_settlement, cleanup_was_pending)
    in
    Eta.Exit.Ok
      ( returned_before_settlement,
        cleanup_was_pending,
        !reason_observed,
        !cleanup_finished,
        !finalizer_count )
  with exn -> Eta.Spi.Expert.exit_of_exn context exn

let runtime_fail_scope_request_probe =
  Eta.Spi.Expert.make @@ fun context ->
  let contract = Eta.Spi.Expert.contract context in
  let reason = Failure "runtime fail_scope probe" in
  let fallback = Failure "runtime fail_scope fallback" in
  let cleanup_started = ref false in
  let cleanup_finished = ref false in
  let finalizer_count = ref 0 in
  let reason_observed = ref false in
  try
    let #(target_ready, publish_target) =
      contract.Runtime_contract.create_promise ()
    in
    let #(child_ready, publish_child) =
      contract.Runtime_contract.create_promise ()
    in
    let #(target_done, publish_target_done) =
      contract.Runtime_contract.create_promise ()
    in
    let #(release_cleanup, release) =
      contract.Runtime_contract.create_promise ()
    in
    let #(release_body, release_target_body) =
      contract.Runtime_contract.create_promise ()
    in
    let returned_before_settlement, cleanup_was_pending, cleanup_started_in_time,
        failure_recorded =
      contract.Runtime_contract.run_scope @@ fun outer_sw ->
      contract.Runtime_contract.fork outer_sw (fun () ->
          let recorded =
            try
              contract.Runtime_contract.run_scope @@ fun target_sw ->
              contract.Runtime_contract.resolve_promise publish_target target_sw;
              contract.Runtime_contract.fork target_sw (fun () ->
                  try
                    contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
                    contract.Runtime_contract.resolve_promise publish_child
                      cancel_context;
                    Fun.protect
                      ~finally:(fun () ->
                        try
                          contract.Runtime_contract.protect @@ fun () ->
                          cleanup_started := true;
                          incr finalizer_count;
                          contract.Runtime_contract.await_promise release_cleanup;
                          cleanup_finished := true
                        with exn ->
                          if
                            not
                              (cancellation_matches contract reason exn
                              || cancellation_matches contract fallback exn)
                          then raise exn)
                      (fun () -> contract.Runtime_contract.await_cancel ())
                  with exn ->
                    if cancellation_matches contract reason exn then
                      reason_observed := true
                    else if not (cancellation_matches contract fallback exn) then
                      raise exn);
              contract.Runtime_contract.await_promise release_body;
              false
            with exn when exn == reason -> true
          in
          contract.Runtime_contract.resolve_promise publish_target_done recorded);
      let target_scope =
        contract.Runtime_contract.await_promise target_ready
      in
      let child_context =
        contract.Runtime_contract.await_promise child_ready
      in
      contract.Runtime_contract.fail_scope target_scope reason;
      let returned_before_settlement = not !cleanup_finished in
      let cleanup_started_in_time =
        contract_wait_until contract 200 (fun () -> !cleanup_started)
      in
      let cleanup_was_pending = not !cleanup_finished in
      contract.Runtime_contract.resolve_promise release ();
      if not cleanup_started_in_time then (
        contract.Runtime_contract.cancel child_context fallback;
        contract.Runtime_contract.resolve_promise release_target_body ());
      let failure_recorded =
        contract.Runtime_contract.await_promise target_done
      in
      ( returned_before_settlement,
        cleanup_was_pending,
        cleanup_started_in_time,
        failure_recorded )
    in
    Eta.Exit.Ok
      ( returned_before_settlement,
        cleanup_was_pending,
        cleanup_started_in_time,
        failure_recorded,
        !reason_observed,
        !cleanup_finished,
        !finalizer_count )
  with exn -> Eta.Spi.Expert.exit_of_exn context exn

(* supcan-kptd *)
let test_runtime_cancel_records_request_and_returns_before_settlement done_ =
  run runtime_cancel_request_probe
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok (true, true, true, true, 1) -> ()
        | Eta.Exit.Ok _ -> fail "runtime cancel request probe was incomplete"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "runtime cancel request probe failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

(* supcan-0uj5 *)
let test_runtime_fail_scope_records_failure_and_returns_before_settlement done_ =
  run runtime_fail_scope_request_probe
    ~on_result:
      (finish done_ (function
        | Eta.Exit.Ok (true, true, true, true, true, true, 1) -> ()
        | Eta.Exit.Ok _ -> fail "runtime fail_scope request probe was incomplete"
        | Eta.Exit.Error cause ->
            fail
              (Format.asprintf "runtime fail_scope request probe failed: %a"
                 (Eta.Cause.pp pp_err) cause)))

let runtime_contract_request_tests =
  [
    ( "runtime cancel records request and returns before settlement",
      test_runtime_cancel_records_request_and_returns_before_settlement );
    ( "runtime fail_scope records failure and returns before settlement",
      test_runtime_fail_scope_records_failure_and_returns_before_settlement );
  ]

let tests = tests @ request_cancel_tests @ runtime_contract_request_tests

let rec run_tests = function
  | [] ->
      suite_completed := true;
      log "eta_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_jsoo failed: " ^ Printexc.to_string exn)
