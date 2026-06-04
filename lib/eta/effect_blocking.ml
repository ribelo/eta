(** Blocking-pool offload for synchronous syscalls and FFI. Internal: see Effect
    for the public surface. *)

open Effect_core
open Effect_concurrent

module Blocking = struct
  type ('a, 'err) effect = ('a, 'err) t

  module Pool = struct
    include Blocking_runtime.Pool

    let shutdown pool =
      make @@ fun () ->
      let frame = current_frame () in
      try
        Blocking_runtime.shutdown ~emit:Runtime_observability.emit_current_blocking_event pool;
        ok ()
      with exn -> exit_of_exn frame exn
  end

  let submit ?pool ?(name = "blocking") ?on_cancel (f @ many) =
    Blocking_runtime.check_not_worker "Effect.Blocking.submit";
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    let run () =
      Blocking_runtime.submit ~sw:frame.runtime.outer_sw
        ~emit:(Runtime_core.emit_blocking_event frame.runtime)
        (Runtime_core.blocking_pool frame.runtime pool) name ?on_cancel f
    in
    try
      ok
        (if frame.runtime.auto_instrument then
           Runtime_instrument.instrument_leaf ~runtime:frame.runtime
             ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~name run
         else run ())
    with exn -> exit_of_exn frame exn
end

let blocking ?pool ?(name = "blocking") ?on_cancel (f @ many) =
  Blocking.submit ?pool ~name ?on_cancel f

let blocking_result ?pool ?name ?on_cancel (f @ many) =
  blocking ?pool ?name ?on_cancel f |> bind from_result

let blocking_result_timeout ?pool ?name ?on_cancel ~timeout ~on_timeout (f @ many) =
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
  make ~names:[ name ] @@ fun () ->
  let frame = current_frame () in
  let completed, resolver = Eio.Promise.create () in
  let resolved = Atomic.make false in
  let started = Atomic.make false in
  let resolve_once exit =
    if Atomic.compare_and_set resolved false true then
      Eio.Promise.resolve resolver exit
  in
  let work =
    blocking ?pool ~name ?on_cancel:on_cancel_once (fun () ->
        Atomic.set started true;
        f ())
    |> map (function
         | Ok value -> `Ok value
         | Error error -> `Error error)
  in
  let exception Timeout_cancelled_background in
  let cancel_requested = Atomic.make false in
  let cancel_context = Atomic.make None in
  (* The timeout races only the caller's wait. The background fiber owns the
     blocking submission so queued jobs can be cancelled before start while
     started Drain jobs remain tracked until the worker returns. *)
  let cancel_background () =
    Atomic.set cancel_requested true;
    if not (Atomic.get resolved) then
      match Atomic.get cancel_context with
      | None -> ()
      | Some context ->
          cancel_cancel frame context Timeout_cancelled_background
  in
  Runtime_core.incr_active frame.runtime;
  fiber_fork_daemon frame ~sw:frame.runtime.outer_sw (fun () ->
      frame.runtime.tracer#with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> Runtime_core.decr_active frame.runtime)
        (fun () ->
          (try
             cancel_sub frame (fun context ->
                 Atomic.set cancel_context (Some context);
                 let exit =
                   try
                     if Atomic.get cancel_requested then
                       cancel_cancel frame context Timeout_cancelled_background;
                     Eio.Fiber.check ();
                     switch_run frame @@ fun sw -> run_scope ~sw frame work
                   with exn -> exit_of_exn frame exn
                 in
                 resolve_once exit)
           with exn -> resolve_once (exit_of_exn frame exn));
          `Stop_daemon));
  let call_cancel_hook_if_started () =
    match (Atomic.get started, on_cancel_once) with
    | false, _ | true, None -> ok ()
    | true, Some hook -> (
        try
          hook ();
          ok ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> exit_of_exn frame exn)
  in
  let publish_value value =
    Eio.Fiber.check ();
    ok value
  in
  let publish_error err =
    Eio.Fiber.check ();
    error (Cause.Fail err)
  in
  let wait =
    race
      [
        sync (fun () -> `Completed (Eio.Promise.await completed));
        delay timeout (pure `Timed_out);
      ]
  in
  try
    match wait.eval () with
    | Exit.Error cause -> error cause
    | Exit.Ok (`Completed (Exit.Ok (`Ok value))) -> publish_value value
    | Exit.Ok (`Completed (Exit.Ok (`Error err))) -> publish_error err
    | Exit.Ok (`Completed (Exit.Error cause)) -> error cause
    | Exit.Ok `Timed_out ->
        let hook_exit = call_cancel_hook_if_started () in
        cancel_background ();
        (match hook_exit with
        | Exit.Ok () -> error (Cause.Fail on_timeout)
        | Exit.Error cause -> error cause)
  with Eio.Cancel.Cancelled _ as exn ->
    ignore (call_cancel_hook_if_started ());
    cancel_background ();
    raise exn
