(** Resolved Eio primitives used by the Eta interpreter.

    Runtime creation chooses direct Eio or host-injected Eio once; hot-path
    eff interpretation calls this substrate without re-checking Host_eio. *)

type t = {
  fiber_get : 'a. 'a Eio.Fiber.key -> 'a option;
  fiber_with_binding :
    'a 'b.
    dls_active:bool ->
    enter_fiberless:((unit -> 'b) -> 'b) ->
    'a Eio.Fiber.key ->
    'a ->
    (unit -> 'b) ->
    'b;
  fiber_fork : sw:Eio.Switch.t -> (unit -> unit) -> unit;
  fiber_fork_daemon :
    sw:Eio.Switch.t -> (unit -> [ `Stop_daemon ]) -> unit;
  fiber_await_cancel : 'a. unit -> 'a;
  fiber_yield : unit -> unit;
  switch_run : 'a. ?name:string -> (Eio.Switch.t -> 'a) -> 'a;
  switch_fail :
    ?bt:Printexc.raw_backtrace -> Eio.Switch.t -> exn -> unit;
  cancel_sub : 'a. (Eio.Cancel.t -> 'a) -> 'a;
  cancel_cancel : Eio.Cancel.t -> exn -> unit;
}

let direct_context_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let direct_has_fiber_context () =
  try
    ignore (Eio.Fiber.get direct_context_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let direct =
  {
    fiber_get =
      (fun key ->
        try Eio.Fiber.get key with Stdlib.Effect.Unhandled _ -> None);
    fiber_with_binding =
      (fun ~dls_active:_ ~enter_fiberless key value f ->
        if direct_has_fiber_context () then Eio.Fiber.with_binding key value f
        else enter_fiberless f);
    fiber_fork = (fun ~sw f -> Eio.Fiber.fork ~sw f);
    fiber_fork_daemon = (fun ~sw f -> Eio.Fiber.fork_daemon ~sw f);
    fiber_await_cancel = (fun () -> Eio.Fiber.await_cancel ());
    fiber_yield = (fun () -> Eio.Fiber.yield ());
    switch_run = (fun ?name f -> Eio.Switch.run ?name f);
    switch_fail = (fun ?bt sw exn -> Eio.Switch.fail ?bt sw exn);
    cancel_sub = (fun f -> Eio.Cancel.sub f);
    cancel_cancel = (fun cancel_context exn ->
      Eio.Cancel.cancel cancel_context exn);
  }

let of_host host =
  let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
  let module Switch = (val Host_eio.switch host : Host_eio.SWITCH) in
  let module Cancel = (val Host_eio.cancel host : Host_eio.CANCEL) in
  {
    fiber_get =
      (fun key ->
        try Fiber.get key with Stdlib.Effect.Unhandled _ -> None);
    fiber_with_binding =
      (fun ~dls_active ~enter_fiberless key value f ->
        let bind () = Fiber.with_binding key value f in
        if dls_active then bind () else enter_fiberless bind);
    fiber_fork = (fun ~sw f -> Fiber.fork ~sw f);
    fiber_fork_daemon = (fun ~sw f -> Fiber.fork_daemon ~sw f);
    fiber_await_cancel = (fun () -> Fiber.await_cancel ());
    fiber_yield = (fun () -> Fiber.yield ());
    switch_run = (fun ?name f -> Switch.run ?name f);
    switch_fail = (fun ?bt sw exn -> Switch.fail ?bt sw exn);
    cancel_sub = (fun f -> Cancel.sub f);
    cancel_cancel = (fun cancel_context exn ->
      Cancel.cancel cancel_context exn);
  }
