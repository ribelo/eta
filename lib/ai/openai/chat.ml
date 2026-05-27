module Common = Common
module Codec = Eta_ai_openai_codec

let message_json = Codec.chat_message_json

let encode ?structured_output request =
  Codec.encode_chat ~provider:"openai" ~schema_value:Common.schema_value
    ?structured_output request

let decode raw = Codec.decode_chat ~provider:"openai" raw
