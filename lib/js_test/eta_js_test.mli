type test = string * ((unit -> unit) -> unit)

val fail : string -> string -> 'a
val log : string -> unit
val set_exit_code : int -> unit
val run_all : test list -> unit
val main : test list -> unit
val expect_ok : string -> (unit -> unit) -> unit
val finish : (unit -> unit) -> (unit -> unit) -> unit
