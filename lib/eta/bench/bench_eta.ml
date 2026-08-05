(* Core [eta] runtime benchmark.

   Methodology, all of it load-bearing:

   - One Eio runtime and one [Eta_eio.Runtime.t] are created for the whole
     process and reused by every row. Creating them inside a measured region
     costs ~23 us and ~890 words, which is one to three orders of magnitude
     more than a bind, a sync leaf, or a catch. A row that paid that per
     sample measured setup and nothing else. Exactly one row - [setup.*] -
     deliberately pays it, because a binary entry point pays it too.

   - Cheap operations are measured in an inner loop of [ops_per_run]
     iterations, and [~ops] tells the harness how to normalize. Read the
     derived [wall_ns_per_op] and [allocated_words_per_op] rows, not the
     totals.

   - Results are forced through [Sys.opaque_identity] sinks. The suite is
     built with [-O3 -unbox-closures], and a workload whose result is dropped
     is a workload the optimizer is allowed to delete.

   Rows that belong elsewhere and must not be duplicated here:
   [par]/[all]/[race]/[map_par] in bench/runtime_concurrency, [Schedule] and
   scoped resources in bench/runtime_real, tracer/cause/OTLP in
   bench/runtime_observability, deep construction chains in
   bench/effect_construction, and the paired Eta-vs-minimal-interpreter
   controls in bench/runtime_overhead. *)

open Eta

let int_sink = ref 0
let bool_sink = ref false
let one = Sys.opaque_identity 1
let effect_async = Sys.opaque_identity Effect.async

(* One runtime serves every row, so every row must present the same typed error
   channel. Each workload absorbs its own typed failures into a defect here,
   outside its inner loop, which costs one catch per [run] call rather than one
   per measured operation. A benchmark that fails is a broken benchmark, so
   collapsing the channel loses nothing. *)
let absorb : type err. (int, err) Effect.t -> (int, [ `Never ]) Effect.t =
 fun program ->
  Effect.bind_error
    (fun _ -> Effect.sync (fun () -> failwith "benchmark effect failed"))
    program

let run_int rt program =
  match Runtime.run rt (absorb program) with
  | Exit.Ok value -> int_sink := Sys.opaque_identity value
  | Exit.Error _ -> failwith "benchmark effect failed"

(* Every cheap row performs this many operations per measured [run] call, which
   keeps a sample in the hundreds of microseconds - far above the clock's
   resolution and far above any per-sample harness cost. *)
let ops_per_run = 100_000

(* ------------------------------------------------------------------ *)
(* Interpreter core                                                    *)
(* ------------------------------------------------------------------ *)

(* Two distinct bind shapes. They are NOT interchangeable, and an earlier
   version of this file accidentally measured the source-nested shape twice
   under two names - the giveaway was byte-identical allocation counts.

   Source-nested: the chain grows on the source side, so the interpreter walks
   a left spine of [Bind] nodes before it reaches a leaf.
     bind f (bind f (bind f (pure 0)))
   Continuation-nested: the chain grows inside the continuation, so each step
   is discovered only after the previous one runs. This is the shape that
   stresses continuation depth and stack safety.
     bind (fun _ -> bind (fun _ -> ...)) (pure n) *)

let rec bind_source_nested n acc =
  if n = 0 then acc
  else bind_source_nested (n - 1) (Effect.bind (fun x -> Effect.pure (x + one)) acc)

let bind_continuation_nested n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else Effect.bind (fun _ -> go (i - 1)) (Effect.pure i)
  in
  go n

let rec map_nested n acc =
  if n = 0 then acc else map_nested (n - 1) (Effect.map (( + ) one) acc)

let sync_chain n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else Effect.bind (fun _ -> go (i - 1)) (Effect.sync (fun () -> i))
  in
  go n

(* Callback bridges are allowed to resolve before registration returns. This is
   a real path for adapters over APIs that report an already-available result,
   and it isolates Eta's registration/state/promise protocol from scheduler
   wakeup cost. [effect_async] is opaque so the compiler cannot specialize the
   implementation to this benchmark's synchronous callback. *)
let async_immediate_chain n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      effect_async
        ~register:(fun resume ->
          resume (Exit.Ok i);
          None)
      |> Effect.bind (fun value -> go (i - 1) (acc + value))
  in
  go n 0

(* One catch per iteration, looped, so the row is not swamped by the cost of
   entering the runtime. *)
let catch_success_chain n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else
      Effect.bind_error
        (fun (`Boom : [ `Boom ]) -> Effect.pure 0)
        (Effect.pure i)
      |> Effect.bind (fun _ -> go (i - 1))
  in
  go n

let catch_failure_chain n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Effect.bind_error
        (fun (`Boom : [ `Boom ]) -> go (i - 1) (acc + one))
        (Effect.fail `Boom)
  in
  go n 0

let tap_error_chain n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Effect.tap_error (fun (`Boom : [ `Boom ]) -> Effect.unit) (Effect.fail `Boom)
      |> Effect.bind_error (fun (`Boom : [ `Boom ]) -> go (i - 1) (acc + one))
  in
  go n 0

(* ------------------------------------------------------------------ *)
(* Mutable_ref                                                         *)
(* ------------------------------------------------------------------ *)

let mutable_ref_update n =
  let cell = Mutable_ref.make 0 in
  let rec go i =
    if i = 0 then Effect.sync (fun () -> Mutable_ref.get cell)
    else
      Effect.sync (fun () -> Mutable_ref.update cell (( + ) one))
      |> Effect.bind (fun () -> go (i - 1))
  in
  go n

let mutable_ref_compare_and_set n =
  let cell = Mutable_ref.make 0 in
  let rec go i =
    if i = 0 then Effect.pure (Mutable_ref.get cell)
    else
      Effect.sync (fun () -> Mutable_ref.compare_and_set cell (n - i) (n - i + 1))
      |> Effect.bind (fun ok ->
             bool_sink := Sys.opaque_identity ok;
             go (i - 1))
  in
  go n

(* ------------------------------------------------------------------ *)
(* Semaphore                                                           *)
(* ------------------------------------------------------------------ *)

(* Uncontended: one permit is always available, so this is the acquire/release
   fast path with no waiter bookkeeping. *)
let semaphore_uncontended n =
  let sem = Semaphore.make ~permits:1 in
  (* Sequential, never nested: the recursion must happen after the permit is
     released, otherwise the loop asks a 1-permit semaphore for [n]
     simultaneous permits and deadlocks. *)
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Semaphore.with_permits sem 1 (fun () -> Effect.pure one)
      |> Effect.bind (fun v -> go (i - 1) (acc + v))
  in
  go n 0

(* Contended: the permit count is smaller than the number of concurrent
   holders, so every iteration after the first must park and be woken. That is
   the path where a semaphore implementation actually goes wrong. *)
let semaphore_contended ~fibers ~per_fiber =
  let sem = Semaphore.make ~permits:1 in
  let rec hold i =
    if i = 0 then Effect.unit
    else
      Semaphore.with_permits sem 1 (fun () -> Effect.unit)
      |> Effect.bind (fun () -> hold (i - 1))
  in
  Effect.all (List.init fibers (fun _ -> hold per_fiber))
  |> Effect.map (fun (_ : unit list) -> 0)

(* ------------------------------------------------------------------ *)
(* Promise                                                             *)
(* ------------------------------------------------------------------ *)

(* Resolve before await: no parking, measures the settled-read path. *)
let promise_resolve_then_await n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      let p : (int, [ `Never ]) Promise.t = Promise.create () in
      Promise.resolve p (Exit.Ok one)
      |> Effect.bind (fun (_ : bool) ->
             Promise.await p |> Effect.bind (fun v -> go (i - 1) (acc + v)))
  in
  go n 0

(* Await before resolve: the awaiting fiber must park and be woken by the
   resolver, which is the path with real handoff cost.

   Caveat, and the reason the row name says [via_par]: each iteration pays one
   [Effect.par], so this row measures par + promise handoff, not promise
   handoff alone. Read it against bench/runtime_concurrency's [par] rows before
   attributing a delta to [Promise]. *)
let promise_await_then_resolve n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      let p : (int, [ `Never ]) Promise.t = Promise.create () in
      Effect.par
        (Promise.await p)
        (Effect.bind
           (fun () -> Promise.resolve p (Exit.Ok one))
           Effect.yield)
      |> Effect.bind (fun (v, (_ : bool)) -> go (i - 1) (acc + v))
  in
  go n 0

(* ------------------------------------------------------------------ *)
(* Queue                                                               *)
(* ------------------------------------------------------------------ *)

let rec queue_send_loop q i n =
  if i = n then Effect.unit
  else Queue.send q i |> Effect.bind (fun () -> queue_send_loop q (i + 1) n)

let rec queue_take_loop q remaining acc =
  if remaining = 0 then Effect.pure acc
  else
    Queue.take q
    |> Effect.bind (fun value -> queue_take_loop q (remaining - 1) (acc + value))

(* Sequential fill then drain over an unbounded queue: no parking on either
   side, so this measures enqueue/dequeue bookkeeping only. *)
let queue_fill_drain n =
  let q = Queue.unbounded () in
  queue_send_loop q 0 n |> Effect.bind (fun () -> queue_take_loop q n 0)

let queue_try_offer_poll n =
  let q = Queue.unbounded () in
  let rec offer i =
    if i = n then Effect.unit
    else
      Queue.try_offer q i
      |> Effect.bind (function
           | `Sent -> offer (i + 1)
           | `Dropped | `Full | `Closed | `Closed_with_error _ ->
               Effect.sync (fun () -> failwith "queue try_offer failed"))
  in
  let rec poll remaining acc =
    if remaining = 0 then Effect.pure acc
    else
      Queue.poll q
      |> Effect.bind (function
           | `Item value -> poll (remaining - 1) (acc + value)
           | `Empty | `Closed | `Closed_with_error _ ->
               Effect.sync (fun () -> failwith "queue poll missed an item"))
  in
  offer 0 |> Effect.bind (fun () -> poll n 0)

(* A real rendezvous. Capacity 1 is the point: the producer cannot run ahead,
   so every element pays a full block-on-full / block-on-empty handoff and both
   parking paths are exercised. With an unbounded queue this row degenerated
   into [queue_fill_drain] and matched it to within 2%. *)
let queue_rendezvous n =
  let q = Queue.bounded ~capacity:1 () in
  Effect.par (queue_send_loop q 0 n) (queue_take_loop q n 0)
  |> Effect.map (fun ((), sum) -> sum)

(* Several producers against one consumer over a small bounded queue: adds
   waiter-queue contention on the send side. *)
let queue_multi_producer ~producers ~per_producer =
  let q = Queue.bounded ~capacity:4 () in
  let producer _ = queue_send_loop q 0 per_producer in
  Effect.par
    (Effect.all (List.init producers producer))
    (queue_take_loop q (producers * per_producer) 0)
  |> Effect.map (fun ((_ : unit list), sum) -> sum)

(* ------------------------------------------------------------------ *)
(* Channel                                                            *)
(* ------------------------------------------------------------------ *)

let rec channel_send_loop ch i n =
  if i = n then Effect.unit
  else Channel.send ch i |> Effect.bind (fun () -> channel_send_loop ch (i + 1) n)

let rec channel_recv_loop ch remaining acc =
  if remaining = 0 then Effect.pure acc
  else
    Channel.recv ch
    |> Effect.bind (fun value -> channel_recv_loop ch (remaining - 1) (acc + value))

let channel_rendezvous ~capacity n =
  let ch = Channel.create ~capacity () in
  Effect.par (channel_send_loop ch 0 n) (channel_recv_loop ch n 0)
  |> Effect.map (fun ((), sum) -> sum)

(* ------------------------------------------------------------------ *)
(* Pubsub                                                             *)
(* ------------------------------------------------------------------ *)

let rec pubsub_publish_recv_loop hub sub i n acc =
  if i = n then Effect.pure acc
  else
    Pubsub.publish hub i
    |> Effect.bind (fun _ ->
           Pubsub.recv sub
           |> Effect.bind (fun v -> pubsub_publish_recv_loop hub sub (i + 1) n (acc + v)))

let pubsub_publish_recv n =
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  Pubsub.subscribe hub (fun sub -> pubsub_publish_recv_loop hub sub 0 n 0)

let pubsub_publish_recv_fanout ~subscribers n =
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let rec with_subs remaining subs k =
    if remaining = 0 then k (List.rev subs)
    else Pubsub.subscribe hub (fun sub -> with_subs (remaining - 1) (sub :: subs) k)
  in
  with_subs subscribers [] (fun subs ->
      let rec go i acc =
        if i = n then Effect.pure acc
        else
          Pubsub.publish hub i
          |> Effect.bind (fun _ ->
                 let rec drain = function
                   | [] -> Effect.pure acc
                   | sub :: rest -> Pubsub.recv sub |> Effect.bind (fun _ -> drain rest)
                 in
                 drain subs |> Effect.bind (fun _ -> go (i + 1) (acc + one)))
      in
      go 0 0)

(* Publishing into a full Drop_new hub: the drop decision path, with no
   consumer progress. *)
let pubsub_drop_new_full n =
  let hub = Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 1 }) () in
  Pubsub.subscribe hub (fun sub ->
      Pubsub.publish hub 0
      |> Effect.bind (fun _ ->
             let rec go i =
               if i = n then Pubsub.recv sub |> Effect.map (fun _ -> 0)
               else Pubsub.publish hub i |> Effect.bind (fun _ -> go (i + 1))
             in
             go 1))

(* Backpressure rendezvous. The previous version of this row spun on
   [Pubsub.stats] and [Eio.Fiber.yield] inside the measured region until a
   publisher was observed blocked, so it mostly measured its own busy-wait and
   moved with Eio's scheduler fairness rather than with pubsub cost. Here the
   consumer simply receives, which forces each publisher to park on a capacity-1
   hub and be woken by the receive - the wakeup path, with nothing else in the
   timed region. *)
let pubsub_backpressure n =
  let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
  Pubsub.subscribe hub (fun sub ->
      let rec publish i =
        if i = n then Effect.unit
        else Pubsub.publish hub i |> Effect.bind (fun _ -> publish (i + 1))
      in
      let rec receive remaining acc =
        if remaining = 0 then Effect.pure acc
        else Pubsub.recv sub |> Effect.bind (fun v -> receive (remaining - 1) (acc + v))
      in
      Effect.par (publish 0) (receive n 0) |> Effect.map (fun ((), sum) -> sum))

(* ------------------------------------------------------------------ *)
(* Pool                                                               *)
(* ------------------------------------------------------------------ *)

(* Warm checkout/checkin against a pool whose single resource is always idle:
   the lease fast path, with no resource construction in the loop. *)
let pool_with_resource n =
  Pool.create ~max_size:1
    ~acquire:(Effect.pure 0 : (int, [ `Pool_shutdown ]) Effect.t)
    ~release:(fun _ -> Effect.unit)
    ()
  |> Effect.bind (fun pool ->
         let rec go i acc =
           if i = 0 then Effect.pure acc
           else
             Pool.with_resource pool (fun conn -> Effect.pure (conn + one))
             |> Effect.bind (fun v -> go (i - 1) (acc + v))
         in
         go n 0)

(* Contended checkout: more concurrent borrowers than resources, so lease
   requests queue and are handed off. *)
let pool_contended ~borrowers ~per_borrower =
  Pool.create ~max_size:2
    ~acquire:(Effect.pure 0 : (int, [ `Pool_shutdown ]) Effect.t)
    ~release:(fun _ -> Effect.unit)
    ()
  |> Effect.bind (fun pool ->
         let rec borrow i =
           if i = 0 then Effect.unit
           else
             Pool.with_resource pool (fun _ -> Effect.unit)
             |> Effect.bind (fun () -> borrow (i - 1))
         in
         Effect.all (List.init borrowers (fun _ -> borrow per_borrower))
         |> Effect.map (fun (_ : unit list) -> 0))

(* ------------------------------------------------------------------ *)
(* Cancellation and interruption                                       *)
(* ------------------------------------------------------------------ *)

(* Scope exit with a child parked on [never]: measures interrupt delivery plus
   child settlement, which AGENTS.md H-W4 names as an Eta-owned invariant and
   which no benchmark in this repo covered. *)
let cancel_parked_child n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else
      Supervisor.scoped
        {
          Supervisor.run =
            (fun sup ->
              let open Supervisor.Scope in
              let* child = start sup (lift (Effect.never : (unit, [ `Never ]) Effect.t)) in
              let* () = cancel child in
              pure ());
        }
      |> Effect.bind (fun () -> go (i - 1))
  in
  go n

(* Same shape, but the child registers an interrupt handler, so the row also
   pays cleanup dispatch. The delta against [cancel_parked_child] is the cost
   of running one interrupt finalizer. *)
let cancel_parked_child_with_cleanup n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else
      Supervisor.scoped
        {
          Supervisor.run =
            (fun sup ->
              let open Supervisor.Scope in
              let* child =
                start sup
                  (lift
                     (Effect.on_interrupt
                        (fun _ -> Effect.unit)
                        (Effect.never : (unit, [ `Never ]) Effect.t)))
              in
              let* () = cancel child in
              pure ());
        }
      |> Effect.bind (fun () -> go (i - 1))
  in
  go n

(* Interruptibility fences over an already-complete effect: the static cost of
   the mode switch, with no interruption actually delivered. *)
let uninterruptible_fence n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Effect.uninterruptible (Effect.pure one)
      |> Effect.bind (fun v -> go (i - 1) (acc + v))
  in
  go n 0

(* ------------------------------------------------------------------ *)
(* Workloads                                                          *)
(* ------------------------------------------------------------------ *)

let setup_workloads () =
  [
    (* The one row that deliberately pays full process setup, because a binary
       entry point pays it. bench/runtime_overhead splits this into
       [overhead.eio.setup] and [overhead.eta.setup_pure]; this row is the
       combined figure that an [eta] consumer sees. *)
    Bench_lib.workload "eta.setup.eio_runtime_pure" (fun () ->
        Eio_main.run @@ fun stdenv ->
        Eio.Switch.run @@ fun sw ->
        let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
        run_int rt (Effect.pure one));
  ]

let core_workloads rt =
  let n = ops_per_run in
  (* Prebuilt programs isolate interpretation from construction. The paired
     [build_run] rows below include construction, so a regression in either can
     be attributed. *)
  let prebuilt_source = bind_source_nested n (Effect.pure 0) in
  let prebuilt_continuation = bind_continuation_nested n in
  let prebuilt_map = map_nested n (Effect.pure 0) in
  let row name run = Bench_lib.workload ~ops:n ("effect.core." ^ name) run in
  [
    row "bind_source_nested.prebuilt" (fun () -> run_int rt prebuilt_source);
    row "bind_source_nested.build_run" (fun () ->
        run_int rt (bind_source_nested n (Effect.pure 0)));
    row "bind_continuation_nested.prebuilt" (fun () ->
        run_int rt prebuilt_continuation);
    row "bind_continuation_nested.build_run" (fun () ->
        run_int rt (bind_continuation_nested n));
    row "map.prebuilt" (fun () -> run_int rt prebuilt_map);
    row "map.build_run" (fun () -> run_int rt (map_nested n (Effect.pure 0)));
    row "sync" (fun () -> run_int rt (sync_chain n));
    row "async_immediate.build_run" (fun () ->
        run_int rt (async_immediate_chain n));
    row "catch_success" (fun () -> run_int rt (catch_success_chain n));
    row "catch_failure" (fun () -> run_int rt (catch_failure_chain n));
    row "tap_error_failure" (fun () -> run_int rt (tap_error_chain n));
    row "uninterruptible" (fun () -> run_int rt (uninterruptible_fence n));
    (* Entering the runtime with nothing to do. Not free, and the floor for
       every row above, but reused-runtime cheap: bench/runtime_overhead calls
       the same figure [overhead.eta.pure.reused_rt]. *)
    Bench_lib.workload ~ops:n "effect.core.pure.reused_rt" (fun () ->
        Bench_lib.repeat n (fun () -> run_int rt (Effect.pure one)));
  ]

let mutable_ref_workloads rt =
  let n = ops_per_run in
  let row name run = Bench_lib.workload ~ops:n ("eta.mutable_ref." ^ name) run in
  [
    row "update" (fun () -> run_int rt (mutable_ref_update n));
    row "compare_and_set" (fun () -> run_int rt (mutable_ref_compare_and_set n));
  ]

let semaphore_workloads rt =
  let n = ops_per_run in
  [
    Bench_lib.workload ~ops:n "eta.semaphore.uncontended" (fun () ->
        run_int rt (semaphore_uncontended n));
    (* 8 fibers x 2_000 acquisitions through a single permit. *)
    Bench_lib.workload ~ops:16_000 "eta.semaphore.contended.8fibers" (fun () ->
        run_int rt (semaphore_contended ~fibers:8 ~per_fiber:2_000));
  ]

let promise_workloads rt =
  let n = 20_000 in
  [
    Bench_lib.workload ~ops:n "eta.promise.resolve_then_await" (fun () ->
        run_int rt (promise_resolve_then_await n));
    Bench_lib.workload ~ops:n "eta.promise.await_then_resolve.via_par"
      (fun () -> run_int rt (promise_await_then_resolve n));
  ]

let queue_workloads rt =
  let n = 100_000 in
  let handoff_n = 20_000 in
  [
    Bench_lib.workload ~ops:n "eta.queue.unbounded.fill_drain" (fun () ->
        run_int rt (queue_fill_drain n));
    Bench_lib.workload ~ops:n "eta.queue.unbounded.try_offer_poll" (fun () ->
        run_int rt (queue_try_offer_poll n));
    Bench_lib.workload ~ops:handoff_n "eta.queue.bounded1.rendezvous" (fun () ->
        run_int rt (queue_rendezvous handoff_n));
    Bench_lib.workload ~ops:16_000 "eta.queue.bounded4.multi_producer.4x4000"
      (fun () ->
        run_int rt (queue_multi_producer ~producers:4 ~per_producer:4_000));
  ]

let channel_workloads rt =
  let n = 20_000 in
  [
    Bench_lib.workload ~ops:n "eta.channel.capacity1.rendezvous" (fun () ->
        run_int rt (channel_rendezvous ~capacity:1 n));
    Bench_lib.workload ~ops:n "eta.channel.capacity64.rendezvous" (fun () ->
        run_int rt (channel_rendezvous ~capacity:64 n));
  ]

let pubsub_workloads rt =
  let n = 50_000 in
  [
    Bench_lib.workload ~ops:n "eta.pubsub.unbounded.publish_recv" (fun () ->
        run_int rt (pubsub_publish_recv n));
    Bench_lib.workload ~ops:(10_000 * 4)
      "eta.pubsub.unbounded.publish_recv.4subs" (fun () ->
        run_int rt (pubsub_publish_recv_fanout ~subscribers:4 10_000));
    Bench_lib.workload ~ops:n "eta.pubsub.drop_new.full" (fun () ->
        run_int rt (pubsub_drop_new_full n));
    Bench_lib.workload ~ops:20_000 "eta.pubsub.backpressure.rendezvous"
      (fun () -> run_int rt (pubsub_backpressure 20_000));
  ]

let pool_workloads rt =
  let n = 50_000 in
  [
    Bench_lib.workload ~ops:n "eta.pool.with_resource.warm" (fun () ->
        run_int rt (pool_with_resource n));
    Bench_lib.workload ~ops:16_000 "eta.pool.with_resource.contended.8x2000"
      (fun () -> run_int rt (pool_contended ~borrowers:8 ~per_borrower:2_000));
  ]

let cancel_workloads rt =
  let n = 10_000 in
  [
    Bench_lib.workload ~ops:n "eta.cancel.parked_child" (fun () ->
        run_int rt (cancel_parked_child n));
    Bench_lib.workload ~ops:n "eta.cancel.parked_child.with_cleanup" (fun () ->
        run_int rt (cancel_parked_child_with_cleanup n));
  ]

let () =
  let opts = Bench_lib.parse_args () in
  Bench_lib.run opts (setup_workloads ());
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Bench_lib.run opts (core_workloads rt);
  Bench_lib.run opts (mutable_ref_workloads rt);
  Bench_lib.run opts (semaphore_workloads rt);
  Bench_lib.run opts (promise_workloads rt);
  Bench_lib.run opts (queue_workloads rt);
  Bench_lib.run opts (channel_workloads rt);
  Bench_lib.run opts (pubsub_workloads rt);
  Bench_lib.run opts (pool_workloads rt);
  Bench_lib.run opts (cancel_workloads rt);
  Printf.eprintf "sinks=%d,%b\n%!" !int_sink !bool_sink
