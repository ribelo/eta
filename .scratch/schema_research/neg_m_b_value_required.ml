(* Property: M-B exposes env codecs as thunks; using the function itself should fail.
   This documents the value-restriction ergonomics penalty. *)

let bad =
  M_b_env_codec_record.Codec.decode M_b_env_codec_record.config
    Migration_fixture.sample_config_json
