open Eta
open Common

type error = [ Common.error | `Pool_shutdown_timeout ]

let acquire factory : (connection, error) Effect.t = open_connection factory

let release factory conn : (unit, error) Effect.t =
  close_connection factory conn

let health conn : (unit, error) Effect.t =
  if health_check conn then Effect.unit
  else Effect.fail (`Connect_failed "health rejected")

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected Eta failure: %a\n%!"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause;
      exit 1

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

let create_pool ~capacity factory =
  Pool.create ~name:"eta.pool.probe" ~kind:"test" ~max_size:capacity
    ~max_idle:capacity ~idle_lifetime:(Duration.seconds 60)
    ~max_lifetime:(Duration.seconds 600)
    ~acquire:(acquire factory) ~release:(release factory) ~health_check:health ()

let timed_use latencies pool hold_ms =
  Effect.sync now_us
  |> Effect.bind (fun started ->
         Pool.with_resource pool (fun conn ->
             Effect.sync (fun () ->
                 latencies := (now_us () - started) :: !latencies)
             |> Effect.bind (fun () -> use_connection conn)
             |> Effect.bind (fun () ->
                    if hold_ms <= 0 then Effect.unit
                    else Effect.delay (Duration.ms hold_ms) Effect.unit)))

let rec repeat n effect =
  if n = 0 then Effect.unit
  else effect |> Effect.bind (fun () -> repeat (n - 1) effect)

let sorted xs = List.sort Int.compare xs

let run_case ~label ~capacity ~acquirers ~iterations ~hold_ms =
  let total = acquirers * iterations in
  let factory = create_factory () in
  let latencies = ref [] in
  let program =
    create_pool ~capacity factory
    |> Effect.bind (fun pool ->
           Effect.for_each_par
             (list_init acquirers (fun worker ->
                  let worker_hold =
                    if worker mod 4 = 0 then hold_ms * 2 else hold_ms
                  in
                  repeat iterations (timed_use latencies pool worker_hold)))
             (fun effect -> effect)
           |> Effect.bind (fun _ -> Pool.shutdown pool)
           |> Effect.map (fun () -> Pool.stats pool))
  in
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  let stats = run_effect program in
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let after = Gc.stat () in
  let factory_stats = factory_stats factory in
  let latencies = sorted !latencies in
  let words = after.minor_words -. before.minor_words in
  let words_per = words /. float_of_int total in
  let warm_reuse_hit_rate =
    1.0 -. (float_of_int factory_stats.opened /. float_of_int total)
  in
  Printf.printf
    "%s capacity=%d acquirers=%d total=%d elapsed_ms=%d minor_words=%.0f words_per_acquire_release=%.1f p50_acquire_us=%d p99_acquire_us=%d warm_reuse_hit_rate=%.4f opened=%d closed=%d active=%d idle=%d waiting=%d health_rejected=%d cancelled_waiters=%d max_live=%d\n%!"
    label capacity acquirers total elapsed_ms words words_per
    (percentile latencies 0.50) (percentile latencies 0.99)
    warm_reuse_hit_rate factory_stats.opened factory_stats.closed stats.Pool.active
    stats.Pool.idle stats.Pool.waiting stats.Pool.health_rejected
    stats.Pool.cancelled_waiters factory_stats.max_live

let () =
  run_case ~label:"eta_pool_sequential" ~capacity:32 ~acquirers:1
    ~iterations:10_000 ~hold_ms:0;
  run_case ~label:"eta_pool_contended" ~capacity:64 ~acquirers:128
    ~iterations:100 ~hold_ms:1
