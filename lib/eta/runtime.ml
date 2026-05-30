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

let host_sleep host clock duration =
  let module Time = (val Host_eio.time host : Host_eio.TIME) in
  let seconds = Duration.to_seconds_float duration in
  if seconds > 0.0 then Time.sleep clock seconds

let host_now_ms host clock =
  let module Time = (val Host_eio.time host : Host_eio.TIME) in
  fun () -> int_of_float (Time.now clock *. 1000.0)

let host_blocking_runner host =
  let module Unix = (val Host_eio.unix host : Host_eio.UNIX) in
  {
    Effect.Blocking.Pool.run_in_systhread =
      (fun ~label f -> Unix.run_in_systhread ~label f);
  }

let with_host_eio host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
    ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace f =
  let sleep = host_sleep host clock in
  let blocking_runner = host_blocking_runner host in
  let runtime =
    {
      (create ~sw ~clock ~sleep ?tracer ?sampler ?auto_instrument ?logger
         ?meter ?random ?island_pool ?blocking_pool ~blocking_runner
         ?capture_backtrace ())
      with
      Runtime_core.host_eio = Some host;
      now_ms = host_now_ms host clock;
    }
  in
  f runtime

let run_host_eio host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
    ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace effect =
  with_host_eio host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger ?meter
    ?random ?island_pool ?blocking_pool ?capture_backtrace (fun runtime ->
      Effect.run runtime effect)

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
  let pp_typed_failure fmt err =
    let raw = Obj.repr err in
    if Obj.is_int raw then Format.pp_print_int fmt (Obj.obj raw : int)
    else
      match Obj.tag raw with
      | tag when tag = Obj.string_tag ->
          Format.fprintf fmt "%S" (Obj.obj raw : string)
      | tag when tag = Obj.double_tag ->
          Format.pp_print_float fmt (Obj.obj raw : float)
      | _ -> Format.pp_print_string fmt "<typed failure>"
  in
  match run t eff with
  | Exit.Ok value -> value
  | Exit.Error (Cause.Die { exn; backtrace = Some backtrace; _ }) ->
      Printexc.raise_with_backtrace exn backtrace
  | Exit.Error (Cause.Die { exn; backtrace = None; _ }) -> raise exn
  | Exit.Error cause ->
      failwith
        (Format.asprintf "Eta.Runtime.run_exn: %a"
           (Cause.pp pp_typed_failure)
           cause)

let drain t = Runtime_core.wait_active_zero t
