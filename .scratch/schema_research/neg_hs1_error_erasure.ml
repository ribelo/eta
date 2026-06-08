(* Property: H-S1 decode failures stay in the typed error channel.
   Predicted: assigning a [`Decode _] effect to an [`Other] effect fails. *)

let bad :
    (< >, [ `Other ], Fixture.person) Effet.Effect.t =
  H_s1_decode.decode_person Fixture.person_bad_missing
