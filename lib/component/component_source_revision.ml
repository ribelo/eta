(* Source revisions stamp replacement batches. One source authority assigns
   strictly increasing revisions for one component context. *)

type t = int64

let of_int64 value = value
let equal = Int64.equal
let compare = Int64.compare
let pp fmt value = Format.pp_print_string fmt (Int64.to_string value)
let to_int64 t = t
