(** Failure causes that cannot fit in OCaml's [('a, 'e) result].

    [Fail] is the typed error channel. [Die] is an unchecked exception
    from user code or the host runtime. [Interrupt] is cancellation, with an
    optional runtime-owned interruption identity.

    [Sequential] preserves ordered failures from sequential composition.
    [Concurrent] preserves failures observed from parallel composition.
    [Suppressed] preserves a primary failure together with a finalizer failure
    that occurred while cleaning up the primary failure. *)

type interrupt_id

type 'err t =
  | Fail of 'err
  | Die of exn * Printexc.raw_backtrace option
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }

val fail : 'err -> 'err t
val die : exn -> 'err t
val die_with_backtrace : exn -> Printexc.raw_backtrace -> 'err t
val interrupt : 'err t
val interrupt_with_id : interrupt_id -> 'err t
val sequential : 'err t list -> 'err t
val concurrent : 'err t list -> 'err t
val suppressed : primary:'err t -> finalizer:'err t -> 'err t

val is_interrupt_only : 'err t -> bool

val equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
val pp : (Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit
