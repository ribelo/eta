(* Negative: PRIVATE *abbreviation* does NOT allow pattern-matching the
   underlying channel from outside (only private *data types* allow
   match-but-not-construct; a private abbreviation keeps matching abstract).
   So private does not leak the channel representation via matching.
   To observe: add an (executable (name neg_private_match) ...) stanza, build,
   expect a type error. *)

let _test (s : (string, [ `E ]) Bridge_lib.StreamP.t) =
  match s with              (* must FAIL: cannot pattern-match a private abbrev *)
  | Bridge_lib.Channel.Emit _ -> ()
  | _ -> ()
