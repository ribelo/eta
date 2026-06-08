open Eta
open Common

type error = [ Common.error | `Pool_shutdown_timeout ]

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let percentile sorted pct =
  match sorted with
  | [] -> 0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let sorted xs = List.sort Int.compare xs

let open_direct (factory : factory) =
  let id = atomic_incr factory.next_id in
  ignore (atomic_incr factory.opened : int);
  let live = atomic_incr factory.live in
  atomic_update_max factory.max_live live;
  {
    id;
    created_ms = now_ms ();
    closed = Atomic.make false;
    unhealthy = Atomic.make (id = 3);
    uses = Atomic.make 0;
  }

let close_direct (factory : factory) (conn : connection) =
  if Atomic.compare_and_set conn.closed false true then (
    ignore (atomic_incr factory.closed : int);
    ignore (atomic_decr factory.live : int))

let use_direct (conn : connection) =
  if Atomic.get conn.closed then
    failwith (Printf.sprintf "connection %d used after close" conn.id);
  ignore (atomic_incr conn.uses : int)

let eta_acquire factory : (connection, error) Effect.t = open_connection factory
let eta_release factory conn : (unit, error) Effect.t = close_connection factory conn

let eta_health conn : (unit, error) Effect.t =
  if health_check conn then Effect.unit
  else Effect.fail (`Connect_failed "health rejected")

let create_eta_pool ~capacity factory =
  Pool.create ~name:"eta.pool.compare" ~kind:"test" ~max_size:capacity
    ~max_idle:capacity ~acquire:(eta_acquire factory)
    ~release:(eta_release factory) ~health_check:eta_health ()

let create_eio_pool ~capacity factory =
  Eio.Pool.create ~validate:health_check
    ~dispose:(close_direct factory)
    capacity
    (fun () -> open_direct factory)

let rec eta_repeat n effect =
  if n = 0 then Effect.unit
  else effect |> Effect.bind (fun () -> eta_repeat (n - 1) effect)

let eta_timed_use latencies pool hold_ms =
  Effect.sync now_us
  |> Effect.bind (fun started ->
         Pool.with_resource pool (fun conn ->
             Effect.sync (fun () ->
                 latencies := (now_us () - started) :: !latencies;
                 use_direct conn)
             |> Effect.bind (fun () ->
                    if hold_ms <= 0 then Effect.unit
                    else Effect.delay (Duration.ms hold_ms) Effect.unit)))

let run_eta_case ~capacity ~acquirers ~iterations ~hold_ms factory latencies =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let pool =
    match Runtime.run rt (create_eta_pool ~capacity factory) with
    | Exit.Ok pool -> pool
    | Exit.Error cause ->
        Format.eprintf "eta create failure: %a\n%!"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
          cause;
        exit 1
  in
  let workload =
    Effect.for_each_par
      (list_init acquirers (fun worker ->
           let worker_hold = if worker mod 4 = 0 then hold_ms * 2 else hold_ms in
           eta_repeat iterations (eta_timed_use latencies pool worker_hold)))
      (fun effect -> effect)
    |> Effect.map (fun _ -> Pool.stats pool)
  in
  let stats =
    match Runtime.run rt workload with
    | Exit.Ok stats -> stats
    | Exit.Error cause ->
        Format.eprintf "eta workload failure: %a\n%!"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
          cause;
        exit 1
  in
  stats

let rec direct_repeat n f =
  if n > 0 then (
    f ();
    direct_repeat (n - 1) f)

let run_eio_case ~capacity ~acquirers ~iterations ~hold_ms factory latencies =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let pool = create_eio_pool ~capacity factory in
  let worker worker_id =
    let worker_hold = if worker_id mod 4 = 0 then hold_ms * 2 else hold_ms in
    direct_repeat iterations (fun () ->
        let started = now_us () in
        Eio.Pool.use pool (fun conn ->
            latencies := (now_us () - started) :: !latencies;
            use_direct conn;
            if worker_hold > 0 then
              Eio.Time.sleep clock (float_of_int worker_hold /. 1000.0)))
  in
  let promises =
    list_init acquirers (fun worker_id ->
        Eio.Fiber.fork_promise ~sw (fun () -> worker worker_id))
  in
  List.iter (fun promise -> Eio.Promise.await_exn promise) promises

let print_result ~label ~capacity ~acquirers ~iterations ~hold_ms ~elapsed_ms
    ~minor_words ~promoted_words ~major_words ~latencies factory_stats =
  let total = acquirers * iterations in
  let latencies = sorted latencies in
  let words_per = minor_words /. float_of_int total in
  let warm_reuse_hit_rate =
    1.0 -. (float_of_int factory_stats.opened /. float_of_int total)
  in
  Printf.printf
    "%s capacity=%d acquirers=%d iterations=%d hold_ms=%d total=%d elapsed_ms=%d minor_words=%.0f promoted_words=%.0f major_words=%.0f words_per_acquire_release=%.1f p50_acquire_us=%d p99_acquire_us=%d warm_reuse_hit_rate=%.4f opened=%d closed=%d live=%d max_live=%d\n%!"
    label capacity acquirers iterations hold_ms total elapsed_ms minor_words
    promoted_words major_words words_per (percentile latencies 0.50)
    (percentile latencies 0.99) warm_reuse_hit_rate factory_stats.opened
    factory_stats.closed factory_stats.live factory_stats.max_live

let measure_eta ~label ~capacity ~acquirers ~iterations ~hold_ms =
  let factory = create_factory () in
  let latencies = ref [] in
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  let stats =
    run_eta_case ~capacity ~acquirers ~iterations ~hold_ms factory latencies
  in
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let after = Gc.stat () in
  let factory_stats = factory_stats factory in
  print_result ~label ~capacity ~acquirers ~iterations ~hold_ms ~elapsed_ms
    ~minor_words:(after.minor_words -. before.minor_words)
    ~promoted_words:(after.promoted_words -. before.promoted_words)
    ~major_words:(after.major_words -. before.major_words)
    ~latencies:!latencies factory_stats;
  Printf.printf
    "%s eta_stats active=%d idle=%d waiting=%d opened=%d closed=%d health_rejected=%d cancelled_waiters=%d shutting_down=%b\n%!"
    label stats.Pool.active stats.Pool.idle stats.Pool.waiting stats.Pool.opened
    stats.Pool.closed stats.Pool.health_rejected stats.Pool.cancelled_waiters
    stats.Pool.shutting_down

let measure_eio ~label ~capacity ~acquirers ~iterations ~hold_ms =
  let factory = create_factory () in
  let latencies = ref [] in
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  run_eio_case ~capacity ~acquirers ~iterations ~hold_ms factory latencies;
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let after = Gc.stat () in
  let factory_stats = factory_stats factory in
  print_result ~label ~capacity ~acquirers ~iterations ~hold_ms ~elapsed_ms
    ~minor_words:(after.minor_words -. before.minor_words)
    ~promoted_words:(after.promoted_words -. before.promoted_words)
    ~major_words:(after.major_words -. before.major_words)
    ~latencies:!latencies factory_stats

let run_pair ~case ~capacity ~acquirers ~iterations ~hold_ms =
  measure_eta ~label:("eta_pool_" ^ case) ~capacity ~acquirers ~iterations
    ~hold_ms;
  measure_eio ~label:("eio_pool_" ^ case) ~capacity ~acquirers ~iterations
    ~hold_ms

let () =
  run_pair ~case:"sequential" ~capacity:32 ~acquirers:1 ~iterations:100_000
    ~hold_ms:0;
  run_pair ~case:"contended" ~capacity:64 ~acquirers:128 ~iterations:100
    ~hold_ms:1
