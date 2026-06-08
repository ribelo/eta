(* Candidate C: reusable AST stores portable continuations, not once continuations. *)

open! Portable

type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ portable
      -> ('env, 'err, 'a) t
  | Map :
      ('env, 'err, 'b) t * ('b -> 'a) @@ portable
      -> ('env, 'err, 'a) t

let bind k e = Bind (e, k)
let map f e = Map (e, f)

let rec eval :
    type (env : value mod portable contended) (err : immutable_data) (a : immutable_data).
    (env, err, a) t -> a = function
  | Pure v -> v
  | Bind (inner, k) ->
      let v = eval inner in
      eval (k v)
  | Map (inner, f) -> f (eval inner)

let program : (unit, string, int) t =
  Pure 20
  |> map (fun n -> n + 1)
  |> bind (fun n -> Pure (n * 2))

let () =
  let a = eval program in
  let b = eval program in
  if a + b <> 84 then failwith "portable continuation AST should be reusable"

