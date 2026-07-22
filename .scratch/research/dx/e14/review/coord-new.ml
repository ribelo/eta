open Eta

let coordinate first continue =
  let promise = Promise.create () in
  let open Syntax in
  let producer =
    let* exit = Effect.to_exit first in
    let+ won = Promise.resolve promise exit in
    if not won then invalid_arg "coordinate: duplicate producer"
  in
  let consumer =
    let* value = Promise.await promise in
    continue value
  in
  let+ (), result = Effect.par producer consumer in
  result
