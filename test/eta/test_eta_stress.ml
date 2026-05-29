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
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let open_fn, close_fn, live = pool_stress_factory in
  let pool =
    run_ok rt
      (Pool.create ~name:"stress.pool" ~max_size:4
         ~acquire:(Effect.sync open_fn)
         ~release:(fun conn -> Effect.sync (fun () -> close_fn conn))
         ~health_check:(fun conn ->
           if conn.id mod 7 = 0 then Effect.fail `Health_failed
           else Effect.unit)
         ())
  in
  let rng = Stdlib.Random.State.make [| 42 |] in
  let errors = ref 0 in
  let successes = ref 0 in
  (* Run 50 concurrent workers that randomly use the pool *)
  let workers =
    List.init 50 (fun _ ->
        let hold_ms = Stdlib.Random.State.int rng 5 in
        let should_timeout = Stdlib.Random.State.int rng 10 < 2 in
        let use =
          Pool.with_resource pool (fun _conn ->
              Effect.delay (Duration.ms hold_ms) Effect.unit)
          |> Effect.map_error (fun _ -> `Pool_err)
        in
        let effect =
          if should_timeout then
            use |> Effect.timeout (Duration.ms 1)
            |> Effect.catch (fun _ -> Effect.unit)
          else
            use |> Effect.catch (fun _ -> Effect.unit)
        in
        effect
        |> Effect.catch (fun _ -> Effect.sync (fun () -> incr errors))
        |> Effect.tap (fun () -> Effect.sync (fun () -> incr successes)))
  in
  ignore (run_ok rt (Effect.all workers) : unit list);
  (* After all workers, shut down the pool *)
  run_ok rt (Pool.shutdown ~deadline:(Duration.ms 500) pool);
  (* Invariant: no live resources after shutdown *)
  let stats = Pool.stats pool in
  Alcotest.(check int) "active after stress" 0 stats.Pool.active;
  Alcotest.(check int) "idle after stress" 0 stats.Pool.idle;
  Alcotest.(check int) "live resources" 0 !live;
  Alcotest.(check bool) "some operations ran" true (!successes + !errors > 0)

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
  Eio_main.run @@ fun stdenv ->
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
