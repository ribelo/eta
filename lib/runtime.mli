(** Eio-backed interpreter for Effet effects. *)

type ('env, 'err) t

val create :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?sleep:(Duration.t -> unit) ->
  env:'env ->
  unit ->
  ('env, 'err) t

val run : ('env, 'err) t -> ('env, 'err, 'a) Effect.t -> ('a, 'err) result
(** Run an effect to completion. Typed failures become [Error err]. *)

val run_exn : ('env, 'err) t -> ('env, 'err, 'a) Effect.t -> 'a
(** Run an effect and raise [Failure "Effet.Runtime.run_exn"] for an
    uncaught typed failure. Prefer {!run} when inspecting failures. *)

val drain : ('env, 'err) t -> unit
(** Wait until currently detached finite fibers complete. *)
