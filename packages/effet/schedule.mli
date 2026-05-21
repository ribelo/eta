(** Pure recurrence-policy descriptions. Drives retry/repeat. *)

type t : immutable_data =
  | Recurs of int
  | Forever
  | Spaced of Duration.t
  | Fixed of Duration.t
  | Exponential of Duration.t * float
  | Linear of { initial : Duration.t; step : Duration.t }
  | Both of t * t
  | Either of t * t
  | And_then of t * t
  | Jittered of t * float * float
  | Named of t * string

val recurs : int -> t
val forever : t
val spaced : Duration.t -> t
val fixed : Duration.t -> t
val exponential : ?factor:float -> Duration.t -> t
val linear : initial:Duration.t -> step:Duration.t -> t

val both : t -> t -> t
val either : t -> t -> t
val and_then : t -> t -> t
val jittered : ?min:float -> ?max:float -> t -> t
val named : string -> t -> t

val pp : Format.formatter -> t -> unit

(** [next_delay schedule ~step] is the wait before the next attempt or
    [None] if the schedule has terminated. Pure; deterministic except
    when [Jittered] is in the tree. *)
val next_delay : t -> step:int -> Duration.t option
