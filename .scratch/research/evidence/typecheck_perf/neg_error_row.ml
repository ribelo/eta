open Effet

let narrow : (< clock_now : int -> int; .. >, [ `Only ], int) Effect.t =
  Tp_m03.program ()
