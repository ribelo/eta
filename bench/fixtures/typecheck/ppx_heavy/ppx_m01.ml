open Eta

let f01 x = [%eta.fn (Effect.pure (x + 1))]
let f02 x = [%eta.fn (Effect.pure (x + 2))]
let f03 x = [%eta.fn (Effect.pure (x + 3))]
let f04 x = [%eta.fn (Effect.pure (x + 4))]
let f05 x = [%eta.fn (Effect.pure (x + 5))]
let f06 x = [%eta.fn (Effect.pure (x + 6))]
let f07 x = [%eta.fn (Effect.pure (x + 7))]
let f08 x = [%eta.fn (Effect.pure (x + 8))]
let f09 x = [%eta.fn (Effect.pure (x + 9))]
let f10 x = [%eta.fn (Effect.pure (x + 10))]
