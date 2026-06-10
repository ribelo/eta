(** Convenience runners for interactive Eta sessions.

    Load this package from [dune utop] when convenience matters more than
    explicit runtime ownership:

    {[
      #require "eta_utop";;

      Eta_utop.run (Eta.Effect.pure 42);;
    ]}

    Production code should usually keep using an application-owned runtime so
    clients, resources, and host services have an obvious owner. *)

val with_runtime :
  ?tracer:Eta.Capabilities.tracer ->
  ?sampler:Eta.Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Eta.Capabilities.logger ->
  ?meter:Eta.Capabilities.meter ->
  ?random:Eta.Capabilities.random ->
  ?blocking_pool:Eta_blocking.Pool.t ->
  ?services:Eta.Runtime_contract.service list ->
  ?capture_backtrace:bool ->
  ('err Eta_eio.Runtime.t -> 'a) ->
  'a
(** Run [f] with a fresh Eio-backed Eta runtime. *)

val run :
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
(** Run one eff and return its full Eta exit. *)

val run_exn :
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
  'a
(** Run one eff and raise on non-success, using {!Eta_eio.Runtime.run_exn}. *)
