module P_atomic = Portable.Atomic

external island_pool_of_public : Effect.Island.pool -> Island_runtime.pool
  = "%identity"

external blocking_pool_of_public : Effect.Blocking.Pool.t -> Blocking_runtime.t
  = "%identity"

let blocking_runner_of_public runner =
  {
    Blocking_runtime.run_in_systhread =
      runner.Effect.Blocking.Pool.run_in_systhread;
  }

type 'err t = 'err Runtime_core.t

let create ~sw ~clock ?sleep ?tracer ?sampler ?auto_instrument ?logger ?meter
    ?random ?island_pool ?blocking_pool ?blocking_runner ?capture_backtrace () =
  let island_pool = Option.map island_pool_of_public island_pool in
  let blocking_pool = Option.map blocking_pool_of_public blocking_pool in
  let blocking_runner = Option.map blocking_runner_of_public blocking_runner in
  Runtime_core.create ~sw ~clock ?sleep ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?island_pool ?blocking_pool ?blocking_runner
    ?capture_backtrace ()

let run ?island_pool ?blocking_pool runtime eff =
  let runtime =
    match (island_pool, blocking_pool) with
    | None, None -> runtime
    | _ ->
        {
          runtime with
          Runtime_core.island_pool =
            (match island_pool with
             | Some pool -> Some (island_pool_of_public pool)
             | None -> runtime.Runtime_core.island_pool);
          Runtime_core.blocking_pool =
            (match blocking_pool with
             | Some pool -> Some (blocking_pool_of_public pool)
             | None -> runtime.Runtime_core.blocking_pool);
        }
  in
  Effect.run runtime eff

let run_exn t eff =
  match run t eff with
  | Exit.Ok value -> value
  | Exit.Error (Cause.Die { exn; backtrace = Some backtrace; _ }) ->
      Printexc.raise_with_backtrace exn backtrace
  | Exit.Error (Cause.Die { exn; backtrace = None; _ }) -> raise exn
  | Exit.Error _ -> failwith "Eta.Runtime.run_exn"

let drain t =
  while P_atomic.get t.Runtime_core.active > 0 do
    Eio.Fiber.yield ()
  done
