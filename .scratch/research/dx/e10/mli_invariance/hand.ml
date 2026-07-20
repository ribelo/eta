open Eta
let add x = Effect.fn __POS__ __FUNCTION__ (Effect.pure (x + 1))
let greet ~name = Effect.fn __POS__ __FUNCTION__ (Effect.pure ("hi " ^ name))
