(** Failure causes that cannot fit in OCaml's [('a, 'e) result].

    [Fail] is the typed error channel. [Die] is an unchecked exception
    from user code or the host runtime. [Interrupt] is cancellation.
    [Both] preserves failures observed from parallel composition. *)

type 'err t =
  | Fail of 'err
  | Die of exn
  | Interrupt
  | Both of 'err t * 'err t

val fail : 'err -> 'err t
val die : exn -> 'err t
val interrupt : 'err t
val both : 'err t -> 'err t -> 'err t

val equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
val pp : (Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit
