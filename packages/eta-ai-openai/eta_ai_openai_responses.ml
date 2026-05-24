module Common = Eta_ai_openai_common
module Codec = Eta_ai_openai_codec

let encode ?structured_output request =
  Codec.encode_responses ~provider:"openai" ~schema_value:Common.schema_value
    ?structured_output request

let decode raw = Codec.decode_responses ~provider:"openai" raw
