open Eta

type ('env, 'a, 'err) t = 'env -> ('a, 'err) Effect.t

let run env reader = reader env
let ask env = Effect.pure env
let local f reader env = reader (f env)
let pure value _env = Effect.pure value
let lift effect _env = effect
let map f reader env = Effect.map f (reader env)

let bind f reader env =
  Effect.bind (fun value -> f value env) (reader env)

module Syntax = struct
  let ( let* ) reader f = bind f reader
  let ( let+ ) reader f = map f reader
end
