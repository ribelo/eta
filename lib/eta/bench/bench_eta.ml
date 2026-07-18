open Eta

let run_effect_exit program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  Runtime.run rt program

let run_effect program = ignore (run_effect_exit program : (_, _) Exit.t)

let run_effect_ok program =
  match run_effect_exit program with
  | Exit.Ok _ -> ()
  | Exit.Error cause ->
      Format.eprintf "benchmark effect failed: %a@."
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<typed>"))
        cause;
      failwith "benchmark effect failed"

let rec bind_chain n acc =
  if n = 0 then acc
  else bind_chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)

let bind_left n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else Effect.bind (fun x -> Effect.pure (x + 1)) (go (i - 1))
  in
  go n

let rec map_chain n acc =
  if n = 0 then acc else map_chain (n - 1) (Effect.map (( + ) 1) acc)

let sync_chain n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else
      Effect.bind
        (fun _ -> go (i - 1))
        (Effect.sync (fun () -> i))
  in
  go n

let rec queue_send_loop q i n =
  if i = n then Effect.unit
  else Queue.send q i |> Effect.bind (fun () -> queue_send_loop q (i + 1) n)

let rec queue_recv_loop q remaining acc =
  if remaining = 0 then Effect.pure acc
  else
    Queue.take q
    |> Effect.bind (fun value -> queue_recv_loop q (remaining - 1) (acc + value))

let queue_send_recv n =
  let q = Queue.unbounded () in
  queue_send_loop q 0 n
  |> Effect.bind (fun () -> queue_recv_loop q n 0)
  |> Effect.map ignore
  |> run_effect

let rec queue_try_send_loop q i n =
  if i = n then Effect.unit
  else
    Queue.try_offer q i
    |> Effect.bind (function
         | `Sent -> queue_try_send_loop q (i + 1) n
         | `Dropped | `Full | `Closed | `Closed_with_error _ ->
             Effect.sync (fun () -> failwith "queue try_send failed during bench"))

let rec queue_try_recv_loop q remaining acc =
  if remaining = 0 then Effect.pure acc
  else
    Queue.poll q
    |> Effect.bind (function
         | `Item value -> queue_try_recv_loop q (remaining - 1) (acc + value)
         | `Empty | `Closed | `Closed_with_error _ ->
             Effect.sync (fun () -> failwith "queue recv missed item during bench"))

let queue_try_send_recv n =
  let q = Queue.unbounded () in
  queue_try_send_loop q 0 n
  |> Effect.bind (fun () -> queue_try_recv_loop q n 0)
  |> Effect.map ignore
  |> run_effect

let queue_handoff n =
  let q = Queue.unbounded () in
  Effect.par (queue_send_loop q 0 n) (queue_recv_loop q n 0)
  |> Effect.map ignore
  |> run_effect

let rec pubsub_publish_recv_loop hub sub i n =
  if i = n then Effect.unit
  else
    Pubsub.publish hub i
    |> Effect.bind (fun _ ->
           Pubsub.recv sub
           |> Effect.bind (fun _ -> pubsub_publish_recv_loop hub sub (i + 1) n))

let pubsub_publish_recv n =
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  Pubsub.subscribe hub (fun sub -> pubsub_publish_recv_loop hub sub 0 n)
  |> run_effect_ok

let rec pubsub_publish_recv4_loop hub a b c d i n =
  if i = n then Effect.unit
  else
    Pubsub.publish hub i
    |> Effect.bind (fun _ ->
           Pubsub.recv a
           |> Effect.bind (fun _ ->
                  Pubsub.recv b
                  |> Effect.bind (fun _ ->
                         Pubsub.recv c
                         |> Effect.bind (fun _ ->
                                Pubsub.recv d
                                |> Effect.bind (fun _ ->
                                       pubsub_publish_recv4_loop hub a b c d
                                         (i + 1) n)))))

let pubsub_publish_recv4 n =
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  Pubsub.subscribe hub (fun a ->
      Pubsub.subscribe hub (fun b ->
          Pubsub.subscribe hub (fun c ->
              Pubsub.subscribe hub (fun d ->
                  pubsub_publish_recv4_loop hub a b c d 0 n))))
  |> run_effect_ok

let rec pubsub_publish_only_loop hub i n =
  if i = n then Effect.unit
  else
    Pubsub.publish hub i
    |> Effect.bind (fun _ -> pubsub_publish_only_loop hub (i + 1) n)

let pubsub_drop_new_full n =
  let hub = Pubsub.create ~overflow:(Pubsub.Drop_new { capacity = 1 }) () in
  Pubsub.subscribe hub (fun a ->
      Pubsub.subscribe hub (fun b ->
          Pubsub.publish hub 0
          |> Effect.bind (fun _ ->
                 pubsub_publish_only_loop hub 1 n
                 |> Effect.bind (fun () ->
                        Pubsub.recv a
                        |> Effect.bind (fun _ ->
                               Pubsub.recv b |> Effect.map ignore)))))
  |> run_effect_ok

let rec pubsub_wait_for_blocked_publisher hub =
  let stats = Pubsub.stats hub in
  if stats.waiting_publishers > 0 then Effect.unit
  else
    Effect.sync Eio.Fiber.yield
    |> Effect.bind (fun () -> pubsub_wait_for_blocked_publisher hub)

let rec pubsub_backpressure_waiter_loop hub sub i n =
  if i = n then Pubsub.recv sub |> Effect.map ignore
  else
    Effect.par
      (Pubsub.publish hub i)
      (pubsub_wait_for_blocked_publisher hub
      |> Effect.bind (fun () -> Pubsub.recv sub))
    |> Effect.bind (fun _ -> pubsub_backpressure_waiter_loop hub sub (i + 1) n)

let pubsub_backpressure_waiter n =
  let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 1 }) () in
  Pubsub.subscribe hub (fun sub ->
      Pubsub.publish hub 0
      |> Effect.bind (fun _ -> pubsub_backpressure_waiter_loop hub sub 1 n))
  |> run_effect_ok

let workloads =
  let core name run =
    { Bench_lib.name = "effect.core." ^ name; run; samples = None }
  in
  let queue name run =
    { Bench_lib.name = "eta.queue." ^ name; run; samples = None }
  in
  let pubsub name run =
    { Bench_lib.name = "eta.pubsub." ^ name; run; samples = None }
  in
  [
    core "pure_run" (fun () -> run_effect (Effect.pure 0));
    core "bind_right.1k" (fun () -> run_effect (bind_chain 1_000 (Effect.pure 0)));
    core "bind_right.10k" (fun () -> run_effect (bind_chain 10_000 (Effect.pure 0)));
    core "bind_right.100k" (fun () -> run_effect (bind_chain 100_000 (Effect.pure 0)));
    core "bind_left.1k" (fun () -> run_effect (bind_left 1_000));
    core "bind_left.10k" (fun () -> run_effect (bind_left 10_000));
    core "bind_left.100k" (fun () -> run_effect (bind_left 100_000));
    core "map_chain.1k" (fun () -> run_effect (map_chain 1_000 (Effect.pure 0)));
    core "map_chain.10k" (fun () -> run_effect (map_chain 10_000 (Effect.pure 0)));
    core "map_chain.100k" (fun () -> run_effect (map_chain 100_000 (Effect.pure 0)));
    core "sync.1" (fun () -> run_effect (sync_chain 1));
    core "sync.100" (fun () -> run_effect (sync_chain 100));
    core "sync.10000" (fun () -> run_effect (sync_chain 10_000));
    core "catch_success" (fun () ->
        run_effect
          (Effect.bind_error (fun (`Boom : [ `Boom ]) -> Effect.pure 0) (Effect.pure 1)));
    core "catch_failure" (fun () ->
        run_effect
          (Effect.bind_error (fun (`Boom : [ `Boom ]) -> Effect.pure 1) (Effect.fail `Boom)));
    core "tap_error_failure" (fun () ->
        run_effect
          (Effect.tap_error (fun (`Boom : [ `Boom ]) -> Effect.unit)
             (Effect.fail `Boom)));
    core "fail_then_catch" (fun () ->
        run_effect
          (Effect.fail `Boom
          |> Effect.bind_error (fun (`Boom : [ `Boom ]) -> Effect.pure 1)));
    core "runtime_create_run_shutdown" (fun () -> run_effect (Effect.pure 0));
    queue "send_recv.10k" (fun () -> queue_send_recv 10_000);
    queue "send_recv.100k" (fun () -> queue_send_recv 100_000);
    queue "try_send_try_recv.100k" (fun () -> queue_try_send_recv 100_000);
    queue "handoff.10k" (fun () -> queue_handoff 10_000);
    pubsub "unbounded.publish_recv.10k" (fun () -> pubsub_publish_recv 10_000);
    pubsub "unbounded.publish_recv.100k" (fun () -> pubsub_publish_recv 100_000);
    pubsub "unbounded.publish_recv_4subs.10k" (fun () ->
        pubsub_publish_recv4 10_000);
    pubsub "drop_new.full.100k" (fun () -> pubsub_drop_new_full 100_000);
    pubsub "backpressure.waiter.1k" (fun () -> pubsub_backpressure_waiter 1_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
