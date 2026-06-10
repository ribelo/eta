(** Eio runtime backend for Eta. *)

module Host : sig
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

  type t

  val make :
    unix:(module UNIX) ->
    eio:(module EIO) ->
    unit ->
    t

  val unix : t -> (module UNIX)
  val time : t -> (module TIME)
  val net : t -> (module NET)
  val flow : t -> (module FLOW)
  val switch : t -> (module SWITCH)
  val fiber : t -> (module FIBER)
  val stream : t -> (module STREAM)
  val cancel : t -> (module CANCEL)
end

module Runtime : sig
  type 'err t = 'err Eta.Runtime.t

  val create :
    sw:Eio.Switch.t ->
    clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
    ?sleep:(Eta.Duration.t -> unit) ->
    ?now_ms:(unit -> int) ->
    ?tracer:Eta.Capabilities.tracer ->
    ?sampler:Eta.Sampler.t ->
    ?auto_instrument:bool ->
    ?logger:Eta.Capabilities.logger ->
    ?meter:Eta.Capabilities.meter ->
    ?random:Eta.Capabilities.random ->
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?blocking_runner:Eta_blocking.Pool.runner ->
    ?services:Eta.Runtime_contract.service list ->
    ?capture_backtrace:bool ->
    unit ->
    'err t

  val with_host :
    Host.t ->
    sw:Eio.Switch.t ->
    clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
    ?now_ms:(unit -> int) ->
    ?tracer:Eta.Capabilities.tracer ->
    ?sampler:Eta.Sampler.t ->
    ?auto_instrument:bool ->
    ?logger:Eta.Capabilities.logger ->
    ?meter:Eta.Capabilities.meter ->
    ?random:Eta.Capabilities.random ->
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?services:Eta.Runtime_contract.service list ->
    ?capture_backtrace:bool ->
    ('err t -> 'a) ->
    'a

  val run_host :
    Host.t ->
    sw:Eio.Switch.t ->
    clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
    ?now_ms:(unit -> int) ->
    ?tracer:Eta.Capabilities.tracer ->
    ?sampler:Eta.Sampler.t ->
    ?auto_instrument:bool ->
    ?logger:Eta.Capabilities.logger ->
    ?meter:Eta.Capabilities.meter ->
    ?random:Eta.Capabilities.random ->
    ?blocking_pool:Eta_blocking.Pool.t ->
    ?services:Eta.Runtime_contract.service list ->
    ?capture_backtrace:bool ->
    ('a, 'err) Eta.Effect.t ->
    ('a, 'err) Eta.Exit.t

  val run :
    ?blocking_pool:Eta_blocking.Pool.t ->
    'err t ->
    ('a, 'err) Eta.Effect.t ->
    ('a, 'err) Eta.Exit.t

  val run_exn : 'err t -> ('a, 'err) Eta.Effect.t -> 'a
  val drain : 'err t -> unit
end

val clock : [> float Eio.Time.clock_ty ] Eio.Std.r -> Eta.Capabilities.clock

val default_blocking_runner : Eta_blocking.Pool.runner
(** Blocking-pool runner backed by [Eio_unix.run_in_systhread]. Runtime
    constructors in this module install it by default; pass it explicitly when
    creating standalone pools that should use the Eio worker substrate. *)

val runtime :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  (module Eta.Runtime_contract.RUNTIME)
(** Eio runtime as a module-shaped backend implementation. This is the
    backend contract consumed by {!Eta.Runtime.create_with_runtime} and
    {!Eta.Runtime.Make}. *)

val runtime_with_host :
  Host.t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  (module Eta.Runtime_contract.RUNTIME)
