open Eta

module Make (B : Runtime_backend.S) = struct
  module E = Effect
  module Rc = Runtime_contract

  let pp_hidden fmt _ = Format.pp_print_string fmt "<err>"

  let expect_ok = function
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let expect_fail pred = function
    | Exit.Error (Cause.Fail err) when pred err -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected typed failure, got Ok"

  let expect_die = function
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Die, got Ok"

  let expect_finalizer_die = function
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Die _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Finalizer(Die), got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Finalizer(Die), got Ok"

  let rec cause_has_fail pred = function
    | Cause.Fail err -> pred err
    | Cause.Sequential causes | Cause.Concurrent causes ->
        List.exists (cause_has_fail pred) causes
    | Cause.Suppressed { primary; finalizer = _ } -> cause_has_fail pred primary
    | Cause.Die _ | Cause.Interrupt _ | Cause.Finalizer _ -> false

  let check_ok test name expected exit =
    Alcotest.check test name expected (expect_ok exit)

  let run_ok rt eff = expect_ok (B.run rt eff)

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 200

  let wait_until label predicate =
    let rec loop attempts =
      if predicate () then ()
      else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 200

  let await_resolved label promise =
    wait_until label (fun () -> B.is_resolved promise);
    B.await promise

  let check_owner_domain owner label =
    Alcotest.(check bool) label true (Domain.self () = owner)

  let expect_owner_domain owner label actual =
    Alcotest.(check bool) label true (actual = owner)

  let string_contains ~needle haystack =
    let needle_len = String.length needle in
    let haystack_len = String.length haystack in
    let rec loop index =
      if index + needle_len > haystack_len then false
      else if String.sub haystack index needle_len = needle then true
      else loop (index + 1)
    in
    loop 0

  let test_pure_bind_catch () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.fail `Bad
      |> E.bind_error (function `Bad -> E.pure 40)
      |> E.bind (fun value -> E.pure (value + 2))
    in
    check_ok Alcotest.int "value" 42 (B.run rt eff)

  let test_recover () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (E.fail `Bad |> E.fold ~ok:Fun.id ~error:(function `Bad -> 42))
    |> check_ok Alcotest.int "typed failure recovered" 42;
    B.run rt (E.sync (fun () -> failwith "boom") |> E.fold ~ok:Fun.id ~error:(fun _ -> 0))
    |> expect_die;
    B.run rt
      (E.fail `Bad
      |> E.fold ~ok:Fun.id ~error:(function `Bad -> failwith "recover handler crash"))
    |> expect_die

  let test_ignore_errors () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (E.unit |> E.ignore_errors)
    |> check_ok Alcotest.unit "success preserved as unit" ();
    B.run rt (E.fail `Bad |> E.ignore_errors)
    |> check_ok Alcotest.unit "typed failure suppressed" ();
    B.run rt (E.sync (fun () -> failwith "boom") |> E.ignore_errors)
    |> expect_die

  let test_result () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (E.pure 7 |> E.to_result)
    |> check_ok Alcotest.(result int string) "success" (Ok 7);
    B.run rt (E.fail "bad" |> E.to_result)
    |> check_ok Alcotest.(result int string) "typed failure" (Error "bad");
    B.run rt (E.sync (fun () -> failwith "boom") |> E.to_result) |> expect_die;
    match B.run rt (E.finally (E.fail "cleanup") E.unit |> E.to_result) with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected finalizer failure, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok _ -> Alcotest.fail "expected finalizer failure"

  let test_yield () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (E.yield |> E.map (fun () -> 42))
    |> check_ok Alcotest.int "yield returns" 42

  let test_collect_names () =
    let eff =
      E.concat
        [
          E.named "leaf-a" (E.sync (fun () -> ())) |> E.map (fun _ -> ());
          E.sync (fun () -> ());
          E.named "leaf-b" (E.sync (fun () -> ()));
        ]
      |> E.named "outer"
    in
    Alcotest.(check (list string))
      "names in pre-order" [ "outer"; "leaf-a"; "leaf-b" ]
      (E.collect_names eff)

  let test_from_result_and_exit_to_result () =
    B.with_runtime @@ fun _ctx rt ->
    check_ok Alcotest.int "from_result ok" 7
      (B.run rt (E.from_result (Ok 7)));
    expect_fail (( = ) "bad") (B.run rt (E.from_result (Error "bad")));
    Alcotest.(check (option (result int string)))
      "success to_result" (Some (Ok 1)) (Exit.to_result (Exit.Ok 1));
    Alcotest.(check (option (result int string)))
      "typed to_result" (Some (Error "bad"))
      (Exit.to_result (Exit.Error (Cause.Fail "bad")));
    Alcotest.(check (option (result int string)))
      "defect to_result" None
      (Exit.to_result (Exit.Error (Cause.die (Failure "boom"))));
    Alcotest.(check (option (result int string)))
      "composite to_result" None
      (Exit.to_result
         (Exit.Error
            (Cause.sequential [ Cause.Fail "left"; Cause.Fail "right" ])))

  let test_map_bind_tap_runtime () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref [] in
    let eff =
      E.pure 1
      |> E.map (fun n -> n + 1)
      |> E.bind (fun n -> E.pure (n * 2))
      |> E.tap (fun n ->
             E.named "tap"
               (E.sync (fun () -> observed := n :: !observed)))
      |> E.map (fun n -> n + 1)
    in
    check_ok Alcotest.int "value" 5 (B.run rt eff);
    Alcotest.(check (list int)) "tap saw pre-map value" [ 4 ] !observed

  let test_tap_observer_runtime () =
    B.with_runtime @@ fun _ctx rt ->
    let observed = ref [] in
    let eff =
      E.pure 10
      |> E.tap (fun n ->
             E.sync (fun () ->
                 observed := n :: !observed;
                 "ignored"))
      |> E.map (( + ) 1)
    in
    check_ok Alcotest.int "value" 11 (B.run rt eff);
    Alcotest.(check (list int)) "observer saw original value" [ 10 ] !observed;
    B.run rt
      (E.pure 1 |> E.tap (fun _ -> E.sync (fun () -> failwith "tap crash")))
    |> expect_die

  let test_map_error () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = E.map_error (function `Old -> `New) (E.fail `Old) in
    expect_fail (( = ) `New) (B.run rt eff)

  let test_map_error_maps_full_cause () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.fail `Release)
        |> E.bind (fun () -> E.fail `Body))
      |> E.map_error (function `Body -> "body" | `Release -> "release")
    in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail "body";
            finalizer = Cause.Finalizer.Fail _;
          }) ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected mapped suppressed cause, got %a"
          (Cause.pp Format.pp_print_string) cause
    | Exit.Ok () -> Alcotest.fail "expected mapped suppressed cause"

  let test_sync_defect () =
    B.with_runtime @@ fun _ctx rt ->
    B.run rt (E.sync (fun () -> raise (Failure "boom"))) |> expect_die

  let test_backtrace_capture_flag () =
    B.with_runtime_capture_backtrace false @@ fun _ctx rt ->
    match B.run rt (E.sync (fun () -> raise (Failure "boom"))) with
    | Exit.Error (Cause.Die { backtrace = None; _ }) -> ()
    | Exit.Error (Cause.Die { backtrace = Some _; _ }) ->
        Alcotest.fail "expected disabled backtrace capture"
    | Exit.Error cause ->
        Alcotest.failf "expected Die, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Die"

  let test_run_exn_uses_captured_backtrace () =
    B.with_runtime @@ fun _ctx rt ->
    let exn = Failure "run_exn defect" in
    match B.run_exn rt (E.named "die.run_exn" (E.sync (fun () -> raise exn))) with
    | _ -> Alcotest.fail "expected exception"
    | exception actual ->
        Alcotest.(check bool) "same exception" true (actual == exn);
        let backtrace =
          Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ())
        in
        Alcotest.(check bool) "backtrace not empty" true
          (String.length backtrace > 0)

  let test_run_exn_preserves_typed_failure_diagnostics () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = E.fail "detailed error: connection refused on port 8080" in
    match B.run_exn rt eff with
    | _ -> Alcotest.fail "expected exception from typed failure"
    | exception (Failure msg) ->
        Alcotest.(check bool)
          (Printf.sprintf
             "run_exn should preserve typed failure info in message (got: %S)"
             msg)
          true
          (string_contains ~needle:"connection refused" msg)
    | exception _ -> Alcotest.fail "expected Failure exception from run_exn"

  let test_finally_cleanup_failure_after_success () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = E.finally (E.fail `Cleanup) (E.pure 1) in
    match B.run rt eff with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail _)) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Finalizer, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected Finalizer"

  let test_finally_suppressed_cleanup_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = E.finally (E.fail `Cleanup) (E.fail `Primary) in
    match B.run rt eff with
    | Exit.Error
        (Cause.Suppressed
          { primary = Cause.Fail `Primary; finalizer = Cause.Finalizer.Fail _ })
      ->
        ()
    | Exit.Error cause ->
        Alcotest.failf "expected Suppressed, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected failure"

  let test_acquire_release_ordering_and_root_finalizer () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let mark name = E.sync (fun () -> trail := name :: !trail) in
    let scoped =
      E.with_scope
        (E.acquire_release
           ~acquire:(mark "acquired" |> E.map (fun () -> 1))
           ~release:(fun _ -> mark "released")
        |> E.bind (fun _ -> mark "body"))
    in
    check_ok Alcotest.unit "scoped" () (B.run rt scoped);
    Alcotest.(check (list string))
      "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail);

    let root_released = ref false in
    let root =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> root_released := true))
    in
    check_ok Alcotest.unit "root" () (B.run rt root);
    Alcotest.(check bool) "root finalizer" true !root_released

  let test_acquire_release_releases_on_defect () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.with_scope
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.sync (fun () -> released := true))
        |> E.bind (fun () -> E.sync (fun () -> failwith "body defect")))
    in
    B.run rt eff |> expect_die;
    Alcotest.(check bool) "released" true !released

  let test_acquire_use_release_success_and_lexical () =
    B.with_runtime @@ fun _ctx rt ->
    let trail = ref [] in
    let mark name = E.sync (fun () -> trail := name :: !trail) in
    let bracket =
      E.acquire_use_release
        ~acquire:(mark "acquired" |> E.map (fun () -> 1))
        ~release:(fun resource -> mark ("released:" ^ string_of_int resource))
        (fun resource ->
          mark ("body:" ^ string_of_int resource) |> E.map (fun () -> resource + 1))
    in
    check_ok Alcotest.int "body result" 2 (B.run rt bracket);
    Alcotest.(check (list string))
      "ordering" [ "acquired"; "body:1"; "released:1" ]
      (List.rev !trail);

    let active = ref 0 in
    let max_active = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr active;
          max_active := max !max_active !active)
    in
    let release () = E.sync (fun () -> decr active) in
    let one =
      E.acquire_use_release ~acquire ~release (fun () ->
          E.sync (fun () ->
              Alcotest.(check int) "active inside body" 1 !active))
    in
    check_ok Alcotest.unit "repeated brackets" ()
      (B.run rt (E.concat [ one; one; one ]));
    Alcotest.(check int) "released after each body" 0 !active;
    Alcotest.(check int) "no accumulated resources" 1 !max_active

  let test_acquire_use_release_defect_releases () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.with_scope
        (E.acquire_use_release ~acquire:(E.pure "resource")
           ~release:(fun _ -> E.sync (fun () -> released := true))
           (fun _ -> E.sync (fun () -> failwith "body defect")))
    in
    B.run rt eff |> expect_die;
    Alcotest.(check bool) "released" true !released

  let test_delay_with_test_clock () =
    B.with_test_clock @@ fun ctx clock rt ->
    let promise =
      B.fork_run ctx rt (E.delay (Duration.ms 10) (E.pure "done"))
    in
    wait_for_sleepers clock 1;
    Alcotest.(check bool) "not resolved before adjust" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 10);
    check_ok Alcotest.string "delayed" "done" (B.await promise)

  let test_timeout_releases_resource () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref false in
    let body =
      E.with_scope
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.sync (fun () -> released := true))
        |> E.bind (fun () -> E.delay (Duration.seconds 1) E.unit))
    in
    let promise =
      B.fork_run ctx rt (E.timeout_as (Duration.ms 5) ~on_timeout:`Timeout body)
    in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 5);
    B.await promise |> expect_fail (( = ) `Timeout);
    Alcotest.(check bool) "released" true !released

  let test_timeout_fast_success_and_nested_outer_timeout () =
    B.with_test_clock @@ fun ctx clock rt ->
    let fast =
      E.delay (Duration.ms 10) (E.pure "ok")
      |> E.timeout_as (Duration.ms 20) ~on_timeout:`Timeout
    in
    let fast_promise = B.fork_run ctx rt fast in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    check_ok Alcotest.string "fast success" "ok" (B.await fast_promise);

    let nested =
      E.delay (Duration.ms 1_000) (E.pure 1)
      |> E.timeout_as (Duration.ms 500) ~on_timeout:`Inner_timeout
      |> E.timeout_as (Duration.ms 10) ~on_timeout:`Outer_timeout
    in
    let nested_promise = B.fork_run ctx rt nested in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    expect_fail (( = ) `Outer_timeout) (B.await nested_promise)

  let test_acquire_use_release_typed_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let released = ref false in
    let eff =
      E.acquire_use_release
        ~acquire:(E.pure 1)
        ~release:(fun _ -> E.sync (fun () -> released := true))
        (fun _ -> E.fail `Boom)
    in
    expect_fail (( = ) `Boom) (B.run rt eff);
    Alcotest.(check bool) "released" true !released

  let test_retry_repeat () =
    B.with_runtime @@ fun _ctx rt ->
    let attempts = ref 0 in
    let retry_eff =
      E.sync (fun () -> incr attempts; !attempts)
      |> E.bind (fun n -> if n < 3 then E.fail `Again else E.pure n)
      |> E.retry ~schedule:(Schedule.recurs 5) ~while_:(function `Again -> true)
    in
    check_ok Alcotest.int "retry result" 3 (B.run rt retry_eff);
    let ticks = ref 0 in
    let repeat_eff =
      E.repeat ~schedule:(Schedule.recurs 2) (E.sync (fun () -> incr ticks))
      |> E.bind (fun (_repeat_count : int) -> E.sync (fun () -> !ticks))
    in
    check_ok Alcotest.int "repeat result" 3 (B.run rt repeat_eff)

  let test_with_background_cancels_child () =
    B.with_test_clock @@ fun ctx clock rt ->
    let finalizer_ran = ref false in
    let child_started = ref false in
    let background =
      E.acquire_release
        ~acquire:(E.sync (fun () -> child_started := true))
        ~release:(fun () -> E.sync (fun () -> finalizer_ran := true))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let program =
      E.with_background background (fun () ->
          E.delay (Duration.ms 10) (E.sync (fun () -> !child_started)))
    in
    let promise = B.fork_run ctx rt program in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    check_ok Alcotest.bool "background started" true (B.await promise);
    Alcotest.(check bool) "background finalizer ran" true !finalizer_ran

  let test_all_preserves_delayed_input_order () =
    B.with_test_clock @@ fun ctx clock rt ->
    let delayed value ms = E.delay (Duration.ms ms) (E.pure value) in
    let promise =
      B.fork_run ctx rt (E.all [ delayed 1 20; delayed 2 10; delayed 3 30 ])
    in
    wait_for_sleepers clock 3;
    B.adjust_clock clock (Duration.ms 10);
    B.yield ();
    Alcotest.(check bool) "not resolved after second finishes" false
      (B.is_resolved promise);
    B.adjust_clock clock (Duration.ms 20);
    check_ok (Alcotest.list Alcotest.int) "ordered" [ 1; 2; 3 ]
      (B.await promise)

  let test_all_settled_collects_outcomes () =
    B.with_runtime @@ fun _ctx rt ->
    let eff = E.all_settled [ E.pure 1; E.fail `Nope; E.pure 3 ] in
    match B.run rt eff with
    | Exit.Ok [ Ok 1; Error (Cause.Fail `Nope); Ok 3 ] -> ()
    | Exit.Ok _ -> Alcotest.fail "unexpected all_settled result list"
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let test_all_empty_and_fail_fast_finalizer () =
    B.with_test_clock @@ fun ctx clock rt ->
    check_ok (Alcotest.list Alcotest.int) "all empty" []
      (B.run rt (E.all []));
    check_ok (Alcotest.list Alcotest.int) "map_par empty" []
      (B.run rt (E.map_par E.pure []));
    Alcotest.(check int) "all_settled empty" 0
      (List.length (run_ok rt (E.all_settled [])));

    let released = ref false in
    let slow =
      E.acquire_use_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> released := true))
        (fun () -> E.delay (Duration.seconds 1) E.unit)
    in
    let eff = E.all [ E.delay (Duration.ms 1) (E.fail `Boom); slow ] in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 1);
    (match B.await promise with
    | Exit.Error cause when cause_has_fail (( = ) `Boom) cause -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected cause containing Boom, got %a"
          (Cause.pp pp_hidden) cause
    | Exit.Ok _ -> Alcotest.fail "expected fail-fast failure");
    Alcotest.(check bool) "cancelled sibling released" true !released

  let test_race_cancels_loser_finalizer () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = ref false in
    let slow =
      E.with_scope
        (E.acquire_release ~acquire:E.unit
           ~release:(fun () -> E.sync (fun () -> released := true))
        |> E.bind (fun () -> E.delay (Duration.seconds 1) (E.pure 1)))
    in
    let fast = E.delay (Duration.ms 1) (E.pure 2) in
    let promise = B.fork_run ctx rt (E.race [ slow; fast ]) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 1);
    check_ok Alcotest.int "winner" 2 (B.await promise);
    Alcotest.(check bool) "loser released" true !released

  let test_map_par_caps_concurrency () =
    B.with_test_clock @@ fun ctx clock rt ->
    let current = ref 0 in
    let max_seen = ref 0 in
    let worker n =
      E.sync (fun () ->
          incr current;
          max_seen := max !max_seen !current)
      |> E.bind (fun () -> E.delay (Duration.ms 10) E.unit)
      |> E.finally (E.sync (fun () -> decr current))
      |> E.map (fun () -> n)
    in
    let promise =
      B.fork_run ctx rt
        (E.map_par ~max_concurrent:2 worker [ 1; 2; 3; 4 ])
    in
    wait_for_sleepers clock 2;
    Alcotest.(check int) "max first wave" 2 !max_seen;
    B.adjust_clock clock (Duration.ms 10);
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Duration.ms 10);
    check_ok (Alcotest.list Alcotest.int) "results" [ 1; 2; 3; 4 ]
      (B.await promise);
    Alcotest.(check int) "max concurrency" 2 !max_seen

  let test_map_par_rejects_nonpositive_max () =
    Alcotest.check_raises "max zero"
      (Invalid_argument "Effect.map_par: max_concurrent must be > 0")
      (fun () -> ignore (E.map_par ~max_concurrent:0 E.pure [ 1 ]))

  let test_queue_channel_semaphore_pubsub () =
    B.with_runtime @@ fun _ctx rt ->
    let queue = Queue.unbounded () in
    let queue_eff =
      Queue.send queue 11 |> E.bind (fun () -> Queue.take queue)
    in
    check_ok Alcotest.int "queue" 11 (B.run rt queue_eff);

    let channel = Channel.create ~capacity:1 () in
    let channel_eff =
      E.par (Channel.send channel 7) (Channel.recv channel) |> E.map snd
    in
    check_ok Alcotest.int "channel" 7 (B.run rt channel_eff);

    let semaphore = Semaphore.make ~permits:1 in
    let semaphore_eff =
      Semaphore.with_permits semaphore 1 (fun () ->
          E.sync (fun () -> Semaphore.available semaphore))
      |> E.bind (fun inside ->
             E.sync (fun () -> (inside, Semaphore.available semaphore)))
    in
    check_ok
      (Alcotest.pair Alcotest.int Alcotest.int)
      "semaphore" (0, 1) (B.run rt semaphore_eff);

    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let pubsub_eff =
      Pubsub.subscribe hub (fun sub ->
          E.par (Pubsub.publish hub 5) (Pubsub.recv sub) |> E.map snd)
    in
    check_ok Alcotest.int "pubsub" 5 (B.run rt pubsub_eff)

  let test_queue_close_and_close_with_error_drain () =
    B.with_runtime @@ fun _ctx rt ->
    let clean = Queue.unbounded () in
    check_ok Alcotest.unit "send before clean close" ()
      (B.run rt (Queue.send clean 1));
    Queue.close clean;
    check_ok Alcotest.int "drain after clean close" 1
      (B.run rt (Queue.take clean));
    expect_fail (( = ) `Closed) (B.run rt (Queue.take clean));

    let errored = Queue.unbounded () in
    check_ok Alcotest.unit "send before error close" ()
      (B.run rt (Queue.send errored 2));
    Queue.close_with_error errored `Boom;
    check_ok Alcotest.int "drain after error close" 2
      (B.run rt (Queue.take errored));
    expect_fail
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt (Queue.take errored))

  let test_channel_close_and_close_with_error_drain () =
    B.with_runtime @@ fun _ctx rt ->
    let clean = Channel.create ~capacity:2 () in
    check_ok Alcotest.unit "send before clean close" ()
      (B.run rt (Channel.send clean 1));
    Channel.close clean;
    check_ok Alcotest.int "drain after clean close" 1
      (B.run rt (Channel.recv clean));
    expect_fail (( = ) `Closed) (B.run rt (Channel.recv clean));

    let errored = Channel.create ~capacity:2 () in
    check_ok Alcotest.unit "send before error close" ()
      (B.run rt (Channel.send errored 2));
    Channel.close_with_error errored `Boom;
    check_ok Alcotest.int "drain after error close" 2
      (B.run rt (Channel.recv errored));
    expect_fail
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt (Channel.recv errored))

  let test_pubsub_close_with_error_drains_subscription () =
    B.with_runtime @@ fun _ctx rt ->
    let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let eff =
      Pubsub.subscribe hub (fun sub ->
          Pubsub.publish hub 1
          |> E.bind (fun _ ->
                 E.sync (fun () -> Pubsub.close_with_error hub `Boom))
          |> E.bind (fun () ->
                 Pubsub.recv sub
                 |> E.bind (fun first ->
                        Pubsub.recv sub |> E.map (fun second -> (first, second)))))
    in
    expect_fail
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt eff)

  let test_handoff_close_effect_helpers () =
    B.with_runtime @@ fun _ctx rt ->
    let queue = Queue.unbounded () in
    check_ok Alcotest.unit "queue clean close effect" ()
      (B.run rt (Queue.close_effect queue));
    expect_fail (( = ) `Closed) (B.run rt (Queue.take queue));

    let channel = Channel.create ~capacity:1 () in
    check_ok Alcotest.unit "channel error close effect" ()
      (B.run rt (Channel.close_with_error_effect channel `Boom));
    expect_fail
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt (Channel.recv channel));

    let clean_hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let clean_pubsub =
      Pubsub.subscribe clean_hub (fun sub ->
          Pubsub.close_effect clean_hub |> E.bind (fun () -> Pubsub.recv sub))
    in
    expect_fail (( = ) `Closed) (B.run rt clean_pubsub);

    let error_hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
    let error_pubsub =
      Pubsub.subscribe error_hub (fun sub ->
          Pubsub.close_with_error_effect error_hub `Boom
          |> E.bind (fun () -> Pubsub.recv sub))
    in
    expect_fail
      (function `Closed_with_error `Boom -> true | _ -> false)
      (B.run rt error_pubsub)

  let test_semaphore_validation_and_with_permits_cleanup () =
    B.with_runtime @@ fun _ctx rt ->
    Alcotest.check_raises "zero permits"
      (Invalid_argument "Eta.Semaphore.make: permits must be > 0")
      (fun () -> ignore (Semaphore.make ~permits:0));
    let semaphore = Semaphore.make ~permits:2 in
    check_ok Alcotest.unit "acquire" () (B.run rt (Semaphore.acquire semaphore 2));
    Alcotest.(check int) "available after acquire" 0
      (Semaphore.available semaphore);
    Semaphore.release semaphore 2;
    Alcotest.(check int) "available after release" 2
      (Semaphore.available semaphore);
    let failing =
      Semaphore.with_permits semaphore 2 (fun () -> E.fail `Boom)
    in
    expect_fail (( = ) `Boom) (B.run rt failing);
    Alcotest.(check int) "released after failure" 2
      (Semaphore.available semaphore)

  let test_pool_basic_reuse () =
    B.with_runtime @@ fun _ctx rt ->
    let opened = ref 0 in
    let closed = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr opened;
          !opened)
    in
    let release _ = E.sync (fun () -> incr closed) in
    let eff =
      Pool.create ~max_size:1 ~acquire ~release ()
      |> E.bind (fun pool ->
             Pool.with_resource pool (fun conn -> E.pure conn)
             |> E.bind (fun first ->
                    Pool.with_resource pool (fun conn -> E.pure (first, conn))))
    in
    check_ok (Alcotest.pair Alcotest.int Alcotest.int) "reused" (1, 1)
      (B.run rt eff);
    Alcotest.(check int) "not closed while runtime alive" 0 !closed

  let test_pool_body_failure_and_defect_release_resource () =
    B.with_runtime @@ fun _ctx rt ->
    let opened = ref 0 in
    let closed = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr opened;
          !opened)
    in
    let release _ = E.sync (fun () -> incr closed) in
    let pool = run_ok rt (Pool.create ~max_size:1 ~acquire ~release ()) in
    expect_fail (( = ) `Boom)
      (B.run rt (Pool.with_resource pool (fun _ -> E.fail `Boom)));
    let stats_after_failure = Pool.stats pool in
    Alcotest.(check int) "idle after typed failure" 1
      stats_after_failure.Pool.idle;
    Alcotest.(check int) "active after typed failure" 0
      stats_after_failure.Pool.active;

    B.run rt
      (Pool.with_resource pool (fun _ ->
           E.sync (fun () -> failwith "body defect")))
    |> expect_die;
    let stats_after_defect = Pool.stats pool in
    Alcotest.(check int) "idle after defect" 1 stats_after_defect.Pool.idle;
    Alcotest.(check int) "active after defect" 0
      stats_after_defect.Pool.active;
    check_ok Alcotest.unit "shutdown" ()
      (B.run rt (Pool.shutdown ~deadline:(Duration.ms 100) pool));
    Alcotest.(check int) "closed on shutdown" 1 !closed

  let test_pool_release_defect_releases_capacity () =
    B.with_runtime @@ fun _ctx rt ->
    let opened = ref 0 in
    let closed = ref 0 in
    let release_attempts = ref 0 in
    let acquire =
      E.sync (fun () ->
          incr opened;
          !opened)
    in
    let release _ =
      E.sync (fun () ->
          incr release_attempts;
          incr closed;
          if !release_attempts = 1 then failwith "release defect")
    in
    let pool =
      run_ok rt
        (Pool.create ~max_size:1 ~max_idle:0 ~acquire ~release ())
    in
    B.run rt (Pool.with_resource pool (fun _ -> E.unit))
    |> expect_finalizer_die;
    let after_defect = Pool.stats pool in
    Alcotest.(check int) "active after release defect" 0
      after_defect.Pool.active;
    Alcotest.(check int) "closed after release defect" 1
      after_defect.Pool.closed;
    check_ok Alcotest.int "capacity reusable" 2
      (B.run rt (Pool.with_resource pool E.pure));
    check_ok Alcotest.unit "shutdown" ()
      (B.run rt (Pool.shutdown ~deadline:(Duration.ms 100) pool))

  let test_supervisor_observes_failure () =
    B.with_runtime @@ fun _ctx rt ->
    let eff =
      Supervisor.scoped
        {
          run =
            (fun (type s) sup ->
              let open Supervisor.Scope in
              let* (_child : (s, [> `Boom ], int) Supervisor.child) =
                start sup (fail `Boom)
              in
              let* () = yield in
              failures sup);
        }
    in
    match B.run rt eff with
    | Exit.Ok [ Cause.Fail `Boom ] -> ()
    | Exit.Ok _ -> Alcotest.fail "unexpected supervisor failure list"
    | Exit.Error cause ->
        Alcotest.failf "expected observed failure, got %a"
          (Cause.pp pp_hidden) cause

  let test_supervisor_await_and_cancel () =
    B.with_test_clock @@ fun _ctx _clock rt ->
    let await_program =
      Supervisor.scoped
        {
          run =
            (fun (type s) sup ->
              let open Supervisor.Scope in
              let* (child : (s, [> `Boom ], int) Supervisor.child) =
                start sup (fail `Boom)
              in
              await child);
        }
    in
    expect_fail (( = ) `Boom) (B.run rt await_program);

    let finalizer_ran = ref false in
    let child =
      E.acquire_release ~acquire:E.unit
        ~release:(fun () -> E.sync (fun () -> finalizer_ran := true))
      |> E.bind (fun () -> E.delay (Duration.ms 1_000) E.unit)
    in
    let cancel_program =
      Supervisor.scoped
        {
          run =
            (fun (type s) sup ->
              let open Supervisor.Scope in
              let* (child : (s, [> `Boom ], unit) Supervisor.child) =
                start sup (lift child)
              in
              let* () = yield in
              let* () = cancel child in
              await child);
        }
    in
    match B.run rt cancel_program with
    | Exit.Error (Cause.Interrupt None) ->
        Alcotest.(check bool) "finalizer ran" true !finalizer_ran
    | Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a" (Cause.pp pp_hidden) cause
    | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

  let test_runtime_contract_locals_and_stream () =
    B.with_runtime @@ fun _ctx rt ->
    let local = Rc.create_local () in
    let locals_eff =
      E.Expert.make ~capabilities:[ `Concurrency ] @@ fun context ->
      let contract = E.Expert.contract context in
      let result =
        contract.Rc.local_with_binding local 42 (fun () ->
            contract.Rc.run_scope @@ fun sw ->
            let promise, resolver = contract.Rc.create_promise () in
            contract.Rc.fork sw (fun () ->
                contract.Rc.resolve_promise resolver
                  (contract.Rc.local_get local));
            contract.Rc.await_promise promise)
      in
      match result with
      | Some value -> Exit.Ok value
      | None -> Exit.Error (Cause.Fail `Missing_local)
    in
    check_ok Alcotest.int "local" 42 (B.run rt locals_eff);

    let stream_eff =
      E.Expert.make ~capabilities:[ `Concurrency ] @@ fun context ->
      let contract = E.Expert.contract context in
      let stream = contract.Rc.create_stream 2 in
      let values =
        contract.Rc.run_scope @@ fun sw ->
        contract.Rc.fork sw (fun () ->
            contract.Rc.stream_add stream 1;
            contract.Rc.stream_add stream 2);
        let first = contract.Rc.stream_take stream in
        let second = contract.Rc.stream_take stream in
        (first, second)
      in
      Exit.Ok values
    in
    check_ok (Alcotest.pair Alcotest.int Alcotest.int) "stream fifo" (1, 2)
      (B.run rt stream_eff)

  let test_runtime_contract_callbacks_stay_on_owner_domain () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let owner = Domain.self () in
    contract.Rc.protect (fun () ->
        check_owner_domain owner "protect callback");
    contract.Rc.run_scope ~name:"same-domain conformance" (fun child_scope ->
        check_owner_domain owner "run_scope callback";
        let promise, resolver = contract.Rc.create_promise () in
        contract.Rc.fork child_scope (fun () ->
            check_owner_domain owner "fork callback";
            contract.Rc.resolve_promise resolver (Domain.self ()));
        expect_owner_domain owner "promise await resumed on owner"
          (contract.Rc.await_promise promise);
        let stream = contract.Rc.create_stream 2 in
        contract.Rc.fork child_scope (fun () ->
            check_owner_domain owner "stream producer callback";
            contract.Rc.stream_add stream (Domain.self ()));
        expect_owner_domain owner "stream take resumed on owner"
          (contract.Rc.stream_take stream);
        contract.Rc.stream_add stream (Domain.self ());
        expect_owner_domain owner "stream take_nonblocking stayed on owner"
          (Option.get (contract.Rc.stream_take_nonblocking stream)));
    let daemon_promise, daemon_resolver = contract.Rc.create_promise () in
    contract.Rc.fork_daemon contract.Rc.root_scope (fun () ->
        check_owner_domain owner "daemon callback";
        contract.Rc.resolve_promise daemon_resolver (Domain.self ());
        `Stop_daemon);
    expect_owner_domain owner "daemon promise resolved on owner"
      (contract.Rc.await_promise daemon_promise);
    let cancelled = Failure "same-domain cancellation" in
    let cancellation_observed = ref false in
    contract.Rc.cancel_sub (fun ctx ->
        check_owner_domain owner "cancel_sub callback";
        contract.Rc.cancel ctx cancelled;
        try
          contract.Rc.check ();
          Alcotest.fail "expected cancellation checkpoint"
        with exn -> (
          check_owner_domain owner "cancellation observed on owner";
          match contract.Rc.cancellation_reason exn with
          | Some reason when reason == cancelled -> cancellation_observed := true
          | Some reason ->
              Alcotest.failf "unexpected cancellation reason: %s"
                (Printexc.to_string reason)
          | None -> raise exn));
    Alcotest.(check bool)
      "cancellation reason observed" true !cancellation_observed;
    let local = Rc.create_local () in
    contract.Rc.local_with_binding local 42 (fun () ->
        check_owner_domain owner "local callback";
        Alcotest.(check (option int))
          "local binding" (Some 42) (contract.Rc.local_get local))

  let test_runtime_contract_resolve_wakes_live_waiter () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let promise, resolver = contract.Rc.create_promise () in
    let waiter_started, waiter_started_resolver = B.create_promise () in
    let waiter_result, waiter_result_resolver = B.create_promise () in
    contract.Rc.run_scope ~name:"live resolver conformance"
      (fun child_scope ->
        contract.Rc.fork child_scope (fun () ->
            B.resolve waiter_started_resolver ();
            let value = contract.Rc.await_promise promise in
            B.resolve waiter_result_resolver value);
        let () = await_resolved "live waiter start" waiter_started in
        contract.Rc.yield ();
        Alcotest.(check bool)
          "waiter blocked before resolution" false
          (B.is_resolved waiter_result);
        contract.Rc.resolve_promise resolver 17;
        Alcotest.(check int)
          "live waiter observed resolved value" 17
          (await_resolved "live waiter result" waiter_result))

  let test_runtime_contract_resolve_after_waiter_cancellation () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let promise, resolver = contract.Rc.create_promise () in
    let started, started_resolver = contract.Rc.create_promise () in
    let cancelled, cancelled_resolver = contract.Rc.create_promise () in
    contract.Rc.run_scope ~name:"resolver cancellation conformance"
      (fun child_scope ->
        contract.Rc.fork child_scope (fun () ->
            contract.Rc.cancel_sub @@ fun cancel_ctx ->
            contract.Rc.resolve_promise started_resolver cancel_ctx;
            try ignore (contract.Rc.await_promise promise : int) with
            | exn -> (
                match contract.Rc.cancellation_reason exn with
                | Some _ -> contract.Rc.resolve_promise cancelled_resolver ()
                | None -> raise exn));
        let cancel_ctx = contract.Rc.await_promise started in
        contract.Rc.cancel cancel_ctx (Failure "cancel promise waiter");
        contract.Rc.await_promise cancelled;
        contract.Rc.resolve_promise resolver 42;
        Alcotest.(check int)
          "resolved promise remains observable" 42
          (contract.Rc.await_promise promise));
    Alcotest.(check pass)
      "resolver tolerated canceled waiter" () ()

  let test_runtime_contract_canceled_waiter_does_not_strand_live_waiter () =
    B.with_runtime_contract @@ fun _ctx contract ->
    let promise, resolver = contract.Rc.create_promise () in
    let canceled_started, canceled_started_resolver = B.create_promise () in
    let canceled_done, canceled_done_resolver = B.create_promise () in
    let live_started, live_started_resolver = B.create_promise () in
    let live_result, live_result_resolver = B.create_promise () in
    contract.Rc.run_scope ~name:"mixed waiter resolver conformance"
      (fun child_scope ->
        contract.Rc.fork child_scope (fun () ->
            contract.Rc.cancel_sub @@ fun cancel_ctx ->
            B.resolve canceled_started_resolver cancel_ctx;
            try ignore (contract.Rc.await_promise promise : int) with
            | exn -> (
                match contract.Rc.cancellation_reason exn with
                | Some _ -> B.resolve canceled_done_resolver ()
                | None -> raise exn));
        let cancel_ctx =
          await_resolved "canceled waiter start" canceled_started
        in
        contract.Rc.cancel cancel_ctx (Failure "cancel one promise waiter");
        let () =
          await_resolved "canceled waiter observed cancel" canceled_done
        in
        contract.Rc.fork child_scope (fun () ->
            B.resolve live_started_resolver ();
            let value = contract.Rc.await_promise promise in
            B.resolve live_result_resolver value);
        let () = await_resolved "live waiter start" live_started in
        contract.Rc.yield ();
        Alcotest.(check bool)
          "live waiter blocked before resolution" false
          (B.is_resolved live_result);
        contract.Rc.resolve_promise resolver 23;
        Alcotest.(check int)
          "live waiter observed value after peer cancel" 23
          (await_resolved "live waiter result after peer cancel" live_result))

  let test_runtime_queue_wakeups_stay_on_owner_domain () =
    B.with_runtime @@ fun ctx rt ->
    let owner = Domain.self () in
    let queue = Queue.bounded ~capacity:1 () in
    run_ok rt (Queue.send queue 1);
    let sender =
      B.fork_run ctx rt
        (Queue.send queue 2 |> E.map (fun () -> Domain.self ()))
    in
    B.yield ();
    Alcotest.(check bool) "sender waits for queue capacity" false
      (B.is_resolved sender);
    let receiver_domain =
      run_ok rt (Queue.take queue |> E.map (fun _ -> Domain.self ()))
    in
    expect_owner_domain owner "queue receiver resumed on owner" receiver_domain;
    expect_owner_domain owner "queue sender resumed on owner" (expect_ok (B.await sender))

  let test_runtime_cancellation_cleanup_stays_on_owner_domain () =
    B.with_runtime @@ fun ctx rt ->
    let owner = Domain.self () in
    let started = ref false in
    let finalizer_domain = ref None in
    let program =
      E.acquire_release
        ~acquire:(E.sync (fun () -> started := true))
        ~release:(fun () ->
          E.sync (fun () -> finalizer_domain := Some (Domain.self ())))
      |> E.bind (fun () -> B.await_cancel_effect ())
    in
    let fiber = B.fork_run_cancelable ctx rt program in
    wait_until "cancelable effect start" (fun () -> !started);
    B.cancel_fiber fiber;
    (match B.await_cancelable fiber with
    | `Cancelled -> ()
    | `Returned (Exit.Ok _) -> Alcotest.fail "expected cancellation, got Ok"
    | `Returned (Exit.Error cause) ->
        Alcotest.failf "expected cancellation, got %a" (Cause.pp pp_hidden)
          cause);
    Alcotest.(check (option bool))
      "cancellation finalizer ran on owner" (Some true)
      (Option.map (fun domain -> domain = owner) !finalizer_domain)

  let test_runtime_daemon_callbacks_stay_on_owner_domain () =
    B.with_runtime @@ fun _ctx rt ->
    let owner = Domain.self () in
    let daemon_domain = ref None in
    B.run rt (E.daemon (E.sync (fun () -> daemon_domain := Some (Domain.self ()))))
    |> expect_ok |> ignore;
    B.drain rt;
    Alcotest.(check (option bool))
      "daemon effect ran on owner" (Some true)
      (Option.map (fun domain -> domain = owner) !daemon_domain)

  let test_daemon_drain () =
    B.with_runtime @@ fun _ctx rt ->
    let completed = ref false in
    B.run rt (E.daemon (E.sync (fun () -> completed := true)))
    |> expect_ok |> ignore;
    B.drain rt;
    Alcotest.(check bool) "daemon completed" true !completed

  let test_runtime_fork_daemon_scope_does_not_join () =
    B.with_test_clock @@ fun ctx clock rt ->
    let daemon_scope =
      E.Expert.make ~capabilities:[ `Concurrency; `Background ] @@ fun context ->
      let contract = E.Expert.contract context in
      try
        contract.Rc.run_scope @@ fun sw ->
        contract.Rc.fork_daemon sw (fun () -> contract.Rc.await_cancel ());
        Exit.Ok ()
      with exn -> E.Expert.exit_of_exn context exn
    in
    let promise =
      B.fork_run ctx rt
        (E.timeout_as (Eta.Duration.ms 50) ~on_timeout:`Timeout daemon_scope)
    in
    wait_until "daemon scope result or timeout sleeper" (fun () ->
        B.is_resolved promise || B.sleeper_count clock >= 1);
    if not (B.is_resolved promise) then B.adjust_clock clock (Duration.ms 50);
    match B.await promise with
    | Exit.Ok () -> ()
    | Exit.Error (Cause.Fail `Timeout) ->
        Alcotest.fail "runtime joined a daemon child inside run_scope"
    | Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a" (Cause.pp pp_hidden) cause

  let test_observability_named_span () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    B.run rt (E.named "shared.runtime.span" (E.pure 1))
    |> check_ok Alcotest.int "value" 1;
    match Tracer.dump tracer with
    | [ span ] ->
        Alcotest.(check string) "span name" "shared.runtime.span"
          span.Tracer.name
    | spans ->
        Alcotest.failf "expected one span, got %d" (List.length spans)

  let tests =
    [
      ( "Effect core",
        [
          Alcotest.test_case "pure bind catch" `Quick test_pure_bind_catch;
          Alcotest.test_case "fold recover shape" `Quick test_recover;
          Alcotest.test_case "ignore_errors" `Quick test_ignore_errors;
          Alcotest.test_case "to_result" `Quick test_result;
          Alcotest.test_case "yield" `Quick test_yield;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "from_result and exit to_result" `Quick
            test_from_result_and_exit_to_result;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_map_bind_tap_runtime;
          Alcotest.test_case "tap observer runtime" `Quick
            test_tap_observer_runtime;
          Alcotest.test_case "map_error" `Quick test_map_error;
          Alcotest.test_case "map_error maps full cause" `Quick
            test_map_error_maps_full_cause;
          Alcotest.test_case "sync defect" `Quick test_sync_defect;
          Alcotest.test_case "backtrace capture flag" `Quick
            test_backtrace_capture_flag;
          Alcotest.test_case "run_exn preserves backtrace" `Quick
            test_run_exn_uses_captured_backtrace;
          Alcotest.test_case "run_exn preserves typed failure diagnostics"
            `Quick test_run_exn_preserves_typed_failure_diagnostics;
          Alcotest.test_case "finally cleanup failure after success" `Quick
            test_finally_cleanup_failure_after_success;
          Alcotest.test_case "finally suppressed cleanup failure" `Quick
            test_finally_suppressed_cleanup_failure;
        ] );
      ( "Time and resources",
        [
          Alcotest.test_case "delay with test clock" `Quick
            test_delay_with_test_clock;
          Alcotest.test_case "timeout releases resource" `Quick
            test_timeout_releases_resource;
          Alcotest.test_case "timeout fast success and nested outer timeout"
            `Quick test_timeout_fast_success_and_nested_outer_timeout;
          Alcotest.test_case "acquire_release ordering and root finalizer"
            `Quick test_acquire_release_ordering_and_root_finalizer;
          Alcotest.test_case "acquire_release releases on defect" `Quick
            test_acquire_release_releases_on_defect;
          Alcotest.test_case "acquire_use_release success and lexical" `Quick
            test_acquire_use_release_success_and_lexical;
          Alcotest.test_case "acquire_use_release typed failure" `Quick
            test_acquire_use_release_typed_failure;
          Alcotest.test_case "acquire_use_release defect releases" `Quick
            test_acquire_use_release_defect_releases;
          Alcotest.test_case "retry repeat" `Quick test_retry_repeat;
          Alcotest.test_case "with_background cancels child" `Quick
            test_with_background_cancels_child;
          Alcotest.test_case "daemon drain" `Quick test_daemon_drain;
          Alcotest.test_case "runtime daemon scope does not join" `Quick
            test_runtime_fork_daemon_scope_does_not_join;
          Alcotest.test_case "runtime daemon callbacks stay on owner domain"
            `Quick test_runtime_daemon_callbacks_stay_on_owner_domain;
        ] );
      ( "Concurrency",
        [
          Alcotest.test_case "all preserves delayed input order" `Quick
            test_all_preserves_delayed_input_order;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_outcomes;
          Alcotest.test_case "all empty and fail-fast finalizer" `Quick
            test_all_empty_and_fail_fast_finalizer;
          Alcotest.test_case "race cancels loser finalizer" `Quick
            test_race_cancels_loser_finalizer;
          Alcotest.test_case "map_par caps concurrency" `Quick
            test_map_par_caps_concurrency;
          Alcotest.test_case "map_par rejects nonpositive max"
            `Quick test_map_par_rejects_nonpositive_max;
        ] );
      ( "Primitives",
        [
          Alcotest.test_case "queue channel semaphore pubsub" `Quick
            test_queue_channel_semaphore_pubsub;
          Alcotest.test_case "queue wakeups stay on owner domain" `Quick
            test_runtime_queue_wakeups_stay_on_owner_domain;
          Alcotest.test_case "queue close and close_with_error drain" `Quick
            test_queue_close_and_close_with_error_drain;
          Alcotest.test_case "channel close and close_with_error drain" `Quick
            test_channel_close_and_close_with_error_drain;
          Alcotest.test_case "pubsub close_with_error drains subscription"
            `Quick test_pubsub_close_with_error_drains_subscription;
          Alcotest.test_case "handoff close effect helpers" `Quick
            test_handoff_close_effect_helpers;
          Alcotest.test_case "semaphore validation and cleanup" `Quick
            test_semaphore_validation_and_with_permits_cleanup;
          Alcotest.test_case "pool basic reuse" `Quick test_pool_basic_reuse;
          Alcotest.test_case "pool body failure and defect release" `Quick
            test_pool_body_failure_and_defect_release_resource;
          Alcotest.test_case "pool release defect releases capacity" `Quick
            test_pool_release_defect_releases_capacity;
        ] );
      ( "Supervisor and contract",
        [
          Alcotest.test_case "supervisor observes failure" `Quick
            test_supervisor_observes_failure;
          Alcotest.test_case "supervisor await and cancel" `Quick
            test_supervisor_await_and_cancel;
          Alcotest.test_case "runtime contract locals and stream" `Quick
            test_runtime_contract_locals_and_stream;
          Alcotest.test_case "runtime contract callbacks stay on owner domain"
            `Quick test_runtime_contract_callbacks_stay_on_owner_domain;
          Alcotest.test_case "runtime contract resolve wakes live waiter" `Quick
            test_runtime_contract_resolve_wakes_live_waiter;
          Alcotest.test_case "runtime contract resolve after waiter cancel"
            `Quick test_runtime_contract_resolve_after_waiter_cancellation;
          Alcotest.test_case
            "runtime contract canceled waiter does not strand live waiter" `Quick
            test_runtime_contract_canceled_waiter_does_not_strand_live_waiter;
          Alcotest.test_case "cancellation cleanup stays on owner domain" `Quick
            test_runtime_cancellation_cleanup_stays_on_owner_domain;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "named span" `Quick test_observability_named_span;
        ] );
    ]
end
