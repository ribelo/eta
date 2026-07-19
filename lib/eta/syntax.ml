let ( let* ) eff (k) = Effect.bind k eff
let ( let+ ) eff (f) = Effect.map f eff
let ( let@ ) (f) (k) = f k

let ( and* ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left

let ( and+ ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
