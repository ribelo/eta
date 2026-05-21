(* Negative counterpart for Candidate B. The portable core must reject a
   callback that captures a mutable ref. *)

open! Portable
open Common

module Effect_pure = struct
  type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Thunk :
        string * ('env -> 'a) @@ portable
        -> ('env, _, 'a) t
end

let bad () =
  let counter = ref 0 in
  let program : (unit, string, int) Effect_pure.t =
    Effect_pure.Thunk ("bad", fun () ->
        incr counter;
        !counter)
  in
  ignore program

let () = bad ()

