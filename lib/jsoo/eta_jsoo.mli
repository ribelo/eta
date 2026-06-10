(** js_of_ocaml-native runtime backend for Eta.

    This backend implements {!Eta.Runtime_contract.RUNTIME} directly on top of
    JavaScript timers and microtasks. It has no external cooperative scheduler dependency;
    OCaml 5 effects are still required in generated JavaScript, so jsoo targets
    must be built with [--effects=cps]. *)

val clock : Eta.Capabilities.clock

module Runtime : sig
  type 'err t = 'err Eta.Runtime.t

  val create :
    ?sleep:(Eta.Duration.t -> unit) ->
    ?tracer:Eta.Capabilities.tracer ->
    ?sampler:Eta.Sampler.t ->
    ?auto_instrument:bool ->
    ?logger:Eta.Capabilities.logger ->
    ?meter:Eta.Capabilities.meter ->
    ?random:Eta.Capabilities.random ->
    ?services:Eta.Runtime_contract.service list ->
    ?capture_backtrace:bool ->
    unit ->
    'err t

  val run :
    'err t ->
    ('a, 'err) Eta.Effect.t ->
    on_result:(('a, 'err) Eta.Exit.t -> unit) ->
    unit

  val run_exn :
    'err t ->
    ('a, 'err) Eta.Effect.t ->
    on_result:('a -> unit) ->
    unit

  val drain : 'err t -> on_result:(unit -> unit) -> unit
end

val run :
  (unit -> ('a, 'err) Eta.Effect.t) -> on_result:('a -> unit) -> unit
(** Create a default runtime, run the effect to success, and invoke
    [on_result]. *)

val runtime : unit -> (module Eta.Runtime_contract.RUNTIME)
(** Low-level backend contract. Prefer {!Runtime.create}. *)

module Private : sig
  type 'a promise
  type 'a resolver

  val create_promise : unit -> 'a promise * 'a resolver
  val resolve : 'a resolver -> 'a -> unit
  val reject : 'a resolver -> exn -> unit
  val await : ?on_cancel:(unit -> unit) -> 'a promise -> 'a
  (** Await an Eta_jsoo promise from inside an Eta_jsoo runtime fiber. *)
end
