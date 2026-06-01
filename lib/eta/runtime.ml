external island_pool_of_public : Effect.Island.pool -> Island_runtime.pool
  = "%identity"

external blocking_pool_of_public : Effect.Blocking.Pool.t -> Blocking_runtime.t
  = "%identity"

(* [Effect.t] is abstract to users. Runtime is the package-local interpreter,
   so it may re-enter the internal representation without exporting that
   representation through [Effect.mli]. *)
external effect_of_public : ('a, 'err) Effect.t -> ('a, 'err) Effect_core.t =
  "%identity"

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

let run_effect (runtime : 'err Runtime_core.t) (effect : ('a, 'err) Effect.t) :
    ('a, 'err) Exit.t =
  if Blocking_runtime.in_worker () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside an Effect.Blocking worker callback";
  runtime.Runtime_core.tracer#with_fiber_context @@ fun () ->
  let finalizers = ref [] in
  let frame =
    {
      (* [Effect_core.frame] stores the runtime with an erased failure carrier
         because one run can cross effects with different typed-failure
         parameters. Runtime_core keeps failures keyed separately, so this cast
         only erases the phantom carrier on the runtime value. *)
      Effect_core.runtime = (Obj.magic runtime : Obj.t Runtime_core.t);
      error_renderer = Effect_core.default_renderer;
      fail_key = runtime.Runtime_core.default_fail_key;
      sw = runtime.Runtime_core.outer_sw;
      finalizers;
    }
  in
  try
    let body () =
      Runtime_core.with_finalizers ~runtime
        ~fail_key:runtime.Runtime_core.default_fail_key
        ~error_renderer:frame.error_renderer finalizers (fun () ->
          Effect_core.run_to_value frame (effect_of_public effect))
    in
    Exit.Ok
      (if runtime.Runtime_core.tracing_enabled
       || runtime.Runtime_core.metrics_enabled
      then
        Runtime_observability.with_blocking_event_emit
          (Runtime_core.emit_blocking_event runtime)
          body
      else body ())
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Exit.Error
        (Runtime_core.cause_of_exn_runtime runtime
           runtime.Runtime_core.default_fail_key exn)

let run_host_eio host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
    ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace effect =
  with_host_eio host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger ?meter
    ?random ?island_pool ?blocking_pool ?capture_backtrace (fun runtime ->
      run_effect runtime effect)

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
  run_effect runtime eff

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
