(** Eio-backed interpreter for Eta effects. *)

type 'err t

val create :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?sleep:(Duration.t -> unit) ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?island_pool:Effect.Island.pool ->
  ?blocking_pool:Effect.Blocking.Pool.t ->
  ?blocking_runner:Effect.Blocking.Pool.runner ->
  ?capture_backtrace:bool ->
  unit ->
  'err t
(** Create an interpreter.

    [island_pool] configures the reusable worker-domain executor used by
    {!Effect.island} and {!Effect.Island} combinators. Missing configuration is
    a runtime defect; Eta does not silently run island work in the current
    domain.

    [blocking_pool] overrides the runtime-owned default pool used by
    {!Effect.blocking} when a call does not pass [?pool]. If omitted, the
    runtime lazily creates a bounded Phase 1 pool using the measured default
    config documented on {!Effect.Blocking.Pool.create}.

    [blocking_runner] configures the worker substrate for that lazy default
    blocking pool. Pass a runner built from the host application's Eio instance
    when using [dune utop] workflows that load Eta before [eio_main].

    [capture_backtrace] controls whether unchecked exceptions captured as
    [Cause.Die] carry [Printexc.raw_backtrace]. It defaults to [true]. Disable
    it only for runtimes where defect-path allocation cost matters more than
    diagnostics. *)

val with_host_eio_unix :
  (module Effect.Blocking.Pool.EIO_UNIX) ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?sleep:(Duration.t -> unit) ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?island_pool:Effect.Island.pool ->
  ?blocking_pool:Effect.Blocking.Pool.t ->
  ?capture_backtrace:bool ->
  (Eio.Switch.t -> 'err t -> 'a) ->
  'a
(** Create a runtime in a fresh switch using the host application's [Eio_unix]
    module as the blocking substrate.

    This is mainly for [dune utop] workflows where Eta is loaded before
    [eio_main]:

    {[
      #require "eio_main";;

      Eio_main.run @@ fun env ->
      Runtime.with_host_eio_unix (module Eio_unix)
        ~clock:(Eio.Stdenv.clock env)
        ~random:(Capabilities.random_of_seed 1)
      @@ fun _sw rt ->
      Runtime.run rt effect
    ]} *)

val run :
  ?island_pool:Effect.Island.pool ->
  ?blocking_pool:Effect.Blocking.Pool.t ->
  'err t ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t
(** Run an effect to completion. [island_pool] and [blocking_pool] override the
    runtime defaults for this run only. *)

val run_exn : 'err t -> ('a, 'err) Effect.t -> 'a
(** Run an effect and raise on non-success. Prefer {!run} when
    inspecting failures. *)

val drain : 'err t -> unit
(** Wait until currently runtime-owned finite background fibers complete. *)
