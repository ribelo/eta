(* Negative: ABSTRACT Stream does NOT allow a [(:>)] coercion from outside.
   StreamA.t is a fresh nominal type; it is not a subtype of Channel.t, so the
   only way to reach the core is the named [StreamA.to_channel].
   To observe: add an (executable (name neg_abstract_coerce) ...) stanza, build,
   expect a type error. *)

let _test (s : (string, [ `E ]) Bridge_lib.StreamA.t) =
  let _ : (string, unit, unit, unit, [ `E ]) Bridge_lib.Channel.t =
    (s :> _)   (* must FAIL *)
  in
  ()
