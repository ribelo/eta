module Host = struct
  module type UNIX = sig
    val run_in_systhread : ?label:string -> (unit -> 'a) -> 'a
  end

  module type TIME = sig
    val now : [> float Eio.Time.clock_ty ] Eio.Std.r -> float
    val sleep : [> float Eio.Time.clock_ty ] Eio.Std.r -> float -> unit
  end

  module type NET = sig
    val getaddrinfo_stream :
      ?service:string -> _ Eio.Net.t -> string -> Eio.Net.Sockaddr.stream list

    val connect :
      sw:Eio.Switch.t ->
      [> 'tag Eio.Net.ty ] Eio.Net.t ->
      Eio.Net.Sockaddr.stream ->
      'tag Eio.Net.stream_socket_ty Eio.Resource.t
  end

  module type FLOW = sig
    val single_read : _ Eio.Flow.source -> Cstruct.t -> int
    val write : _ Eio.Flow.sink -> Cstruct.t list -> unit
  end

  module type SWITCH = sig
    val run : ?name:string -> (Eio.Switch.t -> 'a) -> 'a
    val fail : ?bt:Printexc.raw_backtrace -> Eio.Switch.t -> exn -> unit
  end

  module type FIBER = sig
    val get : 'a Eio.Fiber.key -> 'a option
    val with_binding : 'a Eio.Fiber.key -> 'a -> (unit -> 'b) -> 'b

    val first :
      ?combine:('a -> 'a -> 'a) ->
      (unit -> 'a) ->
      (unit -> 'a) ->
      'a

    val await_cancel : unit -> 'a
    val fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
    val fork_daemon : sw:Eio.Switch.t -> (unit -> [ `Stop_daemon ]) -> unit
    val yield : unit -> unit
    val check : unit -> unit
  end

  module type STREAM = sig
    type 'a t

    val create : int -> 'a t
    val add : 'a t -> 'a -> unit
    val take : 'a t -> 'a
    val take_nonblocking : 'a t -> 'a option
  end

  module type CANCEL = sig
    val sub : (Eio.Cancel.t -> 'a) -> 'a
    val cancel : Eio.Cancel.t -> exn -> unit
  end

  module type EIO = sig
    module Time : TIME
    module Net : NET
    module Flow : FLOW
    module Switch : SWITCH
    module Fiber : FIBER
    module Stream : STREAM
    module Cancel : CANCEL
  end

  type t = {
    unix : (module UNIX);
    time : (module TIME);
    net : (module NET);
    flow : (module FLOW);
    switch : (module SWITCH);
    fiber : (module FIBER);
    stream : (module STREAM);
    cancel : (module CANCEL);
  }

  let make ~unix ~eio () =
    let module Eio = (val eio : EIO) in
    {
      unix;
      time = (module Eio.Time);
      net = (module Eio.Net);
      flow = (module Eio.Flow);
      switch = (module Eio.Switch);
      fiber = (module Eio.Fiber);
      stream = (module Eio.Stream);
      cancel = (module Eio.Cancel);
    }

  let unix t = t.unix
  let time t = t.time
  let net t = t.net
  let flow t = t.flow
  let switch t = t.switch
  let fiber t = t.fiber
  let stream t = t.stream
  let cancel t = t.cancel
end

let clock (c : _ Eio.Std.r) : Eta.Capabilities.clock =
  let c = (c :> float Eio.Time.clock_ty Eio.Std.r) in
  object
    method sleep d = Eio.Time.sleep c (Eta.Duration.to_seconds_float d)
  end

let default_blocking_runner : Eta_blocking.Pool.runner =
  {
    Eta_blocking.Pool.run_worker =
      (fun ~label f -> Eio_unix.run_in_systhread ~label f);
  }

module Worker_context = struct
  let mutex = Mutex.create ()
  let workers : (int, int) Hashtbl.t = Hashtbl.create 16

  let current_id () = Thread.id (Thread.self ())

  let enter () =
    let id = current_id () in
    Mutex.lock mutex;
    let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
    Hashtbl.replace workers id (count + 1);
    Mutex.unlock mutex;
    id

  let leave id =
    Mutex.lock mutex;
    let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
    if count <= 1 then Hashtbl.remove workers id
    else Hashtbl.replace workers id (count - 1);
    Mutex.unlock mutex

  let run f =
    let id = enter () in
    Fun.protect ~finally:(fun () -> leave id) f

  let active () =
    let id = current_id () in
    Mutex.lock mutex;
    let result = Hashtbl.mem workers id in
    Mutex.unlock mutex;
    result
end

let () =
  Eta.Runtime_contract.register_worker_context_probe Worker_context.active

let local_context_key : (int, Obj.t) Hashtbl.t Eio.Fiber.key =
  Eio.Fiber.create_key ()
let protect_context_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()
let fiberless_local_context_key : (int, Obj.t) Hashtbl.t option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let has_eio_fiber_context () =
  try
    ignore (Eio.Fiber.get protect_context_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let protect f = if has_eio_fiber_context () then Eio.Cancel.protect f else f ()

let local_context (module Fiber : Host.FIBER) =
  try Fiber.get local_context_key with Stdlib.Effect.Unhandled _ ->
    Domain.DLS.get fiberless_local_context_key

let with_fiberless_context context f =
  let previous = Domain.DLS.get fiberless_local_context_key in
  Domain.DLS.set fiberless_local_context_key (Some context);
  Fun.protect
    ~finally:(fun () -> Domain.DLS.set fiberless_local_context_key previous)
    f

let local_get_with fiber local =
  match local_context fiber with
  | None -> None
  | Some context -> (
      match Hashtbl.find_opt context (Eta.Runtime_contract.Backend.local_id local) with
      | None -> None
      | Some value -> Some (Obj.obj value))

let local_with_binding_with (module Fiber : Host.FIBER) local value f =
  let id = Eta.Runtime_contract.Backend.local_id local in
  let context =
    match local_context (module Fiber) with
    | None -> Hashtbl.create 8
    | Some context -> Hashtbl.copy context
  in
  Hashtbl.replace context id (Obj.repr value);
  try Fiber.with_binding local_context_key context f
  with Stdlib.Effect.Unhandled _ -> with_fiberless_context context f

let eio_fiber = (module Eio.Fiber : Host.FIBER)
let local_get local = local_get_with eio_fiber local
let local_with_binding local value f = local_with_binding_with eio_fiber local value f

let runtime_with_host host ~sw ~clock:raw_clock =
  let module Time = (val Host.time host : Host.TIME) in
  let module Switch = (val Host.switch host : Host.SWITCH) in
  let module Fiber = (val Host.fiber host : Host.FIBER) in
  let module Stream = (val Host.stream host : Host.STREAM) in
  let module Cancel = (val Host.cancel host : Host.CANCEL) in
  let fiber = (module Fiber : Host.FIBER) in
  let clock = (raw_clock :> float Eio.Time.clock_ty Eio.Std.r) in
  (module struct
    type scope = Eio.Switch.t
    type cancel_context = Eio.Cancel.t
    type 'a promise = 'a Eio.Promise.t
    type 'a resolver = 'a Eio.Promise.u
    type 'a stream = 'a Stream.t

    let root_scope = sw
    let now_ms () = int_of_float (Time.now clock *. 1000.0)
    let sleep duration =
      let seconds = Eta.Duration.to_seconds_float duration in
      if seconds > 0.0 then Time.sleep clock seconds

    let protect = protect
    let run_scope = Switch.run
    let fail_scope = Switch.fail
    let fork scope f = Fiber.fork ~sw:scope f
    let fork_daemon scope f = Fiber.fork_daemon ~sw:scope f
    let await_cancel () = Fiber.await_cancel ()
    let yield () = Fiber.yield ()
    let check () = Fiber.check ()
    let create_promise () = Eio.Promise.create ()
    let resolve_promise = Eio.Promise.resolve
    let await_promise = Eio.Promise.await
    let create_stream = Stream.create
    let stream_add = Stream.add
    let stream_take = Stream.take
    let stream_take_nonblocking = Stream.take_nonblocking
    let with_worker_context = Worker_context.run
    let in_worker_context = Worker_context.active
    let cancellation_reason = function
      | Eio.Cancel.Cancelled reason -> Some reason
      | _ -> None
    let multiple_exceptions = function
      | Eio.Exn.Multiple causes -> Some causes
      | _ -> None
    let cancel_sub f = Cancel.sub f
    let cancel = Cancel.cancel
    let local_get local = local_get_with fiber local
    let local_with_binding local value f =
      local_with_binding_with fiber local value f
  end : Eta.Runtime_contract.RUNTIME)

let default_host =
  Host.make ~unix:(module Eio_unix) ~eio:(module Eio) ()

let runtime ~sw ~clock = runtime_with_host default_host ~sw ~clock

let host_blocking_runner host =
  let module Unix = (val Host.unix host : Host.UNIX) in
  {
    Eta_blocking.Pool.run_worker =
      (fun ~label f -> Unix.run_in_systhread ~label f);
  }

module Runtime = struct
  type 'err t = 'err Eta.Runtime.t

  let create ~sw ~clock ?sleep ?tracer ?sampler ?auto_instrument ?logger ?meter
      ?random ?blocking_pool ?blocking_runner ?capture_backtrace
      () =
    let blocking_runner =
      match blocking_runner with
      | Some _ as runner -> runner
      | None -> Some default_blocking_runner
    in
    let services =
      [ Eta_blocking.runtime_service ?pool:blocking_pool ?runner:blocking_runner () ]
    in
    Eta.Runtime.create_with_runtime (runtime ~sw ~clock) ?sleep ?tracer
      ?sampler ?auto_instrument ?logger ?meter ?random ~services
      ?capture_backtrace ()

  let with_host host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
      ?meter ?random ?blocking_pool ?capture_backtrace f =
    let blocking_runner = host_blocking_runner host in
    let runtime =
      let services =
        [ Eta_blocking.runtime_service ?pool:blocking_pool
            ~runner:blocking_runner () ]
      in
      Eta.Runtime.create_with_runtime (runtime_with_host host ~sw ~clock)
        ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ~services
        ?capture_backtrace ()
    in
    f runtime

  let run_host host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
      ?meter ?random ?blocking_pool ?capture_backtrace eff =
    with_host host ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger ?meter
      ?random ?blocking_pool ?capture_backtrace (fun runtime ->
        Eta.Runtime.run runtime eff)

  let run ?blocking_pool runtime eff =
    Eta.Runtime.run runtime (Eta_blocking.with_defaults ?pool:blocking_pool eff)
  let run_exn = Eta.Runtime.run_exn
  let drain = Eta.Runtime.drain
end
