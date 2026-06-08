(* NEGATIVE TEST: R-A explicit. Try to define A without ~db/~log args.
   Expected: COMPILE FAILURE — b and c need labeled args. *)
open R_a_explicit

let _a_no_args id =
  let open Effect in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id
