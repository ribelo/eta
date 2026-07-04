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

let expect_fail pred = function
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected typed failure, got %a"
           (Eta.Cause.pp pp_err) cause)
  | Eta.Exit.Ok _ -> fail "expected typed failure, got Ok"

let test_delay done_ =
  run (Eta.Effect.delay (Eta.Duration.ms 1) (Eta.Effect.pure 42))
    ~on_result:(finish done_ (expect_ok_int 42))

let test_timeout_releases_resource done_ =
  let released = ref false in
  let acquire = Eta.Effect.unit in
  let release () = Eta.Effect.sync (fun () -> released := true) in
  let body =
    Eta.Effect.scoped
      (Eta.Effect.acquire_release ~acquire ~release
       |> Eta.Effect.bind (fun () ->
              Eta.Effect.delay (Eta.Duration.seconds 1) Eta.Effect.unit))
  in
  run (Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout body)
    ~on_result:
      (finish done_ (fun result ->
           expect_fail (( = ) `Timeout) result;
           if not !released then fail "resource was not released"))

let test_await_cancel_hook done_ =
  let cancel_called = ref false in
  let never, _resolver = Eta_jsoo.Private.create_promise () in
  let body =
    Eta.Effect.sync (fun () ->
        Eta_jsoo.Private.await ~on_cancel:(fun () -> cancel_called := true)
          never)
  in
  run (Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout body)
    ~on_result:
      (finish done_ (fun result ->
           expect_fail (( = ) `Timeout) result;
           if not !cancel_called then fail "cancel hook was not called"))

let test_runtime_locals_cross_fork done_ =
  let local = Runtime_contract.create_local () in
  let eff =
    Eta.Effect.Expert.make @@ fun context ->
    let contract = Eta.Effect.Expert.contract context in
    let result =
      contract.Runtime_contract.local_with_binding local 42 (fun () ->
          contract.Runtime_contract.run_scope @@ fun sw ->
          let promise, resolver = contract.Runtime_contract.create_promise () in
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

let test_runtime_stream_fifo done_ =
  let eff =
    Eta.Effect.Expert.make @@ fun context ->
    let contract = Eta.Effect.Expert.contract context in
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
    Eta.Effect.Expert.make @@ fun context ->
    let contract = Eta.Effect.Expert.contract context in
    let promise, resolver = contract.Runtime_contract.create_promise () in
    let waiter_started, waiter_started_resolver =
      contract.Runtime_contract.create_promise ()
    in
    let waiter_result, waiter_result_resolver =
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
    Eta.Effect.Expert.make @@ fun context ->
    let contract = Eta.Effect.Expert.contract context in
    let promise, resolver = contract.Runtime_contract.create_promise () in
    let started, started_resolver =
      contract.Runtime_contract.create_promise ()
    in
    let cancelled, cancelled_resolver =
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
    Eta.Effect.Expert.make @@ fun context ->
    let contract = Eta.Effect.Expert.contract context in
    let promise, resolver = contract.Runtime_contract.create_promise () in
    let canceled_started, canceled_started_resolver =
      contract.Runtime_contract.create_promise ()
    in
    let canceled_done, canceled_done_resolver =
      contract.Runtime_contract.create_promise ()
    in
    let live_started, live_started_resolver =
      contract.Runtime_contract.create_promise ()
    in
    let live_result, live_result_resolver =
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
    (Eta.Effect.daemon (Eta.Effect.sync (fun () -> completed := true)))
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

let tests =
  [
    ("delay", test_delay);
    ("timeout releases resource", test_timeout_releases_resource);
    ("await cancel hook", test_await_cancel_hook);
    ("runtime locals cross fork", test_runtime_locals_cross_fork);
    ("runtime stream fifo", test_runtime_stream_fifo);
    ("runtime resolve wakes live waiter", test_runtime_resolve_wakes_live_waiter);
    ( "runtime resolve after waiter cancellation",
      test_runtime_resolve_after_waiter_cancellation );
    ( "runtime canceled waiter does not strand live waiter",
      test_runtime_canceled_waiter_does_not_strand_live_waiter );
    ("daemon drain", test_daemon_drain);
  ]

let rec run_tests = function
  | [] -> log "eta_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_jsoo failed: " ^ Printexc.to_string exn)
