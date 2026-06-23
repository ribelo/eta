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
    |> Eta_js.Effect.catch (function `Bad -> Eta_js.Effect.pure 40)
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
    Eta_js.Effect.scoped
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
    Eta_js.Effect.scoped
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
    Eta_js.Effect.scoped
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
    Eta_js.Effect.scoped
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
    (Eta_js.Effect.retry (Eta_js.Schedule.recurs 3)
       (function `Retry -> true)
       attempt)
    ~on_result:(finish done_ (expect_ok_int "retry schedule" 3))

let test_repeat_schedule done_ =
  let ticks = ref 0 in
  let tick = Eta_js.Effect.sync (fun () -> incr ticks) in
  let eff =
    Eta_js.Effect.repeat (Eta_js.Schedule.recurs 2) tick
    |> Eta_js.Effect.bind (fun (_repeat_count : int) ->
           Eta_js.Effect.sync (fun () -> !ticks))
  in
  run eff ~on_result:(finish done_ (expect_ok_int "repeat schedule" 3))

let test_queue_facade done_ =
  let queue = Eta_js.Queue.create () in
  let eff =
    Eta_js.Queue.send queue 11
    |> Eta_js.Effect.bind (fun () -> Eta_js.Queue.recv queue)
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
  ]

let rec run_tests = function
  | [] -> log "eta_js_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_js_jsoo failed: " ^ Printexc.to_string exn)
