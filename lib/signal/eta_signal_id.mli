(** Opaque identifiers for Eta_signal internals. *)

type signal
type scope
type var
type observer

val signal : int -> signal
val scope : int -> scope
val var : int -> var
val observer : int -> observer

val signal_int : signal -> int
val scope_int : scope -> int
val var_int : var -> int
val observer_int : observer -> int

val signal_label : signal -> string
val dead_signal_label : signal -> string
val scope_label : scope -> string
val var_label : var -> string
val observer_label : observer -> string

val compare_observer : observer -> observer -> int
