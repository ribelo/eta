(** Eio-backed interpreter for Effet effects. *)

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
  ?capture_backtrace:bool ->
  unit ->
  'err t
(** Create an interpreter.

    [capture_backtrace] controls whether unchecked exceptions captured as
    [Cause.Die] carry [Printexc.raw_backtrace]. It defaults to [true]. Disable
    it only for runtimes where defect-path allocation cost matters more than
    diagnostics. *)

val run : 'err t -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t
(** Run an effect to completion. *)

val run_exn : 'err t -> ('a, 'err) Effect.t -> 'a
(** Run an effect and raise on non-success. Prefer {!run} when
    inspecting failures. *)

val drain : 'err t -> unit
(** Wait until currently runtime-owned finite background fibers complete. *)
