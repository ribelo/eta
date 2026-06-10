module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let pp_hidden ppf _ = Format.pp_print_string ppf "<err>"

  let check_ok testable label expected = function
    | Eta.Exit.Ok actual -> Alcotest.check testable label expected actual
    | Eta.Exit.Error cause ->
        Alcotest.failf "%s: unexpected error %a" label
          (Eta.Cause.pp pp_hidden) cause

  let run_ok rt eff =
    match B.run rt eff with
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected error %a" (Eta.Cause.pp pp_hidden) cause

  let wait_until ?(attempts = 200) pred =
    let rec loop n =
      if pred () then ()
      else if n = 0 then Alcotest.fail "condition did not become true"
      else (
        B.yield ();
        loop (n - 1))
    in
    loop attempts

  let wait_for_sleepers clock expected =
    wait_until (fun () -> B.sleeper_count clock >= expected)

  let advance_by_ms_until_resolved clock promise limit =
    let rec loop remaining =
      if B.is_resolved promise then ()
      else if remaining = 0 then Alcotest.fail "effect did not complete"
      else (
        B.adjust_clock clock (Eta.Duration.ms 1);
        B.yield ();
        loop (remaining - 1))
    in
    loop limit

  let settle_until_resolved ?(attempts = 40) promise =
    let rec loop remaining =
      if B.is_resolved promise then ()
      else if remaining = 0 then Alcotest.fail "effect did not complete"
      else (
        B.yield ();
        loop (remaining - 1))
    in
    loop attempts

  let rec advance_until_resolved clock promise remaining =
    if B.is_resolved promise then ()
    else if remaining = 0 then settle_until_resolved promise
    else (
      if B.sleeper_count clock = 0 then B.yield ();
      B.adjust_clock clock (Eta.Duration.ms 50);
      advance_until_resolved clock promise (remaining - 1))

  let test_basic_abc () =
    B.with_runtime @@ fun _ctx rt ->
    Eta_stream.Stream.from_iterable [ 1; 2; 3; 4; 5; 6 ]
    |> Eta_stream.Stream.map (( * ) 2)
    |> Eta_stream.Stream.take 5
    |> fun stream -> Eta_stream.run stream (Eta_stream.Sink.fold ( + ) 0)
    |> B.run rt
    |> check_ok Alcotest.int "sum" 30

  let test_grouped_batches () =
    B.with_runtime @@ fun _ctx rt ->
    let stream =
      Eta_stream.Stream.from_iterable [ 1; 2; 3; 4; 5 ]
      |> Eta_stream.Stream.grouped 2
    in
    Alcotest.(check (list (list int)))
      "batches" [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ]
      (run_ok rt (Eta_stream.run_collect stream))

  let test_take_until_effect_includes_terminal_value () =
    B.with_runtime @@ fun _ctx rt ->
    let seen = ref [] in
    let stream =
      Eta_stream.Stream.from_iterable [ 1; 2; 3; 4; 5 ]
      |> Eta_stream.Stream.take_until_effect (fun value ->
             Eta.Effect.sync (fun () ->
                 seen := value :: !seen;
                 value >= 3))
    in
    Alcotest.(check (list int))
      "values" [ 1; 2; 3 ] (run_ok rt (Eta_stream.run_collect stream));
    Alcotest.(check (list int)) "predicate calls" [ 1; 2; 3 ]
      (List.rev !seen)

  let test_from_queue_clean_close_ends_stream () =
    B.with_runtime @@ fun _ctx rt ->
    let queue = Eta.Queue.create () in
    ignore (run_ok rt (Eta.Queue.send queue 1) : unit);
    ignore (run_ok rt (Eta.Queue.send queue 2) : unit);
    Eta.Queue.close queue;
    Alcotest.(check (list int))
      "queued values" [ 1; 2 ]
      (run_ok rt (Eta_stream.Stream.from_queue queue |> Eta_stream.run_collect))

  let test_from_queue_error_close_fails_after_drain () =
    B.with_runtime @@ fun _ctx rt ->
    let queue = Eta.Queue.create () in
    ignore (run_ok rt (Eta.Queue.send queue 1) : unit);
    ignore (run_ok rt (Eta.Queue.send queue 2) : unit);
    Eta.Queue.close_with_error queue `Broken;
    let seen = ref [] in
    let eff =
      let stream = Eta_stream.Stream.from_queue queue in
      Eta_stream.run stream
        (Eta_stream.Sink.fold_effect
           (fun values value ->
             Eta.Effect.sync (fun () ->
                 seen := value :: !seen;
                 value :: values))
           [])
    in
    (match B.run rt eff with
    | Eta.Exit.Error (Eta.Cause.Fail `Broken) -> ()
    | Eta.Exit.Ok values ->
        Alcotest.failf "error-closed queue unexpectedly succeeded with %d values"
          (List.length values)
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected queue stream failure: %a"
          (Eta.Cause.pp pp_hidden) cause);
    Alcotest.(check (list int)) "drained first" [ 1; 2 ] (List.rev !seen)

  let test_stream_range_stops_at_max_int () =
    B.with_runtime @@ fun _ctx rt ->
    let stream =
      Eta_stream.Stream.range ~start:(max_int - 1) ~stop:max_int
      |> Eta_stream.Stream.take 3
    in
    Alcotest.(check (list int))
      "range stops at max_int"
      [ max_int - 1; max_int ]
      (run_ok rt (Eta_stream.run_collect stream))

  let test_stream_range_pure_fold_stops_at_max_int () =
    B.with_runtime @@ fun _ctx rt ->
    let stream =
      Eta_stream.Stream.range ~start:(max_int - 1) ~stop:max_int
      |> Eta_stream.Stream.map (fun i -> i)
      |> Eta_stream.Stream.take 3
    in
    Alcotest.(check (list int))
      "mapped range stops at max_int"
      [ max_int - 1; max_int ]
      (run_ok rt (Eta_stream.run_collect stream))

  let test_mailbox_stream_close_and_drop () =
    B.with_runtime @@ fun _ctx rt ->
    let mailbox = Eta_stream.Mailbox.create ~capacity:2 () in
    (match Eta_stream.Mailbox.offer mailbox 1 with
    | Enqueued -> ()
    | Dropped | Closed -> Alcotest.fail "expected first offer to enqueue");
    (match Eta_stream.Mailbox.offer mailbox 2 with
    | Enqueued -> ()
    | Dropped | Closed -> Alcotest.fail "expected second offer to enqueue");
    (match Eta_stream.Mailbox.offer mailbox 3 with
    | Dropped -> ()
    | Enqueued | Closed -> Alcotest.fail "expected full mailbox to drop");
    Alcotest.(check int) "dropped" 1 (Eta_stream.Mailbox.dropped mailbox);
    Alcotest.(check int) "length before close" 2
      (Eta_stream.Mailbox.length mailbox);
    Eta_stream.Mailbox.close mailbox;
    Alcotest.(check (list int))
      "drain queued values" [ 1; 2 ]
      (run_ok rt
         (Eta_stream.run_collect (Eta_stream.Mailbox.to_stream mailbox)));
    Alcotest.(check int) "length after drain" 0
      (Eta_stream.Mailbox.length mailbox)

  let test_mailbox_batch_stream_emits_partial () =
    B.with_runtime @@ fun _ctx rt ->
    let mailbox = Eta_stream.Mailbox.create ~capacity:8 () in
    List.iter
      (fun value ->
        match Eta_stream.Mailbox.offer mailbox value with
        | Enqueued -> ()
        | Dropped | Closed -> Alcotest.fail "expected offer to enqueue")
      [ 1; 2; 3 ];
    Eta_stream.Mailbox.close mailbox;
    Alcotest.(check (list (list int)))
      "partial batches" [ [ 1; 2 ]; [ 3 ] ]
      (run_ok rt
         (Eta_stream.run_collect
            (Eta_stream.Mailbox.to_batch_stream ~max:2 mailbox)))

  let test_drain_counter_underflow_raises () =
    let counter = Eta_stream.Drain_counter.create () in
    match Eta_stream.Drain_counter.decr counter with
    | exception Invalid_argument _ -> ()
    | () -> Alcotest.fail "drain counter underflow was silently clamped"

  let test_drain_counter_await_zero () =
    B.with_runtime @@ fun _ctx rt ->
    let counter = Eta_stream.Drain_counter.create () in
    Eta_stream.Drain_counter.incr_by counter 2;
    let waiting, waiting_resolver = B.create_promise () in
    let wait =
      Eta.Effect.sync (fun () -> B.resolve waiting_resolver ())
      |> Eta.Effect.bind (fun () ->
             Eta_stream.Drain_counter.await_zero counter)
    in
    let release =
      B.await_effect waiting
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.sync (fun () ->
                 Eta_stream.Drain_counter.decr_by counter 2))
    in
    B.run rt
      (Eta.Effect.all [ wait; release ]
      |> Eta.Effect.map (fun _ -> ()))
    |> check_ok Alcotest.unit "drain counter reaches zero" ();
    Alcotest.(check int) "counter value" 0
      (Eta_stream.Drain_counter.value counter)

  let delayed_counted_source produced =
    Eta_stream.Stream.from_iterable (List.init 1_000 (fun i -> i))
    |> Eta_stream.Stream.map_effect (fun value ->
           Eta.Effect.named "stream.produced"
             (Eta.Effect.sync (fun () -> incr produced))
           |> Eta.Effect.bind (fun () ->
                  Eta.Effect.delay (Eta.Duration.ms 5)
                    (Eta.Effect.pure value)))

  let test_merge_cancellation () =
    B.with_test_clock @@ fun ctx clock rt ->
    let left_count = ref 0 in
    let right_count = ref 0 in
    let stream =
      Eta_stream.Stream.merge (delayed_counted_source left_count)
        (delayed_counted_source right_count)
      |> Eta_stream.Stream.take 1
    in
    let result = B.fork_run ctx rt (Eta_stream.run_drain stream) in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Eta.Duration.ms 5);
    B.await result |> check_ok Alcotest.unit "merge drain" ();
    Alcotest.(check bool) "left cancelled before full production" true
      (!left_count < 1_000);
    Alcotest.(check bool) "right cancelled before full production" true
      (!right_count < 1_000)

  let test_merge_child_failure_does_not_wait_for_full_queue () =
    B.with_test_clock @@ fun ctx clock rt ->
    let filled, filled_resolver = B.create_promise () in
    let signaled = Atomic.make false in
    let left =
      Eta_stream.Stream.from_iterable (List.init 2_000 (fun i -> i))
      |> Eta_stream.Stream.map_effect (fun value ->
             Eta.Effect.sync (fun () ->
                 if value = 1_024
                    && Atomic.compare_and_set signaled false true
                 then B.resolve filled_resolver ();
                 value))
    in
    let right =
      Eta_stream.Stream.from_effect
        (B.await_effect filled
        |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Boom))
    in
    let slow_drain =
      Eta_stream.Sink.fold_effect
        (fun () _ -> Eta.Effect.delay (Eta.Duration.ms 1) Eta.Effect.unit)
        ()
    in
    let eff =
      Eta_stream.Stream.merge left right
      |> fun stream -> Eta_stream.run stream slow_drain
      |> Eta.Effect.timeout_as (Eta.Duration.ms 500) ~on_timeout:`Timed_out
    in
    let result = B.fork_run ctx rt eff in
    wait_until (fun () -> B.is_resolved result || B.is_resolved filled);
    advance_by_ms_until_resolved clock result 500;
    match B.await result with
    | Eta.Exit.Error (Eta.Cause.Fail `Boom) -> ()
    | Eta.Exit.Error (Eta.Cause.Fail `Timed_out) ->
        Alcotest.fail "merge child failure waited behind a full queue"
    | Eta.Exit.Ok () -> Alcotest.fail "merge unexpectedly succeeded"
    | Eta.Exit.Error cause ->
        Alcotest.failf "merge produced unexpected cause: %a"
          (Eta.Cause.pp pp_hidden) cause

  let test_flat_map_par_concurrency () =
    B.with_test_clock @@ fun ctx clock rt ->
    let current = ref 0 in
    let max_seen = ref 0 in
    let input = Eta_stream.Stream.from_iterable (List.init 100 (fun i -> i)) in
    let stream =
      Eta_stream.Stream.flat_map_par ~max_concurrency:10
        (fun value ->
          Eta_stream.Stream.from_effect
            (Eta.Effect.sync (fun () ->
                 incr current;
                 max_seen := max !max_seen !current)
            |> Eta.Effect.bind (fun () ->
                   Eta.Effect.delay (Eta.Duration.ms 50)
                     (Eta.Effect.pure value))
            |> Eta.Effect.finally
                 (Eta.Effect.sync (fun () -> decr current))))
        input
    in
    let result = B.fork_run ctx rt (Eta_stream.run_collect stream) in
    wait_for_sleepers clock 10;
    Alcotest.(check int) "max first wave" 10 !max_seen;
    advance_until_resolved clock result 20;
    B.await result
    |> check_ok (Alcotest.list Alcotest.int) "all values"
         (List.init 100 (fun i -> i));
    Alcotest.(check int) "max concurrency" 10 !max_seen

  let test_flat_map_par_inner_failure_does_not_deadlock () =
    B.with_test_clock @@ fun ctx clock rt ->
    let stream =
      Eta_stream.Stream.range ~start:1 ~stop:10
      |> Eta_stream.Stream.flat_map_par ~max_concurrency:1 (fun value ->
             if value = 1 then Eta_stream.Stream.fail `Boom
             else Eta_stream.Stream.succeed value)
    in
    let eff =
      Eta_stream.run_drain stream
      |> Eta.Effect.timeout_as (Eta.Duration.ms 1_000)
           ~on_timeout:`Timed_out
    in
    let result = B.fork_run ctx rt eff in
    for _ = 1 to 20 do
      if not (B.is_resolved result) then B.yield ()
    done;
    if not (B.is_resolved result) then (
      wait_for_sleepers clock 1;
      B.adjust_clock clock (Eta.Duration.ms 1_000));
    match B.await result with
    | Eta.Exit.Error (Eta.Cause.Fail `Boom) -> ()
    | Eta.Exit.Error (Eta.Cause.Fail `Timed_out) ->
        Alcotest.fail "flat_map_par inner failure timed out"
    | Eta.Exit.Ok () ->
        Alcotest.fail "flat_map_par inner failure unexpectedly succeeded"
    | Eta.Exit.Error cause ->
        Alcotest.failf
          "flat_map_par inner failure produced unexpected cause: %a"
          (Eta.Cause.pp pp_hidden) cause

  let test_flat_map_par_child_failure_does_not_wait_for_full_queue () =
    B.with_test_clock @@ fun ctx clock rt ->
    let filled, filled_resolver = B.create_promise () in
    let signaled = Atomic.make false in
    let stream =
      Eta_stream.Stream.from_iterable [ 0; 1 ]
      |> Eta_stream.Stream.flat_map_par ~max_concurrency:2 (function
           | 0 ->
               Eta_stream.Stream.from_iterable (List.init 2_000 (fun i -> i))
               |> Eta_stream.Stream.map_effect (fun value ->
                      Eta.Effect.sync (fun () ->
                          if value = 1_024
                             && Atomic.compare_and_set signaled false true
                          then B.resolve filled_resolver ();
                          value))
           | _ ->
               Eta_stream.Stream.from_effect
                 (B.await_effect filled
                 |> Eta.Effect.bind (fun () -> Eta.Effect.fail `Boom)))
    in
    let slow_drain =
      Eta_stream.Sink.fold_effect
        (fun () _ -> Eta.Effect.delay (Eta.Duration.ms 1) Eta.Effect.unit)
        ()
    in
    let eff =
      Eta_stream.run stream slow_drain
      |> Eta.Effect.timeout_as (Eta.Duration.ms 500) ~on_timeout:`Timed_out
    in
    let result = B.fork_run ctx rt eff in
    wait_until (fun () -> B.is_resolved result || B.is_resolved filled);
    advance_by_ms_until_resolved clock result 500;
    match B.await result with
    | Eta.Exit.Error (Eta.Cause.Fail `Boom) -> ()
    | Eta.Exit.Error (Eta.Cause.Fail `Timed_out) ->
        Alcotest.fail
          "flat_map_par child failure waited behind a full queue"
    | Eta.Exit.Ok () -> Alcotest.fail "flat_map_par unexpectedly succeeded"
    | Eta.Exit.Error cause ->
        Alcotest.failf "flat_map_par produced unexpected cause: %a"
          (Eta.Cause.pp pp_hidden) cause

  let test_bounded_queue_no_deadlock () =
    B.with_test_clock @@ fun ctx clock rt ->
    let left = delayed_counted_source (ref 0) in
    let right = delayed_counted_source (ref 0) in
    let eff =
      Eta_stream.Stream.merge left right
      |> Eta_stream.Stream.take 1
      |> Eta_stream.run_drain
      |> Eta.Effect.timeout (Eta.Duration.ms 1_000)
    in
    let result = B.fork_run ctx rt eff in
    wait_for_sleepers clock 2;
    B.adjust_clock clock (Eta.Duration.ms 5);
    B.await result |> check_ok Alcotest.unit "bounded queue completes" ()

  class type db = object
    method get : int
  end

  let row_pipeline clock db () =
    let clock_stream =
      Eta_stream.Stream.from_effect
        (Eta.Effect.named "clock"
           (Eta.Effect.sync (fun () ->
                clock#sleep (Eta.Duration.ms 0);
                1)))
    in
    let db_stream =
      Eta_stream.Stream.from_effect
        (Eta.Effect.named "db" (Eta.Effect.sync (fun () -> db#get)))
    in
    Eta_stream.Stream.merge clock_stream db_stream
    |> Eta_stream.Stream.flat_map_par ~max_concurrency:2 (fun value ->
           Eta_stream.Stream.from_effect
             (if value < 0 then Eta.Effect.fail `Negative
              else Eta.Effect.pure value))
    |> Eta_stream.run_collect

  module type ROW_SIG = sig
    val row_pipeline :
      Eta.Capabilities.clock ->
      db ->
      unit ->
      (int list, [> `Negative ]) Eta.Effect.t
  end

  module _ : ROW_SIG = struct
    let row_pipeline = row_pipeline
  end

  let test_row_pipeline_runtime () =
    B.with_runtime @@ fun _ctx rt ->
    let db =
      object
        method get = 2
      end
    in
    let clock =
      object
        method sleep _duration = ()
      end
    in
    match B.run rt (row_pipeline clock db ()) with
    | Eta.Exit.Ok values ->
        Alcotest.(check (list int)) "row values" [ 1; 2 ]
          (List.sort compare values)
    | Eta.Exit.Error cause ->
        Alcotest.failf "row pipeline failed: %a" (Eta.Cause.pp pp_hidden)
          cause
  let tests =
    [
      ( "Eta_stream",
        [
          Alcotest.test_case "A/B/C map take fold" `Quick test_basic_abc;
          Alcotest.test_case "grouped batches" `Quick test_grouped_batches;
          Alcotest.test_case "take_until_effect includes terminal value" `Quick
            test_take_until_effect_includes_terminal_value;
          Alcotest.test_case "from_queue clean close ends stream" `Quick
            test_from_queue_clean_close_ends_stream;
          Alcotest.test_case "from_queue error close fails after drain" `Quick
            test_from_queue_error_close_fails_after_drain;
          Alcotest.test_case "range stops at max_int" `Quick
            test_stream_range_stops_at_max_int;
          Alcotest.test_case "mapped range stops at max_int" `Quick
            test_stream_range_pure_fold_stops_at_max_int;
          Alcotest.test_case "mailbox closes and drops" `Quick
            test_mailbox_stream_close_and_drop;
          Alcotest.test_case "mailbox batch stream emits partial batches"
            `Quick test_mailbox_batch_stream_emits_partial;
          Alcotest.test_case "drain counter underflow raises" `Quick
            test_drain_counter_underflow_raises;
          Alcotest.test_case "drain counter await zero" `Quick
            test_drain_counter_await_zero;
          Alcotest.test_case "merge cancels upstream on downstream stop"
            `Quick test_merge_cancellation;
          Alcotest.test_case
            "merge child failure does not wait for full queue" `Quick
            test_merge_child_failure_does_not_wait_for_full_queue;
          Alcotest.test_case "flat_map_par is bounded concurrent" `Quick
            test_flat_map_par_concurrency;
          Alcotest.test_case
            "flat_map_par inner failure does not deadlock" `Quick
            test_flat_map_par_inner_failure_does_not_deadlock;
          Alcotest.test_case
            "flat_map_par child failure does not wait for full queue" `Quick
            test_flat_map_par_child_failure_does_not_wait_for_full_queue;
          Alcotest.test_case "bounded queue no deadlock on early stop" `Quick
            test_bounded_queue_no_deadlock;
          Alcotest.test_case "explicit deps/error rows compose" `Quick
            test_row_pipeline_runtime;
        ] );
    ]
end
