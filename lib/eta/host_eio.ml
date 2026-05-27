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
    ?combine:('a -> 'a -> 'a) -> (unit -> 'a) -> (unit -> 'a) -> 'a

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

type t = {
  unix : (module UNIX);
  time : (module TIME);
  net : (module NET);
  flow : (module FLOW);
  switch : (module SWITCH);
  fiber : (module FIBER);
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
    cancel = (module Eio.Cancel);
  }

let unix t = t.unix
let time t = t.time
let net t = t.net
let flow t = t.flow
let switch t = t.switch
let fiber t = t.fiber
let cancel t = t.cancel
