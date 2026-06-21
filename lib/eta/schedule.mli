(** Pure recurrence-policy descriptions. Drives retry/repeat. *)

type t =
  | Recurs of int
  | Forever
  | Spaced of Duration.t
  | Fixed of Duration.t
  | Exponential of Duration.t * float
  | Fibonacci of Duration.t
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
val fibonacci : Duration.t -> t
val linear : initial:Duration.t -> step:Duration.t -> t

val both : t -> t -> t
val either : t -> t -> t
val and_then : t -> t -> t
val jittered : ?min:float -> ?max:float -> t -> t
val named : string -> t -> t

val pp : Format.formatter -> t -> unit

type driver

val start : ?random:Capabilities.random -> t -> driver
(** Start a stateful schedule driver. [Jittered] draws from [random]. Portable
    runtimes should pass an explicit worker-safe random capability instead of
    relying on the same-domain default. *)

val next : driver -> (Duration.t * driver) option
(** Return the next delay and advanced driver, or [None] when the schedule has
    terminated. Composed schedules advance each phase with its own local step. *)

(** [next_delay schedule ~step] is the wait before the next attempt or [None]
    if the schedule has terminated. This compatibility helper starts a fresh
    driver and advances it to [step]. Prefer {!start} and {!next} when driving
    a schedule repeatedly. *)
val next_delay : ?random:Capabilities.random -> t -> step:int -> Duration.t option
