(* Property: H-S5 effectful decode keeps env-row requirements.
   Predicted: a codec needing age_policy cannot be run as a closed-env effect. *)

let bad :
    (< >, [> `Decode of Fixture.issue list ], Fixture.person)
    Effet.Effect.t =
  H_s5_codec_record.Codec.decode
    (H_s5_codec_record.person_with_policy ())
    Fixture.person_ok_json
