type 'err t = 'err Runtime_core.t

let create_with_contract contract ?sleep ?now_ms ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?services ?capture_backtrace () =
  Runtime_core.create_with_contract ~contract ?sleep ?now_ms ?tracer ?sampler
    ?auto_instrument ?logger ?meter ?random ?services ?capture_backtrace ()

let create_with_runtime backend ?sleep ?now_ms ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?services ?capture_backtrace () =
  create_with_contract (Runtime_contract.of_runtime backend) ?sleep ?now_ms
    ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?services
    ?capture_backtrace ()

let run_effect (runtime : 'err Runtime_core.t) (eff : ('a, 'err) Effect.t) :
    ('a, 'err) Exit.t =
  Sync_lock.check_no_runtime_operation ();
  if runtime.Runtime_core.contract.Runtime_contract.in_worker_context () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside a runtime worker callback";
  runtime.Runtime_core.contract.Runtime_contract.with_fiber_identity @@ fun () ->
  let _, tracer = Runtime_core.current_tracer runtime in
  tracer#with_task_context runtime.Runtime_core.contract
  @@ fun () ->
  let finalizers = ref [] in
  let frame =
    {
      Effect_core.runtime = Runtime_erasure.erase_runtime_error runtime;
      error_renderer = Effect_core.default_renderer;
      fail_key = runtime.Runtime_core.default_fail_key;
      sw = runtime.Runtime_core.outer_scope;
      interrupt_of_cancel = Effect_core.default_interrupt_of_cancel;
      finalizers;
    }
  in
  try
    Exit.Ok
      (Runtime_core.with_finalizers ~runtime
         ~fail_key:runtime.Runtime_core.default_fail_key
         ~error_renderer:frame.error_renderer finalizers (fun () ->
           Effect_core.run_to_value frame
             (Runtime_erasure.effect_of_public eff)))
  with
  | exn when Runtime_core.is_cancellation runtime.Runtime_core.contract exn ->
      raise exn
  | exn ->
      Exit.Error
        (Runtime_core.cause_of_exn_runtime runtime
           runtime.Runtime_core.default_fail_key exn)

let run runtime eff = run_effect runtime eff

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

let metrics_enabled (t : 'err Runtime_core.t) = t.Runtime_core.metrics_enabled
let tracing_enabled (t : 'err Runtime_core.t) = t.Runtime_core.tracing_enabled

module Make (R : Runtime_contract.RUNTIME) = struct
  let backend = (module R : Runtime_contract.RUNTIME)

  let create ?sleep ?now_ms ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
      ?services ?capture_backtrace () =
    create_with_runtime backend ?sleep ?now_ms ?tracer ?sampler
      ?auto_instrument ?logger ?meter ?random ?services ?capture_backtrace ()

  let run = run
  let run_exn = run_exn
  let drain = drain
end
