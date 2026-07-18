module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let pp_hidden ppf _ = Format.pp_print_string ppf "<stress>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let wait_for_sleepers clock expected =
    let rec loop attempts =
      if B.sleeper_count clock >= expected then ()
      else if attempts = 0 then
        Alcotest.failf "expected at least %d sleepers, got %d" expected
          (B.sleeper_count clock)
      else (
        B.yield ();
        loop (attempts - 1))
    in
    loop 200

  let advance_clock clock duration =
    for _ = 1 to 20 do
      if B.sleeper_count clock = 0 then B.yield ()
    done;
    B.adjust_clock clock duration

  type pool_stress_conn = { id : int; mutable closed : bool }

  let make_pool_stress_factory () =
    let next = ref 0 in
    let live = ref 0 in
    ( (fun () ->
        incr next;
        incr live;
        { id = !next; closed = false }),
      (fun conn ->
        if not conn.closed then (
          conn.closed <- true;
          decr live)),
      live )

  let test_pool_stress_no_resource_leak () =
    B.with_runtime @@ fun _ctx rt ->
    let open_fn, close_fn, live = make_pool_stress_factory () in
    let pool =
      run_ok rt
        (Pool.create ~name:"stress.pool" ~max_size:4
           ~acquire:(Effect.sync open_fn)
           ~release:(fun conn -> Effect.sync (fun () -> close_fn conn))
           ())
    in
    let workers =
      List.init 20 (fun _ ->
          Pool.with_resource pool (fun _conn -> Effect.unit)
          |> Effect.ignore_errors)
    in
    (match B.run rt (Effect.all workers) with
    | Exit.Ok _ -> ()
    | Exit.Error (Cause.Die { exn; _ }) ->
        Alcotest.failf "pool stress workers died: %s" (Printexc.to_string exn)
    | Exit.Error cause ->
        Alcotest.failf "pool stress workers failed: %a" (Cause.pp pp_hidden)
          cause);
    ignore (B.run rt (Pool.shutdown ~deadline:(Duration.seconds 2) pool));
    let stats = Pool.stats pool in
    Alcotest.(check int) "active after stress" 0 stats.Pool.active;
    Alcotest.(check int) "idle after stress" 0 stats.Pool.idle;
    Alcotest.(check int) "live resources" 0 !live

  let test_semaphore_stress_permit_accounting () =
    B.with_test_clock @@ fun ctx clock rt ->
    let max_permits = 5 in
    let sem = Semaphore.make ~permits:max_permits in
    let rng = Stdlib.Random.State.make [| 17 |] in
    let workers =
      List.init 30 (fun _ ->
          let hold_ms = Stdlib.Random.State.int rng 3 in
          let timeout_ms =
            if Stdlib.Random.State.int rng 5 < 1 then Some 1 else None
          in
          let acquire_use_release =
            Semaphore.with_permits sem 1 (fun () ->
                Effect.delay (Duration.ms hold_ms) Effect.unit)
          in
          match timeout_ms with
          | None -> acquire_use_release
          | Some ms ->
              acquire_use_release
              |> Effect.timeout (Duration.ms ms)
              |> Effect.bind_error (fun (`Timeout : [ `Timeout ]) ->
                     Effect.unit))
    in
    let promise = B.fork_run ctx rt (Effect.all workers) in
    for _ = 1 to 10 do
      if not (B.is_resolved promise) then advance_clock clock (Duration.ms 1)
    done;
    (match B.await promise with
    | Exit.Ok (_ : unit list) -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check int)
      "all permits returned" max_permits (Semaphore.available sem);
    Alcotest.(check int) "no waiters" 0 (Semaphore.waiting sem)

  let test_channel_stress_no_lost_messages () =
    B.with_runtime @@ fun ctx rt ->
    let ch = Channel.create ~capacity:4 () in
    let n_messages = 100 in
    let received = Atomic.make 0 in
    let sender =
      Effect.map_par ~max_concurrent:4
        (fun i -> Channel.send ch i)
        (List.init n_messages (fun i -> i))
    in
    let receiver =
      let rec loop () =
        Channel.recv ch
        |> Effect.bind (fun _value ->
               Effect.sync (fun () -> Atomic.incr received)
               |> Effect.bind (fun () -> loop ()))
        |> Effect.bind_error (function
             | `Closed -> Effect.unit
             | `Closed_with_error _ -> Effect.unit)
      in
      loop ()
    in
    let send_promise = B.fork_run ctx rt sender in
    let recv_promise = B.fork_run ctx rt receiver in
    (match B.await send_promise with
    | Exit.Ok _ -> ()
    | Exit.Error _ -> Alcotest.fail "sender failed");
    Channel.close ch;
    (match B.await recv_promise with
    | Exit.Ok () -> ()
    | Exit.Error _ -> Alcotest.fail "receiver failed");
    let stats = Channel.stats ch in
    Alcotest.(check int) "sent count" n_messages stats.Channel.sent;
    Alcotest.(check int) "received count" n_messages (Atomic.get received);
    Alcotest.(check int) "sent = received" stats.Channel.sent
      stats.Channel.received

  let test_retry_resource_accumulation_systematic () =
    B.with_runtime @@ fun _ctx rt ->
    let test_with_n n =
      let active = ref 0 in
      let max_active = ref 0 in
      let attempts = ref 0 in
      let acquire =
        Effect.sync (fun () ->
            incr active;
            max_active := max !max_active !active)
      in
      let release () = Effect.sync (fun () -> decr active) in
      let attempt =
        Effect.acquire_release ~acquire ~release
        |> Effect.bind (fun () ->
               incr attempts;
               if !attempts < n then Effect.fail (`Retry !attempts)
               else Effect.pure !attempts)
      in
      let eff =
        Effect.scoped
          (Effect.retry
             ~schedule:(Schedule.recurs (n + 1))
             ~while_:(fun (`Retry _) -> true)
             attempt)
      in
      ignore (run_ok rt eff : int);
      if !max_active > 1 then
        Alcotest.failf
          "retry with %d failed attempts held %d resources concurrently"
          (n - 1) !max_active
    in
    List.iter test_with_n [ 2; 3; 5; 10 ]

  let test_nested_scope_catch_retry_releases_all () =
    B.with_runtime @@ fun _ctx rt ->
    let active = ref 0 in
    let max_active = ref 0 in
    let released_count = ref 0 in
    let acquire label =
      Effect.sync (fun () ->
          ignore label;
          incr active;
          max_active := max !max_active !active)
    in
    let release _label () =
      Effect.sync (fun () ->
          decr active;
          incr released_count)
    in
    let attempts = ref 0 in
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:(acquire "outer")
           ~release:(release "outer")
        |> Effect.bind (fun () ->
               Effect.retry
                 ~schedule:(Schedule.recurs 3)
                 ~while_:(fun (`Inner_retry _) -> true)
                 (Effect.scoped
                    (Effect.acquire_release ~acquire:(acquire "inner")
                       ~release:(release "inner")
                    |> Effect.bind (fun () ->
                           incr attempts;
                           if !attempts < 3 then
                             Effect.fail (`Inner_retry !attempts)
                           else Effect.pure !attempts)))
               |> Effect.bind_error (fun (`Inner_retry n) -> Effect.pure n)))
    in
    let result = run_ok rt eff in
    Alcotest.(check int) "result" 3 result;
    Alcotest.(check int) "all released" 0 !active;
    Alcotest.(check int) "release count" 4 !released_count;
    Alcotest.(check int) "max active with scoped retry" 2 !max_active

  let test_race_retry_accumulated_resources_released_on_scope_exit () =
    B.with_test_clock @@ fun ctx clock rt ->
    let active = ref 0 in
    let max_active = ref 0 in
    let acquire =
      Effect.sync (fun () ->
          incr active;
          max_active := max !max_active !active)
    in
    let release () = Effect.sync (fun () -> decr active) in
    let retry_branch =
      Effect.retry
        ~schedule:
          (Schedule.both (Schedule.recurs 10)
             (Schedule.spaced (Duration.ms 5)))
        ~while_:(fun (`Again _) -> true)
        (Effect.acquire_release ~acquire ~release
        |> Effect.bind (fun () -> Effect.fail (`Again 0)))
    in
    let fast_branch = Effect.delay (Duration.ms 20) (Effect.pure "fast") in
    let eff =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () -> Effect.unit)
        |> Effect.bind (fun () -> Effect.race [ retry_branch; fast_branch ]))
    in
    let promise = B.fork_run ctx rt eff in
    for _ = 1 to 5 do
      advance_clock clock (Duration.ms 5)
    done;
    (match B.await promise with
    | Exit.Ok "fast" -> ()
    | Exit.Ok other -> Alcotest.failf "expected fast winner, got %s" other
    | Exit.Error cause ->
        Alcotest.failf "expected fast winner, got %a" (Cause.pp pp_hidden)
          cause);
    Alcotest.(check int) "all released after scope" 0 !active

  let test_all_settled_scoped_resources_released_per_branch () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = Atomic.make 0 in
    let make_scoped_branch fail =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () -> Effect.sync (fun () -> Atomic.incr released))
        |> Effect.bind (fun () ->
               if fail then Effect.fail `Branch_error
               else Effect.delay (Duration.ms 10) (Effect.pure "ok")))
    in
    let eff =
      Effect.all_settled
        [
          make_scoped_branch false;
          make_scoped_branch true;
          make_scoped_branch false;
        ]
    in
    let promise = B.fork_run ctx rt eff in
    wait_for_sleepers clock 1;
    B.adjust_clock clock (Duration.ms 10);
    match B.await promise with
    | Exit.Ok [ Ok "ok"; Error (Cause.Fail `Branch_error); Ok "ok" ] ->
        Alcotest.(check int)
          "all settled branches released" 3 (Atomic.get released)
    | result ->
        Alcotest.failf "unexpected all_settled result: %a"
          (Exit.pp (fun fmt _ -> Format.pp_print_string fmt "<list>")
             (fun fmt _ -> Format.pp_print_string fmt "<err>"))
          result

  let test_race_many_branches_resource_cleanup () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = Atomic.make 0 in
    let make_branch i =
      let delay_ms = (i + 1) * 5 in
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () -> Effect.sync (fun () -> Atomic.incr released))
        |> Effect.bind (fun () ->
               Effect.delay (Duration.ms delay_ms) (Effect.pure i)))
    in
    let promise = B.fork_run ctx rt (Effect.race (List.init 10 make_branch)) in
    for _ = 1 to 15 do
      advance_clock clock (Duration.ms 10)
    done;
    (match B.await promise with
    | Exit.Ok 0 -> ()
    | Exit.Ok other -> Alcotest.failf "expected winner 0, got %d" other
    | Exit.Error cause ->
        Alcotest.failf "expected winner, got error: %a" (Cause.pp pp_hidden)
          cause);
    for _ = 1 to 10 do
      advance_clock clock (Duration.ms 10)
    done;
    Alcotest.(check int) "all race branches released" 10 (Atomic.get released)

  let generate_random_effect max_depth rng ~active =
    let rec gen depth =
      if depth >= max_depth then
        if Stdlib.Random.State.bool rng then
          Effect.pure (Stdlib.Random.State.int rng 100)
        else Effect.sync (fun () -> Stdlib.Random.State.int rng 100)
      else
        match Stdlib.Random.State.int rng 6 with
        | 0 ->
            Effect.acquire_release
              ~acquire:(Effect.sync (fun () -> incr active))
              ~release:(fun () -> Effect.sync (fun () -> decr active))
            |> Effect.bind (fun () -> gen (depth + 1))
        | 1 -> gen (depth + 1) |> Effect.map (fun n -> n + 1)
        | 2 ->
            gen (depth + 1)
            |> Effect.bind (fun n ->
                   if n mod 5 = 0 then Effect.fail (`Fail n)
                   else Effect.pure n)
        | 3 ->
            Effect.scoped
              (Effect.acquire_release
                 ~acquire:(Effect.sync (fun () -> incr active))
                 ~release:(fun () -> Effect.sync (fun () -> decr active))
              |> Effect.bind (fun () -> gen (depth + 1)))
        | 4 ->
            gen (depth + 1) |> Effect.bind_error (fun (`Fail n) -> Effect.pure (-n))
        | 5 -> gen (depth + 1) |> Effect.finally (Effect.sync (fun () -> ()))
        | _ -> Effect.pure 0
    in
    gen 0

  let test_randomized_effect_compositions_release_resources () =
    B.with_runtime @@ fun _ctx rt ->
    let rng = Stdlib.Random.State.make [| 42; 137; 256 |] in
    for _ = 1 to 50 do
      let active = ref 0 in
      let eff = generate_random_effect 5 rng ~active in
      ignore (B.run rt eff);
      if !active <> 0 then
        Alcotest.failf "random eff leaked %d resources" !active
    done

  let test_randomized_race_compositions_release_resources () =
    B.with_test_clock @@ fun ctx clock rt ->
    let rng = Stdlib.Random.State.make [| 17; 31; 73 |] in
    for _ = 1 to 20 do
      let active = ref 0 in
      let n_branches = 2 + Stdlib.Random.State.int rng 4 in
      let branches =
        List.init n_branches (fun i ->
            generate_random_effect 3 rng ~active
            |> Effect.delay (Duration.ms ((i + 1) * 2)))
      in
      let promise = B.fork_run ctx rt (Effect.race branches) in
      for _ = 1 to 10 do
        advance_clock clock (Duration.ms 5)
      done;
      ignore (B.await promise);
      if !active <> 0 then
        Alcotest.failf "random race leaked %d resources" !active
    done

  let test_randomized_all_compositions_release_resources () =
    B.with_test_clock @@ fun ctx clock rt ->
    let rng = Stdlib.Random.State.make [| 7; 13; 19 |] in
    for _ = 1 to 20 do
      let active = ref 0 in
      let n_effects = 2 + Stdlib.Random.State.int rng 4 in
      let effects =
        List.init n_effects (fun i ->
            generate_random_effect 3 rng ~active
            |> Effect.delay (Duration.ms ((i + 1) * 2)))
      in
      let promise = B.fork_run ctx rt (Effect.all effects) in
      for _ = 1 to 10 do
        advance_clock clock (Duration.ms 5)
      done;
      ignore (B.await promise);
      if !active <> 0 then
        Alcotest.failf "random all leaked %d resources" !active
    done

  let test_all_without_scoped_releases_at_scope_exit () =
    B.with_test_clock @@ fun ctx clock rt ->
    let active = Atomic.make 0 in
    let worker i =
      Effect.acquire_release
        ~acquire:(Effect.sync (fun () -> Atomic.incr active))
        ~release:(fun () -> Effect.sync (fun () -> Atomic.decr active))
      |> Effect.bind (fun () ->
             Effect.delay (Duration.ms 10) (Effect.pure i))
    in
    let promise = B.fork_run ctx rt (Effect.all [ worker 0; worker 1 ]) in
    for _ = 1 to 5 do
      advance_clock clock (Duration.ms 5)
    done;
    (match B.await promise with
    | Exit.Ok [ 0; 1 ] -> ()
    | Exit.Ok _ -> Alcotest.fail "unexpected all result"
    | Exit.Error cause ->
        Alcotest.failf "unexpected error: %a" (Cause.pp pp_hidden) cause);
    Alcotest.(check int)
      "resources released after branch completion" 0 (Atomic.get active)

  let test_par_scoped_resource_released_on_failure () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = Atomic.make false in
    let slow =
      Effect.scoped
        (Effect.acquire_release ~acquire:Effect.unit
           ~release:(fun () ->
             Effect.sync (fun () -> Atomic.set released true))
        |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) Effect.unit))
    in
    let fast =
      Effect.named "fast" (B.yield_effect ())
      |> Effect.bind (fun () -> Effect.fail `Boom)
    in
    let promise = B.fork_run ctx rt (Effect.par fast slow) in
    for _ = 1 to 5 do
      advance_clock clock (Duration.ms 5)
    done;
    (match B.await promise with
    | Exit.Error _ -> ()
    | Exit.Ok _ -> Alcotest.fail "expected failure");
    Alcotest.(check bool) "scoped resource released" true (Atomic.get released)

  let test_map_par_cancelled_workers_release_resources () =
    B.with_test_clock @@ fun ctx clock rt ->
    let released = Atomic.make 0 in
    let started = Atomic.make 0 in
    let worker i =
      Effect.scoped
        (Effect.acquire_release
           ~acquire:(Effect.sync (fun () -> Atomic.incr started))
           ~release:(fun () -> Effect.sync (fun () -> Atomic.incr released))
        |> Effect.bind (fun () ->
               if i = 2 then Effect.fail (`Worker_fail i)
               else Effect.delay (Duration.ms 100) (Effect.pure i)))
    in
    let eff = Effect.map_par ~max_concurrent:4 worker [ 0; 1; 2; 3; 4 ] in
    let promise = B.fork_run ctx rt eff in
    advance_clock clock (Duration.ms 5);
    B.yield ();
    let has_worker_fail =
      let rec loop = function
        | Cause.Fail (`Worker_fail 2) -> true
        | Cause.Fail (`Worker_fail _) -> false
        | Cause.Sequential causes | Cause.Concurrent causes ->
            List.exists loop causes
        | Cause.Suppressed { primary; finalizer = _ } -> loop primary
        | Cause.Die _ | Cause.Interrupt _ | Cause.Finalizer _ -> false
      in
      loop
    in
    (match B.await promise with
    | Exit.Error cause when has_worker_fail cause -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Worker_fail 2, got %a" (Cause.pp pp_hidden)
          cause
    | Exit.Ok _ -> Alcotest.fail "expected failure");
    for _ = 1 to 20 do
      advance_clock clock (Duration.ms 10)
    done;
    Alcotest.(check int)
      "all started workers released" (Atomic.get started) (Atomic.get released)

  let tests =
    [
      ( "Stress",
        [
          Alcotest.test_case "pool no resource leak" `Quick
            test_pool_stress_no_resource_leak;
          Alcotest.test_case "semaphore permit accounting" `Quick
            test_semaphore_stress_permit_accounting;
          Alcotest.test_case "channel no lost messages" `Quick
            test_channel_stress_no_lost_messages;
          Alcotest.test_case "retry resource accumulation systematic" `Quick
            test_retry_resource_accumulation_systematic;
          Alcotest.test_case "nested scope catch retry releases all" `Quick
            test_nested_scope_catch_retry_releases_all;
          Alcotest.test_case "race+retry resources released on scope exit"
            `Quick test_race_retry_accumulated_resources_released_on_scope_exit;
          Alcotest.test_case "all_settled scoped resources released" `Quick
            test_all_settled_scoped_resources_released_per_branch;
          Alcotest.test_case "race many branches resource cleanup" `Quick
            test_race_many_branches_resource_cleanup;
          Alcotest.test_case "randomized eff compositions release" `Quick
            test_randomized_effect_compositions_release_resources;
          Alcotest.test_case "randomized race compositions release" `Quick
            test_randomized_race_compositions_release_resources;
          Alcotest.test_case "randomized all compositions release" `Quick
            test_randomized_all_compositions_release_resources;
          Alcotest.test_case "all without scoped releases at scope exit"
            `Quick test_all_without_scoped_releases_at_scope_exit;
          Alcotest.test_case "par scoped resource released on failure" `Quick
            test_par_scoped_resource_released_on_failure;
          Alcotest.test_case "map_par cancelled workers release" `Quick
            test_map_par_cancelled_workers_release_resources;
        ] );
    ]
end
