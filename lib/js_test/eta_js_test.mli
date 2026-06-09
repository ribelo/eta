module Test_clock = Test_clock

type test = string * (unit -> unit Js.Promise.t)

val fail : string -> string -> 'a
val run_all : test list -> unit Js.Promise.t
val expect_ok : string -> (unit -> unit) -> unit Js.Promise.t
