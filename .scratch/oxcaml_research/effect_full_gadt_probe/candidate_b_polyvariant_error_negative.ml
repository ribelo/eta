(* Negative counterpart for Candidate B's pure core. The requested
   ('err : immutable_data) constraint rejects Effet's current open
   polymorphic-variant error style, even in the split shape. *)

open! Portable

module Effect_pure = struct
  type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
    | Fail : 'err -> ('env, 'err, _) t
end

let program : (unit, [> `Bad ], int) Effect_pure.t =
  Effect_pure.Fail `Bad

let () = ignore program

