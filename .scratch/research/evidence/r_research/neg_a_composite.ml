(* NEGATIVE TEST: R-A composite. Try to define A without `s` arg.
   Expected: COMPILE FAILURE — b and c need a services bag. *)
open R_a_composite

let _a_no_arg id =
  let open Effect in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id
