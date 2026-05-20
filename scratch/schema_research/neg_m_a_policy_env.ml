(* Property: M-A effectful policy still records its env-row requirement.
   Predicted: closed env cannot run a decoder needing feature_allowed. *)

let bad :
    (< >, [> `Decode of Fixture.issue list ], Migration_fixture.config)
    Effet.Effect.t =
  M_a_pure_schema_effect_policy.decode_config_with_policy
    Migration_fixture.sample_config_json
