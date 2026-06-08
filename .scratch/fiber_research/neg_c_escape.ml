(* NEGATIVE TEST: F-C escape hatch should REJECT escaping fibers.
   Try to return a fiber from a [scoped] block.
   Expected: COMPILE FAILURE — the scope tag 's cannot leak. *)

open F_c_hybrid

let _attempt_escape () =
  let open Effect in
  (* Try to make scoped's result type be a fiber. The inner type
     mentions the bound 's, which cannot appear in the outer 'a. *)
  scoped {
    run = fun (type s) () : (s, _, _, (s, _, int) fiber) scoped_t ->
      fork (s_pure 42)
  }
