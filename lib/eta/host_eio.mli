(** Host Eio operations for toplevel-sensitive integrations. *)

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
  module Cancel : CANCEL
end

type t

val make :
  unix:(module UNIX) ->
  eio:(module EIO) ->
  unit ->
  t
(** Capture the host toplevel's Eio modules.

    In [dune utop] sessions, pass modules from the REPL after
    [#require "eio_main"], for example
    [Host_eio.make ~unix:(module Eio_unix) ~eio:(module Eio) ()]. *)

val unix : t -> (module UNIX)
val time : t -> (module TIME)
val net : t -> (module NET)
val flow : t -> (module FLOW)
val switch : t -> (module SWITCH)
val fiber : t -> (module FIBER)
val cancel : t -> (module CANCEL)
