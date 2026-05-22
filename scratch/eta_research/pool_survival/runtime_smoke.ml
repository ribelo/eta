open Eta
open Common

module type CANDIDATE = sig
  type t

  val label : string
  val create : ?config:pool_config -> factory -> (t, error) Effect.t

  val with_connection :
    t -> (connection -> ('a, error) Effect.t) -> ('a, error) Effect.t

  val shutdown : ?deadline:Duration.t -> t -> (unit, error) Effect.t

  val stats : t -> pool_stats
end

module Branch_a : CANDIDATE = struct
  type t = Branch_a_internal_pool.t

  let label = "branch_a_internal_pool"
  let create = Branch_a_internal_pool.create
  let with_connection = Branch_a_internal_pool.with_connection
  let shutdown = Branch_a_internal_pool.shutdown
  let stats = Branch_a_internal_pool.stats
end

module Branch_b : CANDIDATE = struct
  type t = connection Branch_b_eta_pool.t

  let label = "branch_b_eta_pool"
  let create = Branch_b_eta_pool.create_for_fake
  let with_connection = Branch_b_eta_pool.with_resource
  let shutdown = Branch_b_eta_pool.shutdown
  let stats = Branch_b_eta_pool.stats
end

let outcome_counts outcomes =
  List.fold_left
    (fun (used, cancelled, shutdown_done, pool_shutdowns, other_errors) -> function
      | Ok (`Used _) -> (used + 1, cancelled, shutdown_done, pool_shutdowns, other_errors)
      | Ok `Cancelled -> (used, cancelled + 1, shutdown_done, pool_shutdowns, other_errors)
      | Ok `Shutdown_done ->
          (used, cancelled, shutdown_done + 1, pool_shutdowns, other_errors)
      | Ok `Unexpected_cancel_success ->
          (used, cancelled, shutdown_done, pool_shutdowns, other_errors + 1)
      | Error (Cause.Fail `Pool_shutdown) ->
          (used, cancelled, shutdown_done, pool_shutdowns + 1, other_errors)
      | Error _ -> (used, cancelled, shutdown_done, pool_shutdowns, other_errors + 1))
    (0, 0, 0, 0, 0) outcomes

let workload (module P : CANDIDATE) =
  let factory = create_factory () in
  P.create factory
  |> Effect.bind (fun pool ->
         let use_once i hold_ms =
           P.with_connection pool (fun conn ->
               use_connection conn
               |> Effect.bind (fun () ->
                      Effect.delay (Duration.ms hold_ms) Effect.unit)
               |> Effect.map (fun () -> `Used i))
         in
         let warmup = list_init 8 (fun i -> use_once i 24) in
         let mixed =
           list_init 92 (fun i ->
               let hold_ms = if i mod 2 = 0 then 1 else 6 in
               use_once (i + 8) hold_ms)
         in
         let shutdown_midflight =
           Effect.delay (Duration.ms 8)
             (P.shutdown ~deadline:(Duration.ms 250) pool
             |> Effect.map (fun () -> `Shutdown_done))
         in
         Effect.all_settled (warmup @ mixed @ [ shutdown_midflight ])
         |> Effect.bind (fun outcomes ->
                Effect.sync (P.label ^ ".assert_workload") (fun () ->
                    let stats = P.stats pool in
                    let factory_stats = factory_stats factory in
                    let used, cancelled, shutdown_done, pool_shutdowns, other_errors =
                      outcome_counts outcomes
                    in
                    check (P.label ^ " max_live <= 8") (factory_stats.max_live <= 8);
                    check (P.label ^ " max_observed_in_use <= 8")
                      (stats.max_observed_in_use <= 8);
                    check (P.label ^ " unhealthy connection rejected")
                      (stats.health_rejected >= 1);
                    check (P.label ^ " shutdown completed") (shutdown_done = 1);
                    check (P.label ^ " shutdown rejected waiters")
                      (pool_shutdowns >= 1);
                    check (P.label ^ " no unexpected errors") (other_errors = 0);
                    check (P.label ^ " some requests used pool") (used > 0);
                    check (P.label ^ " drained total") (stats.total = 0);
                    check (P.label ^ " drained in_use") (stats.in_use = 0);
                    check (P.label ^ " drained idle") (stats.idle = 0);
                    check (P.label ^ " no live fake connections")
                      (factory_stats.live = 0);
                    check (P.label ^ " closed all opened")
                      (factory_stats.opened = factory_stats.closed);
                    check (P.label ^ " emitted trace events") (stats.events > 0);
                    Printf.printf
                      "%s workload PASS used=%d cancelled=%d shutdown_done=%d pool_shutdowns=%d %s %s\n%!"
                      P.label used cancelled shutdown_done pool_shutdowns
                      (pp_pool_stats stats)
                      (pp_factory_stats factory_stats))))

let cancel_waiter (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 1;
      max_idle = 1;
      idle_lifetime = Some (Duration.ms 50);
      max_lifetime = Some (Duration.seconds 1);
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         P.with_connection pool (fun holder_conn ->
             use_connection holder_conn
             |> Effect.bind (fun () ->
                    let holder_delay =
                      Effect.delay (Duration.ms 20) Effect.unit
                      |> Effect.map (fun () -> `Holder_done)
                    in
                    let waiter =
                      Effect.delay (Duration.ms 1)
                        (P.with_connection pool (fun conn ->
                             use_connection conn
                             |> Effect.map (fun () -> `Waiter_acquired))
                        |> Effect.timeout (Duration.ms 2)
                        |> Effect.catch (function
                             | `Timeout -> Effect.pure `Cancelled
                             | #error as err -> Effect.fail err))
                    in
                    Effect.all_settled [ holder_delay; waiter ]))
         |> Effect.bind (fun outcomes ->
                Effect.sync (P.label ^ ".assert_cancel_waiter") (fun () ->
                    let describe = function
                      | Ok `Holder_done -> "ok_holder"
                      | Ok `Cancelled -> "ok_cancelled"
                      | Ok `Waiter_acquired -> "ok_waiter_acquired"
                      | Ok _ -> "ok_other"
                      | Error (Cause.Fail `Timeout) -> "error_timeout"
                      | Error (Cause.Fail `Pool_shutdown) -> "error_pool_shutdown"
                      | Error (Cause.Interrupt _) -> "error_interrupt"
                      | Error cause ->
                          Format.asprintf "error_other:%a"
                            (Cause.pp (fun fmt _ ->
                                 Format.pp_print_string fmt "<error>"))
                            cause
                    in
                    Printf.printf "%s cancel_waiter outcomes=%s\n%!" P.label
                      (String.concat "," (List.map describe outcomes));
                    let cancelled =
                      List.exists
                        (function Ok `Cancelled -> true | _ -> false)
                        outcomes
                    in
                    let unexpected =
                      List.exists
                        (function Ok `Waiter_acquired -> true | _ -> false)
                        outcomes
                    in
                    let stats = P.stats pool in
                    let verdict =
                      if cancelled && (not unexpected) && stats.waiting = 0
                         && stats.cancelled_waiters >= 1
                      then "PASS"
                      else "FAIL"
                    in
                    Printf.printf "%s cancel_waiter %s %s\n%!" P.label
                      verdict (pp_pool_stats stats))
                |> Effect.bind (fun () ->
                       P.shutdown ~deadline:(Duration.ms 100) pool)))

let idle_eviction (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 2;
      max_idle = 2;
      idle_lifetime = Some (Duration.ms 2);
      max_lifetime = Some (Duration.seconds 1);
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         P.with_connection pool (fun conn ->
             use_connection conn |> Effect.map (fun () -> conn.id))
         |> Effect.bind (fun first_id ->
                Effect.delay (Duration.ms 8) Effect.unit
                |> Effect.bind (fun () ->
                       Effect.sync (P.label ^ ".assert_idle_evicted") (fun () ->
                           let stats = P.stats pool in
                           let factory_stats = factory_stats factory in
                           check (P.label ^ " idle evicted") (stats.idle = 0);
                           check (P.label ^ " first connection closed")
                             (factory_stats.closed >= 1);
                           Printf.printf
                             "%s idle_evict PASS first=%d %s %s\n%!" P.label
                             first_id (pp_pool_stats stats)
                             (pp_factory_stats factory_stats))))
                 |> Effect.bind (fun () ->
                        P.with_connection pool (fun conn ->
                            Effect.delay (Duration.ms 8) Effect.unit
                            |> Effect.bind (fun () ->
                                   Effect.sync
                                     (P.label ^ ".assert_in_use_alive")
                                     (fun () ->
                                       check
                                         (P.label
                                        ^ " in-use connection kept alive")
                                         (not (Atomic.get conn.closed))))))
                 |> Effect.bind (fun () ->
                        P.shutdown ~deadline:(Duration.ms 100) pool))

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

let () =
  run_effect
    (Effect.concat
       [
         cancel_waiter (module Branch_a);
         workload (module Branch_a);
         idle_eviction (module Branch_a);
         cancel_waiter (module Branch_b);
         workload (module Branch_b);
         idle_eviction (module Branch_b);
       ]);
  print_endline "pool_survival runtime smoke passed"
