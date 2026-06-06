(* Property/stress tests for Eta modules using randomized operation sequences.
   Uses Random with fixed seeds for reproducibility. *)

open Eta
open Eta_test
open Test_eta_support

(* -------------------------------------------------------------------------- *)
(* Pool stress: random concurrent acquire/release with timeouts and failures.
   Invariant: after all operations settle, active=0 and no resource is leaked. *)

type pool_stress_conn = { id : int; mutable closed : bool }

let pool_stress_factory =
  let next = ref 0 in
  let live = ref 0 in
  ( (fun () -> incr next; incr live; { id = !next; closed = false }),
    (fun conn -> if not conn.closed then (conn.closed <- true; decr live)),
    live )

let test_pool_stress_no_resource_leak () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let open_fn, close_fn, live = pool_stress_factory in
  let pool =
    run_ok rt
      (Pool.create ~name:"stress.pool" ~max_size:4
         ~acquire:(Effect.sync open_fn)
         ~release:(fun conn -> Effect.sync (fun () -> close_fn conn))
         ())
  in
  (* Run 20 concurrent workers that use and release the pool *)
  let workers =
    List.init 20 (fun _ ->
        Pool.with_resource pool (fun _conn -> Effect.unit)
        |> Effect.catch (fun _ -> Effect.unit))
  in
  (match Runtime.run rt (Effect.all workers) with
  | Exit.Ok _ -> ()
  | Exit.Error (Cause.Die { exn; _ }) ->
      Alcotest.failf "pool stress workers died: %s" (Printexc.to_string exn)
  | Exit.Error cause ->
      Alcotest.failf "pool stress workers failed: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<pool>")) cause);
  (* After all workers, shut down the pool *)
  (match Runtime.run rt (Pool.shutdown ~deadline:(Duration.seconds 2) pool) with
  | Exit.Ok () -> ()
  | Exit.Error _ -> ());
  (* Invariant: no live resources after shutdown *)
  let stats = Pool.stats pool in
  Alcotest.(check int) "active after stress" 0 stats.Pool.active;
  Alcotest.(check int) "idle after stress" 0 stats.Pool.idle;
  Alcotest.(check int) "live resources" 0 !live

(* -------------------------------------------------------------------------- *)
(* Semaphore stress: concurrent acquire/release/cancel with permit accounting.
   Invariant: available + in_use = max_permits at all times. *)

let test_semaphore_stress_permit_accounting () =
  with_runtime @@ fun rt ->
  let max_permits = 5 in
  let sem = Semaphore.make ~permits:max_permits in
  let rng = Stdlib.Random.State.make [| 17 |] in
  (* 30 workers that acquire, hold briefly, release — some with timeout *)
  let workers =
    List.init 30 (fun _ ->
        let hold_ms = Stdlib.Random.State.int rng 3 in
        let timeout_ms = if Stdlib.Random.State.int rng 5 < 1 then Some 1 else None in
        let acquire_use_release =
          Semaphore.with_permits sem 1 (fun () ->
              Effect.delay (Duration.ms hold_ms) Effect.unit)
        in
        match timeout_ms with
        | None -> acquire_use_release
        | Some ms ->
            acquire_use_release
            |> Effect.timeout (Duration.ms ms)
            |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.unit))
  in
  ignore (run_ok rt (Effect.all workers) : unit list);
  (* After all workers: all permits should be returned *)
  let available = Semaphore.available sem in
  Alcotest.(check int) "all permits returned" max_permits available;
  Alcotest.(check int) "no waiters" 0 (Semaphore.waiting sem)

(* -------------------------------------------------------------------------- *)
(* Channel stress: concurrent senders and receivers with cancellation.
   Invariant: sent count = received count (no lost messages). *)

let test_channel_stress_no_lost_messages () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ch = Channel.create ~capacity:4 () in
  let n_messages = 100 in
  let received = Atomic.make 0 in
  (* Sender: sends n_messages sequentially *)
  let sender =
    Effect.for_each_par_bounded ~max:4
      (List.init n_messages (fun i -> i))
      (fun i -> Channel.send ch i)
  in
  (* Receiver: receives until channel is closed *)
  let receiver =
    let rec loop () =
      Channel.recv ch
      |> Effect.bind (fun _value ->
             Effect.sync (fun () -> Atomic.incr received)
             |> Effect.bind (fun () -> loop ()))
      |> Effect.catch (function
           | `Closed -> Effect.unit
           | `Closed_with_error _ -> Effect.unit)
    in
    loop ()
  in
  let send_promise = fork_run sw rt sender in
  let recv_promise = fork_run sw rt receiver in
  (* Wait for sender to finish, then close channel *)
  (match Eio.Promise.await send_promise with
  | Exit.Ok _ -> ()
  | Exit.Error _ -> Alcotest.fail "sender failed");
  Channel.close ch;
  (match Eio.Promise.await recv_promise with
  | Exit.Ok () -> ()
  | Exit.Error _ -> Alcotest.fail "receiver failed");
  let stats = Channel.stats ch in
  Alcotest.(check int) "sent count" n_messages stats.Channel.sent;
  Alcotest.(check int) "received count" n_messages (Atomic.get received);
  Alcotest.(check int) "sent = received (no lost messages)"
    stats.Channel.sent stats.Channel.received

(* -------------------------------------------------------------------------- *)
(* Effect.retry resource accumulation property test.
   Already confirmed as a bug — this stress tests various retry counts
   to ensure the issue is systematic. *)

let test_retry_resource_accumulation_systematic () =
  with_runtime @@ fun rt ->
  let test_with_n n =
    let active = ref 0 in
    let max_active = ref 0 in
    let attempts = ref 0 in
    let acquire =
      Effect.sync (fun () -> incr active; max_active := max !max_active !active)
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
        (Effect.retry (Schedule.recurs (n + 1)) (fun (`Retry _) -> true) attempt)
    in
    ignore (run_ok rt eff : int);
    (* Key check: max_active should be 1, not n *)
    if !max_active > 1 then
      Alcotest.failf
        "retry with %d failed attempts held %d resources concurrently \
         (expected max 1)"
        (n - 1) !max_active
  in
  (* Test with various retry counts *)
  List.iter test_with_n [ 2; 3; 5; 10 ]

(* -------------------------------------------------------------------------- *)
(* Nested scope + catch + retry: verify scoped releases always fire even
   with complex nesting combinations. *)

let test_nested_scope_catch_retry_releases_all () =
  with_runtime @@ fun rt ->
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
    Effect.sync (fun () -> decr active; incr released_count)
  in
  (* Nested: outer scope with resource A, inner retry that acquires resource B
     and fails. The retry is wrapped in catch to recover. *)
  let attempts = ref 0 in
  let eff =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(acquire "outer")
         ~release:(release "outer")
      |> Effect.bind (fun () ->
             (* Inner: retry with scoped resource per attempt *)
             Effect.retry (Schedule.recurs 3)
               (fun (`Inner_retry _) -> true)
               (Effect.scoped
                  (Effect.acquire_release
                     ~acquire:(acquire "inner")
                     ~release:(release "inner")
                  |> Effect.bind (fun () ->
                         incr attempts;
                         if !attempts < 3 then
                           Effect.fail (`Inner_retry !attempts)
                         else Effect.pure !attempts)))
             |> Effect.catch (fun (`Inner_retry n) ->
                    Effect.pure n)))
  in
  let result = run_ok rt eff in
  Alcotest.(check int) "result" 3 result;
  Alcotest.(check int) "all released" 0 !active;
  (* outer + 3 inner (each scoped) = 4 releases total *)
  Alcotest.(check int) "release count" 4 !released_count;
  (* With scoped inside retry, max_active should be 2 (outer + one inner) *)
  Alcotest.(check int) "max active with scoped retry" 2 !max_active

(* -------------------------------------------------------------------------- *)
(* Race + retry interaction: when a race is won by a fast branch while a retry
   branch has accumulated resources (the retry bug), verify the resources ARE
   eventually released when the enclosing scope exits. *)

let test_race_retry_accumulated_resources_released_on_scope_exit () =
  with_test_clock @@ fun sw clock rt ->
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
      (Schedule.both (Schedule.recurs 10) (Schedule.spaced (Duration.ms 5)))
      (fun (`Again _) -> true)
      (Effect.acquire_release ~acquire ~release
      |> Effect.bind (fun () -> Effect.fail (`Again 0)))
  in
  let fast_branch =
    Effect.delay (Duration.ms 20) (Effect.pure "fast")
  in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () -> Effect.unit)
      |> Effect.bind (fun () ->
             Effect.race [ retry_branch; fast_branch ]))
  in
  let promise = fork_run sw rt eff in
  (* Advance clock to let retry fail a few times, then fast branch wins *)
  for _ = 1 to 5 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 5)
  done;
  check_exit_ok Alcotest.string "fast wins" "fast"
    (Eio.Promise.await promise);
  (* After the scoped eff returns, all resources should be released *)
  Alcotest.(check int) "all released after scope" 0 !active

(* -------------------------------------------------------------------------- *)
(* all_settled with scoped resources: verify that each branch's scoped
   resources are properly released when the settled result is collected. *)

let test_all_settled_scoped_resources_released_per_branch () =
  with_test_clock @@ fun sw clock rt ->
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
      [ make_scoped_branch false; make_scoped_branch true; make_scoped_branch false ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  match Eio.Promise.await promise with
  | Exit.Ok [ Ok "ok"; Error (Cause.Fail `Branch_error); Ok "ok" ] ->
      (* All 3 scoped resources should be released *)
      Alcotest.(check int) "all settled branches released" 3
        (Atomic.get released)
  | result ->
      Alcotest.failf "unexpected all_settled result: %a"
        (Exit.pp (fun fmt _ -> Format.pp_print_string fmt "<list>")
           (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        result

(* -------------------------------------------------------------------------- *)
(* Stress: race with many branches, some failing, some succeeding. Verify
   that exactly one winner is returned and all losers' resources are released. *)

let test_race_many_branches_resource_cleanup () =
  with_test_clock @@ fun sw clock rt ->
  let released = Atomic.make 0 in
  let make_branch i =
    let delay_ms = (i + 1) * 5 in
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () -> Effect.sync (fun () -> Atomic.incr released))
      |> Effect.bind (fun () ->
             Effect.delay (Duration.ms delay_ms) (Effect.pure i)))
  in
  let eff = Effect.race (List.init 10 make_branch) in
  let promise = fork_run sw rt eff in
  (* Advance past all branches (50ms max) + cleanup time *)
  for _ = 1 to 15 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 10)
  done;
  (match Eio.Promise.await promise with
  | Exit.Ok 0 -> ()
  | Exit.Ok other ->
      Alcotest.failf "expected winner 0, got %d" other
  | Exit.Error cause ->
      Alcotest.failf "expected winner, got error: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause);
  (* Give losers extra time to clean up *)
  for _ = 1 to 10 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 10)
  done;
  (* All 10 branches should have released their scoped resources *)
  Alcotest.(check int) "all race branches released" 10
    (Atomic.get released)

(* -------------------------------------------------------------------------- *)
(* Randomized eff composition: generate random nested eff trees and
   verify that all scoped resources are properly released. *)

let generate_random_effect max_depth rng ~active =
  let rec gen depth =
    if depth >= max_depth then
      if Stdlib.Random.State.bool rng then Effect.pure (Stdlib.Random.State.int rng 100)
      else Effect.sync (fun () -> Stdlib.Random.State.int rng 100)
    else
      let choice = Stdlib.Random.State.int rng 6 in
      match choice with
      | 0 ->
          Effect.acquire_release
            ~acquire:(Effect.sync (fun () -> incr active))
            ~release:(fun () -> Effect.sync (fun () -> decr active))
          |> Effect.bind (fun () -> gen (depth + 1))
      | 1 -> gen (depth + 1) |> Effect.map (fun n -> n + 1)
      | 2 ->
          gen (depth + 1) |> Effect.bind (fun n ->
            if n mod 5 = 0 then Effect.fail (`Fail n)
            else Effect.pure n)
      | 3 ->
          Effect.scoped (
            Effect.acquire_release
              ~acquire:(Effect.sync (fun () -> incr active))
              ~release:(fun () -> Effect.sync (fun () -> decr active))
            |> Effect.bind (fun () -> gen (depth + 1)))
      | 4 -> gen (depth + 1) |> Effect.catch (fun (`Fail n) -> Effect.pure (-n))
      | 5 -> gen (depth + 1) |> Effect.finally (Effect.sync (fun () -> ()))
      | _ -> Effect.pure 0
  in
  gen 0

let test_randomized_effect_compositions_release_resources () =
  with_runtime @@ fun rt ->
  let rng = Stdlib.Random.State.make [| 42; 137; 256 |] in
  for _ = 1 to 50 do
    let active = ref 0 in
    let eff = generate_random_effect 5 rng ~active in
    (match Runtime.run rt eff with
    | Exit.Ok _ -> ()
    | Exit.Error _ -> ());
    if !active <> 0 then
      Alcotest.failf "random eff leaked %d resources" !active
  done

let test_randomized_race_compositions_release_resources () =
  with_test_clock @@ fun sw clock rt ->
  let rng = Stdlib.Random.State.make [| 17; 31; 73 |] in
  for _ = 1 to 20 do
    let active = ref 0 in
    let n_branches = 2 + Stdlib.Random.State.int rng 4 in
    let branches = List.init n_branches (fun i ->
      generate_random_effect 3 rng ~active
      |> Effect.delay (Duration.ms ((i + 1) * 2)))
    in
    let eff = Effect.race branches in
    let promise = fork_run sw rt eff in
    for _ = 1 to 10 do
      (try wait_for_sleepers clock 1 with _ -> ());
      Test_clock.adjust clock (Duration.ms 5)
    done;
    (match Eio.Promise.await promise with
    | Exit.Ok _ -> ()
    | Exit.Error _ -> ());
    if !active <> 0 then
      Alcotest.failf "random race leaked %d resources" !active
  done

let test_randomized_all_compositions_release_resources () =
  with_test_clock @@ fun sw clock rt ->
  let rng = Stdlib.Random.State.make [| 7; 13; 19 |] in
  for _ = 1 to 20 do
    let active = ref 0 in
    let n_effects = 2 + Stdlib.Random.State.int rng 4 in
    let effects = List.init n_effects (fun i ->
      generate_random_effect 3 rng ~active
      |> Effect.delay (Duration.ms ((i + 1) * 2)))
    in
    let eff = Effect.all effects in
    let promise = fork_run sw rt eff in
    for _ = 1 to 10 do
      (try wait_for_sleepers clock 1 with _ -> ());
      Test_clock.adjust clock (Duration.ms 5)
    done;
    (match Eio.Promise.await promise with
    | Exit.Ok _ -> ()
    | Exit.Error _ -> ());
    if !active <> 0 then
      Alcotest.failf "random all leaked %d resources" !active
  done

(* GREEN TEST: Effect.all without scoped wrapper releases resources at scope
   exit (not per-branch). When acquire_release is used inside all, the
   finalizer is added to the outer frame and released when the outer scope
   exits. Unlike retry, all does not accumulate resources across branches
   because branches are concurrent and all finalizers run together at the
   end. *)
let test_all_without_scoped_releases_at_scope_exit () =
  with_test_clock @@ fun sw clock rt ->
  let active = Atomic.make 0 in
  let worker i =
    Effect.acquire_release
      ~acquire:(Effect.sync (fun () -> Atomic.incr active))
      ~release:(fun () ->
        Effect.sync (fun () -> Atomic.decr active))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) (Effect.pure i))
  in
  let promise = fork_run sw rt (Effect.all [ worker 0; worker 1 ]) in
  for _ = 1 to 5 do
    (try wait_for_sleepers clock 1 with _ -> ());
    Test_clock.adjust clock (Duration.ms 5)
  done;
  let result = Eio.Promise.await promise in
  (match result with
  | Exit.Ok [ 0; 1 ] -> ()
  | Exit.Ok other -> Alcotest.failf "unexpected result: %a" Fmt.(Dump.list int) other
  | Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause);
  Alcotest.(check int) "resources released after branch completion" 0
    (Atomic.get active)

(* -------------------------------------------------------------------------- *)
(* Par with scoped resource: when one branch fails while another holds a
   scoped resource, verify the resource is released. *)

let test_par_scoped_resource_released_on_failure () =
  with_test_clock @@ fun sw clock rt ->
  let released = Atomic.make false in
  let slow =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:Effect.unit
         ~release:(fun () ->
           Effect.sync (fun () -> Atomic.set released true))
      |> Effect.bind (fun () -> Effect.delay (Duration.ms 10) Effect.unit))
  in
  let fast =
    Effect.named "fast" (Effect.sync (fun () -> Eio.Fiber.yield ()))
    |> Effect.bind (fun () -> Effect.fail `Boom)
  in
  let eff = Effect.par fast slow in
  let promise = fork_run sw rt eff in
  for _ = 1 to 5 do
    (try wait_for_sleepers clock 1 with _ -> ());
    Test_clock.adjust clock (Duration.ms 5)
  done;
  (match Eio.Promise.await promise with
  | Exit.Error _ -> () (* expected: fast branch failed *)
  | Exit.Ok _ -> Alcotest.fail "expected failure");
  Alcotest.(check bool) "scoped resource released" true (Atomic.get released)

(* -------------------------------------------------------------------------- *)
(* for_each_par cancellation: when a task fails, remaining workers should
   be cancelled and their resources released. *)

let test_for_each_par_cancelled_workers_release_resources () =
  with_test_clock @@ fun sw clock rt ->
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
  let eff = Effect.for_each_par_bounded ~max:4 [ 0; 1; 2; 3; 4 ] worker in
  let promise = fork_run sw rt eff in
  (* Let the failing task execute and cancel others *)
  (try wait_for_sleepers clock 1 with _ -> ());
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  (match Eio.Promise.await promise with
  | Exit.Error (Cause.Concurrent causes) ->
      let has_fail = List.exists (function Cause.Fail (`Worker_fail 2) -> true | _ -> false) causes in
      if not has_fail then
        Alcotest.failf "expected Worker_fail 2 in concurrent causes"
  | Exit.Error cause ->
      Alcotest.failf "expected Concurrent cause, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok _ -> Alcotest.fail "expected failure");
  (* Wait for all workers to complete and release resources *)
  for _ = 1 to 20 do
    (try wait_for_sleepers clock 1 with _ -> ());
    Test_clock.adjust clock (Duration.ms 10)
  done;
  let started_count = Atomic.get started in
  let released_count = Atomic.get released in
  Alcotest.(check int) "all started workers released" started_count released_count
