(** Runtime result of an eff. *)

type ('a, 'err) t =
  | Ok of 'a
  | Error of 'err Cause.t

val ok : 'a -> ('a, 'err) t
val error : 'err Cause.t -> ('a, 'err) t

val is_ok : ('a, 'err) t -> bool
val is_error : ('a, 'err) t -> bool
val get_success : ('a, 'err) t -> 'a option
val get_cause : ('a, 'err) t -> 'err Cause.t option

val match_ :
  ok:('a -> 'b) -> error:('err Cause.t -> 'b) -> ('a, 'err) t -> 'b

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
val map_error : ('err1 -> 'err2) -> ('a, 'err1) t -> ('a, 'err2) t

val map_both :
  ok:('a -> 'b) ->
  error:('err1 -> 'err2) ->
  ('a, 'err1) t ->
  ('b, 'err2) t

val get_or_else : ('err Cause.t -> 'a) -> ('a, 'err) t -> 'a
val as_unit : ('a, 'err) t -> (unit, 'err) t

val to_result : ('a, 'err) t -> ('a, 'err) result option
(** Convert to OCaml [result] only when the exit is [Ok _] or a single
    typed [Fail _]. [Die], [Interrupt], [Sequential], [Concurrent], and
    [Suppressed] have no faithful [result] representation. *)

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

val pretty : ('a -> string) -> ('err -> string) -> ('a, 'err) t -> string
(** Render an exit to a compact terminal-oriented string. *)
