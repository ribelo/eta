(* Candidate B: consuming run takes the whole AST at once mode.
   Reusing the same Effect.t value should be rejected. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ once
      -> ('env, 'err, 'a) t

let bind k e = Bind (e, k)

let rec eval : type env err a. (env, err, a) t @ once -> a = function
  | Pure v -> v
  | Bind (inner, k) ->
      let v = eval inner in
      eval (k v)

let run (program @ once) = eval program

let bad () =
  let (k @ once) n = Pure (n + 1) in
  let program = bind k (Pure 41) in
  let first = run program in
  let second = run program in
  first + second

let () = ignore (bad ())

