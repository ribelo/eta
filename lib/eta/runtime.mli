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
    blocking pool.

    [capture_backtrace] controls whether unchecked exceptions captured as
    [Cause.Die] carry [Printexc.raw_backtrace]. It defaults to [true]. Disable
    it only for runtimes where defect-path allocation cost matters more than
    diagnostics. *)

val with_host_eio :
  Host_eio.t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?island_pool:Effect.Island.pool ->
  ?blocking_pool:Effect.Blocking.Pool.t ->
  ?capture_backtrace:bool ->
  ('err t -> 'a) ->
  'a
(** Create a runtime from a host switch using host Eio operations for blocking
    workers and sleeps.

    This is mainly for [dune utop] workflows where Eta is loaded before
    [eio_main]:

    {[
      #require "eio_main";;

      let host =
        Host_eio.make
          ~unix:(module Eio_unix)
          ~eio:(module Eio)
          ()
      ;;

      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Runtime.with_host_eio host ~sw
        ~clock:(Eio.Stdenv.clock env)
        ~random:(Capabilities.random_of_seed 1)
      @@ fun rt ->
      Runtime.run rt effect
    ]} *)

val run_host_eio :
  Host_eio.t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?island_pool:Effect.Island.pool ->
  ?blocking_pool:Effect.Blocking.Pool.t ->
  ?capture_backtrace:bool ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t
(** Create a host-backed runtime and run one effect to completion. *)

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
