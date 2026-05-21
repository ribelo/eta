(* Candidate A: reusable/many AST stores a once Bind continuation.
   Expected: this should not be the Phase 4 shape if it makes reuse awkward. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ once
      -> ('env, 'err, 'a) t

let bind k e = Bind (e, k)

let rec eval : type env err a. (env, err, a) t -> a = function
  | Pure v -> v
  | Bind (inner, k) ->
      let v = eval inner in
      eval (k v)

let program : (unit, string, int) t =
  let (k @ once) n = Pure (n + 1) in
  bind k (Pure 41)

let () =
  let a = eval program in
  let b = eval program in
  if a + b <> 84 then failwith "many AST with once continuation changed"

