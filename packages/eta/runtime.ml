module E = Effect
module P_atomic = Portable.Atomic

external direct : ('a, 'err) E.t -> ('a, 'err) Effect_direct.t = "%identity"
external island_pool_of_public : E.Island.pool -> Island_runtime.pool
  = "%identity"

external blocking_pool_of_public : E.Blocking.Pool.t -> Blocking_runtime.t
  = "%identity"

type 'err t = 'err Runtime_core.t

let create ~sw ~clock ?sleep ?tracer ?sampler ?auto_instrument ?logger ?meter
    ?random ?island_pool ?blocking_pool ?capture_backtrace () =
  let island_pool = Option.map island_pool_of_public island_pool in
  let blocking_pool = Option.map blocking_pool_of_public blocking_pool in
  Runtime_core.create ~sw ~clock ?sleep ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace ()

let run ?island_pool ?blocking_pool t eff =
  let island_pool = Option.map island_pool_of_public island_pool in
  let blocking_pool = Option.map blocking_pool_of_public blocking_pool in
  Effect_direct.run ?island_pool ?blocking_pool t (direct eff)

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
