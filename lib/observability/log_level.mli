(** Severity level for log records.

    [All] and [Off] are threshold helpers; they are not emitted as record
    levels. Levels order from least to most severe: Trace < Debug < Info <
    Warn < Error < Fatal. *)

type t =
  | All
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal
  | Off

val to_string : t -> string
val of_string : string -> t option
val compare : t -> t -> int
val equal : t -> t -> bool
val is_enabled : at:t -> threshold:t -> bool
(** [is_enabled ~at ~threshold] is [true] when [at] is at least as severe as
    [threshold], treating [All] as passing every level and [Off] as passing
    none. *)

val to_otel_severity : t -> int
val of_otel_severity : int -> t
val pp : Format.formatter -> t -> unit
val all : t list
