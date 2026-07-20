open Eta
let%eta add x = Effect.pure (x + 1)
let%eta greet ~name = Effect.pure ("hi " ^ name)
