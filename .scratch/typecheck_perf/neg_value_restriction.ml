open Effet
let cell = ref None
let reusable = Effect.thunk "needs-open-row" (fun env -> env#clock_now 0)
let () = cell := Some reusable
let _a : (< clock_now : int -> int; .. >, [> `A ], int) Effect.t option = !cell
let _b : (< user_read : int -> int; .. >, [> `B ], int) Effect.t option = !cell
