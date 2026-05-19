(** Runtime result of an effect. *)

type ('a, 'err) t =
  | Ok of 'a
  | Error of 'err Cause.t

val ok : 'a -> ('a, 'err) t
val error : 'err Cause.t -> ('a, 'err) t

val to_result : ('a, 'err) t -> ('a, 'err) result option
(** Convert to OCaml [result] only when the exit is [Ok _] or a single
    typed [Fail _]. [Die], [Interrupt], and [Both] have no faithful
    [result] representation. *)

val equal :
  ('a -> 'a -> bool) ->
  ('err -> 'err -> bool) ->
  ('a, 'err) t ->
  ('a, 'err) t ->
  bool

val pp :
  (Format.formatter -> 'a -> unit) ->
  (Format.formatter -> 'err -> unit) ->
  Format.formatter ->
  ('a, 'err) t ->
  unit
