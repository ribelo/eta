open Eta
let add x = Effect.pure (x + 1) [@@eta.trace]
let greet ~name = Effect.pure ("hi " ^ name) [@@eta.trace]
