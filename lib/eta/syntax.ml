let ( let* ) effect k = Effect.bind k effect
let ( let+ ) effect f = Effect.map f effect
let ( let@ ) f k = f k
let ( and* ) left right = Effect.par left right
let ( and+ ) left right = Effect.par left right
