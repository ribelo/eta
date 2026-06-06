let ( let* ) eff (k) = Effect.bind k eff
let ( let+ ) eff (f) = Effect.map f eff
let ( let@ ) (f) (k) = f k
let ( and* ) left right = Effect.par left right
let ( and+ ) left right = Effect.par left right
