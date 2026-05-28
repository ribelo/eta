open Eta

let with_thing body = body 1

let bad =
  let ( let@ ) f k = f k in
  let open Syntax in
  let@ x = with_thing in
  let* y = Effect.pure 2 in
  x + y
