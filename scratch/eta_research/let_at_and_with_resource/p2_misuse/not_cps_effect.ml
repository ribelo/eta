open Eta

let bad =
  let ( let@ ) f k = f k in
  let@ x = Effect.pure 1 in
  Effect.pure (x + 1)
