open Eta

let with_thing body = body 1

let bad =
  let open Syntax in
  let* x = with_thing in
  Effect.pure (x + 1)
