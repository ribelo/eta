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
    ?now_ms:(unit -> int) ->
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
  (** Create a JavaScript runtime.

      The default runtime clock is [performance.now()] and sleeps use
      [setTimeout], so Eta time is monotonic elapsed runtime time rather than
      wall/civil time. Any [?sleep] override must preserve that same time-base
      relationship with {!Eta.Effect.now_ms}; use [?now_ms] with [?sleep] for
      deterministic clocks in tests. *)

  val run :
    'err t ->
    ('a, 'err) Eta.Effect.t ->
    on_result:(('a, 'err) Eta.Exit.t -> unit) ->
    unit
  (** Schedule [eff] on the JavaScript host and invoke [on_result] from a
      later microtask/timer turn.

      Exceptions raised by [on_result] are not re-raised to the caller of
      [run]; they escape from that scheduled JavaScript callback and surface as
      uncaught JavaScript errors. *)

  val run_exn :
    'err t ->
    ('a, 'err) Eta.Effect.t ->
    on_result:('a -> unit) ->
    unit
  (** Like {!run}, but pass only successful values to [on_result].

      Defects are re-raised from the scheduled callback. Typed failures are
      rendered through {!Eta.Cause.pp}; because the concrete typed error printer
      is not available at this boundary, typed error payloads are shown as
      [<typed failure>]. *)

  val drain : 'err t -> on_result:(unit -> unit) -> unit
  (** Schedule pending finalizers/work and invoke [on_result] from a later
      microtask/timer turn. Exceptions raised by [on_result] escape as uncaught
      JavaScript errors. *)
end

val run :
  (unit -> ('a, 'err) Eta.Effect.t) -> on_result:('a -> unit) -> unit
(** Create a default runtime, run the effect to success, and invoke
    [on_result] from a later microtask/timer turn. Exceptions raised by
    [on_result] escape as uncaught JavaScript errors. *)

val runtime : unit -> (module Eta.Runtime_contract.RUNTIME)
(** Low-level backend contract. Prefer {!Runtime.create}. *)

module Private : sig
  type 'a promise
  type 'a resolver

  val create_promise : unit -> 'a promise * 'a resolver
  val pending_subscriptions : 'a promise -> int
  (** Number of active subscription records retained by an unsettled promise. *)

  val resolve : 'a resolver -> 'a -> unit
  val reject : 'a resolver -> exn -> unit
  val await : ?on_cancel:(unit -> unit) -> 'a promise -> 'a
  (** Await an Eta_jsoo promise from inside an Eta_jsoo runtime fiber.

      Cancellation removes the promise subscription before [on_cancel] runs.
      If [on_cancel] raises, its exception resumes the waiter as a defect. *)
end
