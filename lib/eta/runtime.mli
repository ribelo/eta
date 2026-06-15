(** Runtime-backed interpreter for Eta effects. *)

type 'err t

val create_with_runtime :
  (module Runtime_contract.RUNTIME) ->
  ?sleep:(Duration.t -> unit) ->
  ?now_ms:(unit -> int) ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?services:Runtime_contract.service list ->
  ?capture_backtrace:bool ->
  unit ->
  'err t
(** Create an interpreter from a module-shaped backend runtime.

    Runtime packages should implement {!Runtime_contract.RUNTIME} and pass the
    module here. Eta currently erases that module into the interpreter's
    internal representation; the module boundary is the public contract for
    future functorized runtimes.

    [services] attaches optional runtime-package services. Root [eta] does not
    inspect their types; packages such as [eta_blocking] own their keys and
    retrieve them through [Effect.Expert].

    [capture_backtrace] controls whether unchecked exceptions captured as
    [Cause.Die] carry [Printexc.raw_backtrace]. It defaults to [true]. Disable
    it only for runtimes where defect-path allocation cost matters more than
    diagnostics. *)

module Make (_ : Runtime_contract.RUNTIME) : sig
  val create :
    ?sleep:(Duration.t -> unit) ->
    ?now_ms:(unit -> int) ->
    ?tracer:Capabilities.tracer ->
    ?sampler:Sampler.t ->
    ?auto_instrument:bool ->
    ?logger:Capabilities.logger ->
    ?meter:Capabilities.meter ->
    ?random:Capabilities.random ->
    ?services:Runtime_contract.service list ->
    ?capture_backtrace:bool ->
    unit ->
    'err t
  (** Create an interpreter using the runtime module applied to this functor. *)

  val run : 'err t -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t

  val run_exn : 'err t -> ('a, 'err) Effect.t -> 'a
  val drain : 'err t -> unit
end
(** Functor-shaped runtime constructor for backends that want a statically
    applied module instead of passing a first-class module through each create
    call. *)

val run : 'err t -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t
(** Run an eff to completion. *)

val run_exn : 'err t -> ('a, 'err) Effect.t -> 'a
(** Run an eff and raise on non-success. Prefer {!run} when
    inspecting failures.

    - [Cause.Die] defects are re-raised with their captured backtrace.
    - Typed failures, interruption, and composite causes raise [Failure]
      with a rendered cause string.

    This is a convenience exit for tests and top-level programs that cannot
    recover; do not use it inside effectful recovery logic. *)

val drain : 'err t -> unit
(** Wait until currently runtime-owned finite background fibers complete. *)

val metrics_enabled : _ t -> bool
(** Whether a meter is installed (i.e. metrics will actually be recorded).
    Hot-path code can use this to skip building metric label attributes when no
    meter is present; a noop meter records nothing, so this changes no observable
    behavior. *)

val tracing_enabled : _ t -> bool
(** Whether a tracer is installed (i.e. spans will actually be recorded). *)
