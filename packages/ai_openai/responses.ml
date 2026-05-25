module Common = Common
module Codec = Ai_openai_codec

let encode ?structured_output request =
  Codec.encode_responses ~provider:"openai" ~schema_value:Common.schema_value
    ?structured_output request

let decode raw = Codec.decode_responses ~provider:"openai" raw
