(* Candidate C: make interpretation consume the whole AST at [once] mode so a
   resource node may store a once release callback. This tests whether the
   public Runtime.run shape can simply become consuming. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, 'err, unit) t) @@ once
      -> ('env, 'err, 'a) t

let rec run : type env err a. (env, err, a) t @ once -> a = function
  | Pure value -> value
  | Acquire_release (acquire, release) ->
      let value = run acquire in
      ignore (run (release value));
      value

let () =
  let (release @ once) _ = Pure () in
  ignore (run (Acquire_release (Pure 1, release)))
