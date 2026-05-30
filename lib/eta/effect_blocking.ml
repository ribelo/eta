(** Blocking-pool offload for synchronous syscalls and FFI. Internal: see Effect
    for the public surface. *)

open Effect_core

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

  let submit ?pool ?(name = "blocking") ?on_cancel f =
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

let blocking ?pool ?(name = "blocking") ?on_cancel f =
  Blocking.submit ?pool ~name ?on_cancel f

let blocking_result ?pool ?name ?on_cancel f =
  blocking ?pool ?name ?on_cancel f |> bind from_result
