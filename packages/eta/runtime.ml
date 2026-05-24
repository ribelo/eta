module E = Effect
module EV = Effect_ast
module P_atomic = Portable.Atomic
module RObs = Runtime_observability

external view : ('a, 'err) E.t -> ('a, 'err) EV.t = "%identity"
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
  if Blocking_runtime.in_worker () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside an Effect.Blocking worker callback";
  let t =
    match (island_pool, blocking_pool) with
    | None, None -> t
    | _ ->
        let island_pool = Option.map island_pool_of_public island_pool in
        let blocking_pool = Option.map blocking_pool_of_public blocking_pool in
        {
          t with
          Runtime_core.island_pool =
            (match island_pool with
            | Some _ as pool -> pool
            | None -> t.Runtime_core.island_pool);
          Runtime_core.blocking_pool =
            (match blocking_pool with
            | Some _ as pool -> pool
            | None -> t.Runtime_core.blocking_pool);
        }
  in
  (* Terminal effects do not need switch/finalizer setup. *)
  match view eff with
  | EV.Pure v -> Exit.Ok v
  | EV.Fail e -> Exit.Error (Cause.Fail e)
  | _ ->
      t.tracer#with_fiber_context @@ fun () ->
      Eio.Switch.run @@ fun sw ->
      let finalizers = ref [] in
      try
        Exit.Ok
          (RObs.with_blocking_event_emit
             (Runtime_core.emit_blocking_event t)
             (fun () ->
               Runtime_core.with_finalizers ~runtime:t
                 ~fail_key:t.default_fail_key finalizers (fun () ->
                   Runtime_interpret.interpret ~runtime:t
                     ~error_renderer:RObs.default_error_renderer
                     ~fail_key:t.Runtime_core.default_fail_key ~sw ~finalizers
                     eff)))
      with exn ->
        Exit.Error
          (Runtime_core.cause_of_exn_runtime t t.Runtime_core.default_fail_key
             exn)

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
