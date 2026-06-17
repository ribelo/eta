module Expert = Eta.Effect.Expert
module Runtime_contract = Eta.Runtime_contract

let string_of_outcome = function
  | Blocking_runtime.Blocking_ok -> "ok"
  | Blocking_runtime.Blocking_error msg -> "error:" ^ msg
  | Blocking_runtime.Blocking_cancelled -> "cancelled"
  | Blocking_runtime.Blocking_rejected -> "rejected"
  | Blocking_runtime.Blocking_shutdown_rejected -> "shutdown"
  | Blocking_runtime.Blocking_detached -> "detached"

let emit_blocking_event context (event : Blocking_runtime.event) =
  let attrs =
    [
      ("eta.blocking.pool", event.pool);
      ("eta.blocking.name", event.name);
      ("eta.blocking.outcome", string_of_outcome event.outcome);
      ("eta.blocking.queue_wait_ms", string_of_int event.queue_wait_ms);
      ("eta.blocking.run_ms", string_of_int event.run_ms);
    ]
  in
  Expert.emit_trace_event context ~name:"eta.blocking" ~attrs;
  Expert.record_metric context ~name:"eta.blocking.queue_wait_ms"
    ~description:"Time spent admitted but waiting for a blocking worker"
    ~unit_:"ms" ~kind:Eta.Capabilities.Gauge ~attrs
    ~value:(Eta.Capabilities.Int event.queue_wait_ms);
  Expert.record_metric context ~name:"eta.blocking.run_ms"
    ~description:"Time spent running a blocking callback" ~unit_:"ms"
    ~kind:Eta.Capabilities.Gauge ~attrs
    ~value:(Eta.Capabilities.Int event.run_ms)

module Pool = struct
  include Blocking_runtime.Pool

  let shutdown pool =
    Expert.make @@ fun context ->
    try
      Blocking_runtime.shutdown
        ~contract:(Expert.contract context)
        ~emit:(emit_blocking_event context)
        pool;
      Eta.Exit.Ok ()
    with exn -> Expert.exit_of_exn context exn
end

type defaults = {
  pool : Pool.t Lazy.t;
  runner : Pool.runner option;
}

let defaults_key : defaults Runtime_contract.service_key =
  Runtime_contract.create_service_key ()

let defaults_local : defaults Runtime_contract.local =
  Runtime_contract.create_local ()

let make_default_pool () =
  Pool.create ~name:"runtime.default" Blocking_runtime.default_config

let make_defaults ?pool ?runner () =
  let pool =
    match pool with
    | Some pool -> Lazy.from_val pool
    | None -> lazy (make_default_pool ())
  in
  { pool; runner }

let runtime_service ?pool ?runner () =
  Runtime_contract.Service (defaults_key, make_defaults ?pool ?runner ())

let fallback_defaults = lazy (make_defaults ())

let current_defaults context =
  let contract = Expert.contract context in
  match contract.Runtime_contract.local_get defaults_local with
  | Some defaults -> defaults
  | None -> (
      match Expert.runtime_service context defaults_key with
      | Some defaults -> defaults
      | None -> Lazy.force fallback_defaults)

let with_defaults ?pool ?runner eff =
  Expert.make @@ fun context ->
  let parent = current_defaults context in
  let pool =
    match pool with
    | Some pool -> Lazy.from_val pool
    | None -> parent.pool
  in
  let runner =
    match runner with
    | Some _ as runner -> runner
    | None -> parent.runner
  in
  let defaults = { pool; runner } in
  let contract = Expert.contract context in
  contract.Runtime_contract.local_with_binding defaults_local defaults
    (fun () -> Expert.eval context eff)

let check_not_worker operation =
  if Runtime_contract.in_registered_worker_context () then
    invalid_arg
      (operation
     ^ " must not be called from inside an Eta_blocking worker callback")

let pool_and_runner context override =
  let defaults = current_defaults context in
  let pool =
    match override with
    | Some pool -> pool
    | None -> Lazy.force defaults.pool
  in
  (pool, defaults.runner)

let run ?pool ?(name = "blocking") ?on_cancel f =
  check_not_worker "Eta_blocking.run";
  Expert.make ~names:[ name ] @@ fun context ->
  let contract = Expert.contract context in
  let pool, runner = pool_and_runner context pool in
  let body () =
    Blocking_runtime.submit ~scope:(Expert.outer_scope context) ~contract
      ~runner ~emit:(emit_blocking_event context) pool name ?on_cancel f
  in
  try
    Eta.Exit.Ok
      (if Expert.auto_instrument context then
         Expert.instrument_leaf context ~name body
       else body ())
  with exn -> Expert.exit_of_exn context exn

let run_result ?pool ?name ?on_cancel f =
  run ?pool ?name ?on_cancel f |> Eta.Effect.flatten_result

let result = run_result

let run_result_timeout ?pool ?name ?on_cancel ~timeout ~on_timeout f =
  let name = Option.value ~default:"blocking" name in
  let cancel_hook_called = Atomic.make false in
  let on_cancel_once =
    match on_cancel with
    | None -> None
    | Some hook ->
        Some
          (fun () ->
            if Atomic.compare_and_set cancel_hook_called false true then hook ())
  in
  Expert.make ~names:[ name ] @@ fun context ->
  let contract = Expert.contract context in
  let completed, resolver = contract.Runtime_contract.create_promise () in
  let resolved = Atomic.make false in
  let started = Atomic.make false in
  let resolve_once exit =
    if Atomic.compare_and_set resolved false true then
      contract.Runtime_contract.resolve_promise resolver exit
  in
  let work =
    run ?pool ~name ?on_cancel:on_cancel_once (fun () ->
        Atomic.set started true;
        f ())
    |> Eta.Effect.map (function
         | Ok value -> `Ok value
         | Error error -> `Error error)
  in
  let exception Timeout_cancelled_background in
  let cancel_requested = Atomic.make false in
  let cancel_context = Atomic.make None in
  let cancel_background () =
    Atomic.set cancel_requested true;
    if not (Atomic.get resolved) then
      match Atomic.get cancel_context with
      | None -> ()
      | Some cancel_context ->
          contract.Runtime_contract.cancel cancel_context
            Timeout_cancelled_background
  in
  let defaults = current_defaults context in
  Expert.fork_daemon context (fun () ->
      (try
         contract.Runtime_contract.cancel_sub (fun cancel ->
             Atomic.set cancel_context (Some cancel);
             let exit =
               try
                 if Atomic.get cancel_requested then
                   contract.Runtime_contract.cancel cancel
                     Timeout_cancelled_background;
                 contract.Runtime_contract.check ();
                 contract.Runtime_contract.local_with_binding defaults_local
                   defaults (fun () ->
                     contract.Runtime_contract.run_scope @@ fun sw ->
                     Expert.eval_in_scope context sw work)
               with exn -> Expert.exit_of_exn context exn
             in
             resolve_once exit)
       with exn -> resolve_once (Expert.exit_of_exn context exn));
      `Stop_daemon);
  let call_cancel_hook_if_started () =
    match (Atomic.get started, on_cancel_once) with
    | false, _ | true, None -> Eta.Exit.Ok ()
    | true, Some hook -> (
        try
          hook ();
          Eta.Exit.Ok ()
        with exn ->
          if Option.is_some (contract.Runtime_contract.cancellation_reason exn)
          then raise exn
          else Expert.exit_of_exn context exn)
  in
  let publish_value value =
    contract.Runtime_contract.check ();
    Eta.Exit.Ok value
  in
  let publish_error err =
    contract.Runtime_contract.check ();
    Eta.Exit.Error (Eta.Cause.Fail err)
  in
  let wait =
    Eta.Effect.race
      [
        Eta.Effect.sync (fun () ->
            `Completed (contract.Runtime_contract.await_promise completed));
        Eta.Effect.delay timeout (Eta.Effect.pure `Timed_out);
      ]
  in
  try
    match Expert.eval context wait with
    | Eta.Exit.Error cause -> Eta.Exit.Error cause
    | Eta.Exit.Ok (`Completed (Eta.Exit.Ok (`Ok value))) -> publish_value value
    | Eta.Exit.Ok (`Completed (Eta.Exit.Ok (`Error err))) -> publish_error err
    | Eta.Exit.Ok (`Completed (Eta.Exit.Error cause)) -> Eta.Exit.Error cause
    | Eta.Exit.Ok `Timed_out ->
        let hook_exit = call_cancel_hook_if_started () in
        cancel_background ();
        (match hook_exit with
        | Eta.Exit.Ok () -> Eta.Exit.Error (Eta.Cause.Fail on_timeout)
        | Eta.Exit.Error cause -> Eta.Exit.Error cause)
  with exn when Option.is_some (contract.Runtime_contract.cancellation_reason exn) ->
    ignore (call_cancel_hook_if_started ());
    cancel_background ();
    raise exn

let result_timeout = run_result_timeout
