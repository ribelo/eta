(* Negative: PRIVATE abbreviation does NOT allow constructing a t from a
   channel outside the defining module. The backward direction still requires
   the named [StreamP.of_channel], so private is NOT a free-for-all.
   To observe: add an (executable (name neg_private_construct) ...) stanza,
   build, expect a type error. *)

(* This tries to build a StreamP.t directly from a Channel.t value by claiming
   type equality. Private forbids it. *)
let _test (c : (string, unit, unit, unit, [ `E ]) Bridge_lib.Channel.t) =
  let _ : (string, [ `E ]) Bridge_lib.StreamP.t = c in  (* must FAIL *)
  ()
