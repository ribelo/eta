(* Negative test: an ambient nursery still needs a scope tag.

   Predicted error: the escaped child mentions the locally bound phantom
   scope ['s], so [with_nursery] cannot return it. This shows that ambient
   access does not remove the type-system cost of structured handles. *)

open F_f_ambient_nursery

let escaped =
  let open Nursery in
  with_nursery {
    run =
      fun (type s) () ->
        let* (child : (s, [> `Boom ], int) child) = start (pure 1) in
        pure child;
  }
