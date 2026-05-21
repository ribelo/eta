(* Candidate C negative: portable continuations reject mutable ref capture. *)

open! Portable

type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ portable
      -> ('env, 'err, 'a) t

let bad () =
  let counter = ref 0 in
  let program : (unit, string, int) t =
    Bind (Pure 1, fun n ->
      incr counter;
      Pure (n + !counter))
  in
  ignore program

let () = bad ()

