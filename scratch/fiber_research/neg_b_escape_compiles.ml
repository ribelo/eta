(* NEGATIVE TEST: F-B does NOT prevent escape.
   Same code as the F-C negative, ported to F-B.
   Expected: COMPILES (proves F-B's hazard). *)

open F_b_public_fiber

let _escapes_in_f_b () =
  let open Effect in
  let* f = fork (pure 42) in
  pure f
