let ( let* ) effect (k @ many) = Effect.bind k effect
let ( let+ ) effect (f @ many) = Effect.map f effect
let ( let@ ) (f @ many) (k @ many) = f k
let ( and* ) left right = Effect.par left right
let ( and+ ) left right = Effect.par left right
