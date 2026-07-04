(** Pure diagnostics helpers for Eta_signal internals. *)

val stats_counter :
  name:string -> int -> (int, [> `Counter_overflow of string ]) result

val bool_field : string -> bool -> string
