(* Negative: the redesigned portable Effet AST must reject a Thunk that
   captures a non-portable mutable ref. If this succeeded, the
   "portable" kind would be a lie. The compiler error proves the
   safety bar is real.

   Expected: this fixture does NOT compile. *)

open! Portable

type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Thunk :
      string * ('env -> 'a) @@ portable
      -> ('env, 'err, 'a) t

let bad () =
  let counter = ref 0 in
  let leaky : (unit, string, int) t =
    Thunk ("leak", fun _env -> incr counter; !counter)
  in
  ignore leaky

let () = bad ()
